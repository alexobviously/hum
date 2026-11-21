use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    BufferSize, FromSample, Sample, SampleFormat, SizedSample, StreamConfig,
    SupportedBufferSize,
};

/// Active capture stream and lock-free ring buffer consumer handle.
pub struct HumCaptureHandle {
    consumer: rtrb::Consumer<f32>,
    _stream: cpal::Stream,
    channels: usize,
    stopped: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
    overruns: Arc<AtomicU64>,
}

fn find_input_device(
    host: &cpal::Host,
    device_id: Option<&str>,
) -> Result<cpal::Device, String> {
    match device_id {
        Some(target_id) => {
            let devices = host.devices().map_err(|e| {
                format!("Failed to enumerate audio devices: {e}")
            })?;
            for device in devices {
                if device
                    .id()
                    .ok()
                    .is_some_and(|id| id.to_string() == target_id)
                {
                    return Ok(device);
                }
            }
            Err(format!("Audio input device '{target_id}' was not found"))
        }
        None => host.default_input_device().ok_or_else(|| {
            String::from("No default audio input device available")
        }),
    }
}

fn buffer_size_supported(
    supported: &SupportedBufferSize,
    hardware_buffer_frames: u32,
) -> bool {
    if hardware_buffer_frames == 0 {
        return true;
    }
    match supported {
        SupportedBufferSize::Range { min, max } => {
            *min <= hardware_buffer_frames && hardware_buffer_frames <= *max
        }
        SupportedBufferSize::Unknown => true,
    }
}

/// Validates that `device` supports the requested `(sample_rate, channels)`
/// configuration and picks the best supported sample format:
/// `F32` preferred, falling back to `I32`, `I16`, then `U16`.
fn select_input_sample_format(
    device: &cpal::Device,
    sample_rate: u32,
    channels: u16,
    hardware_buffer_frames: u32,
) -> Result<SampleFormat, String> {
    let device_name = device
        .description()
        .map(|d| d.name().to_owned())
        .unwrap_or_else(|_| String::from("Unknown Device"));

    let config_ranges = device.supported_input_configs().map_err(|e| {
        format!("Failed to query input configs for '{device_name}': {e}")
    })?;

    let mut best_format: Option<(u8, SampleFormat)> = None;
    for range in config_ranges {
        if range.channels() != channels
            || sample_rate < range.min_sample_rate()
            || sample_rate > range.max_sample_rate()
            || !buffer_size_supported(
                range.buffer_size(),
                hardware_buffer_frames,
            )
        {
            continue;
        }

        let priority = match range.sample_format() {
            SampleFormat::F32 => 4,
            SampleFormat::I32 => 3,
            SampleFormat::I16 => 2,
            SampleFormat::U16 => 1,
            _ => 0,
        };
        if priority > 0
            && best_format.is_none_or(|(best_prio, _)| priority > best_prio)
        {
            best_format = Some((priority, range.sample_format()));
        }
    }

    best_format.map(|(_, fmt)| fmt).ok_or_else(|| {
        if hardware_buffer_frames > 0 {
            format!(
                "Device '{device_name}' does not support {channels}ch input audio at {sample_rate}Hz with hardwareBufferFrames={hardware_buffer_frames} (f32/i32/i16/u16)"
            )
        } else {
            format!(
                "Device '{device_name}' does not support {channels}ch input audio at {sample_rate}Hz (f32/i32/i16/u16)"
            )
        }
    })
}

/// Pushes complete interleaved `f32` frames directly into `producer`.
///
/// Always writes whole frames so channel alignment cannot drift on overrun.
fn push_f32_frames(
    producer: &mut rtrb::Producer<f32>,
    input: &[f32],
    channels: usize,
    overruns: &AtomicU64,
) {
    let input_frames = input.len() / channels;
    let free_frames = producer.slots() / channels;
    let writable_frames = input_frames.min(free_frames);

    if writable_frames > 0 {
        let sample_count = writable_frames * channels;
        if let Ok(mut chunk) = producer.write_chunk(sample_count) {
            let (first, second) = chunk.as_mut_slices();
            let split = first.len();
            first.copy_from_slice(&input[..split]);
            second.copy_from_slice(&input[split..sample_count]);
            chunk.commit_all();
        }
    }

    if writable_frames < input_frames {
        overruns.fetch_add(1, Ordering::Relaxed);
    }
}

/// Converts interleaved samples of type `T` to `f32` on the fly and pushes
/// complete frames into `producer` with zero heap allocations.
fn push_converted_frames<T>(
    producer: &mut rtrb::Producer<f32>,
    input: &[T],
    channels: usize,
    overruns: &AtomicU64,
) where
    T: SizedSample,
    f32: FromSample<T>,
{
    let input_frames = input.len() / channels;
    let free_frames = producer.slots() / channels;
    let writable_frames = input_frames.min(free_frames);

    if writable_frames > 0 {
        let sample_count = writable_frames * channels;
        if let Ok(mut chunk) = producer.write_chunk(sample_count) {
            let (first, second) = chunk.as_mut_slices();
            let split = first.len();

            for (dst, &src) in first.iter_mut().zip(&input[..split]) {
                *dst = f32::from_sample(src);
            }

            for (dst, &src) in
                second.iter_mut().zip(&input[split..sample_count])
            {
                *dst = f32::from_sample(src);
            }

            chunk.commit_all();
        }
    }

    if writable_frames < input_frames {
        overruns.fetch_add(1, Ordering::Relaxed);
    }
}

fn build_converted_input_stream<T>(
    device: &cpal::Device,
    config: StreamConfig,
    mut producer: rtrb::Producer<f32>,
    channels: usize,
    overruns: Arc<AtomicU64>,
    stopped: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    device
        .build_input_stream(
            config,
            move |input: &[T], _| {
                push_converted_frames(
                    &mut producer,
                    input,
                    channels,
                    &overruns,
                );
            },
            move |err| {
                if let Ok(mut guard) = last_error.lock() {
                    *guard = Some(err.to_string());
                }
                stopped.store(true, Ordering::Release);
            },
            None,
        )
        .map_err(|e| format!("Failed to build input stream: {e}"))
}

impl HumCaptureHandle {
    /// Opens and starts a cpal input stream backed by an `rtrb` ring buffer.
    ///
    /// Prefers `f32` native capture and falls back to zero-allocation `i32`,
    /// `i16`, or `u16` -> `f32` conversion when the device does not advertise
    /// `f32` for the requested `(sample_rate, channels)`.
    ///
    /// Pass `hardware_buffer_frames == 0` to use the OS default period size
    /// (`BufferSize::Default`), or a positive frame count for
    /// `BufferSize::Fixed(n)`.
    pub fn create(
        device_id: Option<&str>,
        sample_rate: u32,
        channels: u32,
        buffer_frames: u32,
        hardware_buffer_frames: u32,
    ) -> Result<Self, String> {
        if sample_rate == 0 {
            return Err(String::from("sampleRate must be positive"));
        }
        let channels_u16 = u16::try_from(channels)
            .ok()
            .filter(|&c| c > 0)
            .ok_or_else(|| format!("Invalid channel count: {channels}"))?;
        if buffer_frames == 0 {
            return Err(String::from("bufferFrames must be positive"));
        }

        let channels_usize = usize::from(channels_u16);
        let ring_capacity = (buffer_frames as usize)
            .checked_mul(channels_usize)
            .ok_or_else(|| String::from("Ring buffer capacity overflow"))?;

        let host = cpal::default_host();
        let device = find_input_device(&host, device_id)?;
        let sample_format = select_input_sample_format(
            &device,
            sample_rate,
            channels_u16,
            hardware_buffer_frames,
        )?;

        let (mut producer, consumer) =
            rtrb::RingBuffer::<f32>::new(ring_capacity);
        let stopped = Arc::new(AtomicBool::new(false));
        let last_error = Arc::new(Mutex::new(None));
        let overruns = Arc::new(AtomicU64::new(0));

        let data_overruns = Arc::clone(&overruns);
        let error_stopped = Arc::clone(&stopped);
        let error_message = Arc::clone(&last_error);

        let config = StreamConfig {
            channels: channels_u16,
            sample_rate,
            buffer_size: if hardware_buffer_frames == 0 {
                BufferSize::Default
            } else {
                BufferSize::Fixed(hardware_buffer_frames)
            },
        };

        let stream = match sample_format {
            SampleFormat::F32 => device
                .build_input_stream(
                    config,
                    move |input: &[f32], _| {
                        push_f32_frames(
                            &mut producer,
                            input,
                            channels_usize,
                            &data_overruns,
                        );
                    },
                    move |err| {
                        if let Ok(mut guard) = error_message.lock() {
                            *guard = Some(err.to_string());
                        }
                        error_stopped.store(true, Ordering::Release);
                    },
                    None,
                )
                .map_err(|e| format!("Failed to build input stream: {e}"))?,
            SampleFormat::I32 => build_converted_input_stream::<i32>(
                &device,
                config,
                producer,
                channels_usize,
                data_overruns,
                error_stopped,
                error_message,
            )?,
            SampleFormat::I16 => build_converted_input_stream::<i16>(
                &device,
                config,
                producer,
                channels_usize,
                data_overruns,
                error_stopped,
                error_message,
            )?,
            SampleFormat::U16 => build_converted_input_stream::<u16>(
                &device,
                config,
                producer,
                channels_usize,
                data_overruns,
                error_stopped,
                error_message,
            )?,
            other => {
                return Err(format!(
                    "Unsupported input sample format: {other}"
                ));
            }
        };

        stream
            .play()
            .map_err(|e| format!("Failed to start input stream: {e}"))?;

        Ok(Self {
            consumer,
            _stream: stream,
            channels: channels_usize,
            stopped,
            last_error,
            overruns,
        })
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Number of interleaved float32 frames currently buffered and ready to read.
    pub fn available_read_frames(&self) -> u32 {
        (self.consumer.slots() / self.channels) as u32
    }

    /// Pops up to as many complete interleaved float32 frames as fit in
    /// `interleaved_out` and returns the number of frames read.
    pub fn read_frames(&mut self, interleaved_out: &mut [f32]) -> u32 {
        if self.is_stopped() {
            return 0;
        }

        let requested_frames = interleaved_out.len() / self.channels;
        let readable_frames =
            requested_frames.min(self.consumer.slots() / self.channels);
        if readable_frames == 0 {
            return 0;
        }

        let sample_count = readable_frames * self.channels;
        let Ok(chunk) = self.consumer.read_chunk(sample_count) else {
            return 0;
        };

        let (first, second) = chunk.as_slices();
        let split = first.len();
        interleaved_out[..split].copy_from_slice(first);
        interleaved_out[split..sample_count].copy_from_slice(second);
        chunk.commit_all();

        readable_frames as u32
    }

    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }

    pub fn overruns(&self) -> u64 {
        self.overruns.load(Ordering::Relaxed)
    }

    pub fn take_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|mut g| g.take())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_parameters() {
        assert!(HumCaptureHandle::create(None, 0, 1, 1024, 0).is_err());
        assert!(HumCaptureHandle::create(None, 48000, 0, 1024, 0).is_err());
        assert!(HumCaptureHandle::create(None, 48000, 1, 0, 0).is_err());
        assert!(
            HumCaptureHandle::create(
                Some("nonexistent-device-id"),
                48000,
                1,
                1024,
                0
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_mismatched_channel_or_sample_rate() {
        let host = cpal::default_host();
        if host.default_input_device().is_none() {
            return;
        }

        assert!(HumCaptureHandle::create(None, 48000, 99, 1024, 0).is_err());
        assert!(HumCaptureHandle::create(None, 12345, 1, 1024, 0).is_err());
    }

    #[test]
    fn converts_i16_frames_and_counts_overruns() {
        let (mut producer, mut consumer) = rtrb::RingBuffer::<f32>::new(4);
        let overruns = AtomicU64::new(0);

        // 3 stereo frames into a 2-frame (4-sample) ring buffer: writes 2
        // frames cleanly and counts 1 overrun without breaking frame alignment.
        let input: [i16; 6] = [i16::MAX, 0, i16::MIN, 0, 1000, -1000];
        push_converted_frames(&mut producer, &input, 2, &overruns);

        assert_eq!(overruns.load(Ordering::Relaxed), 1);
        assert_eq!(consumer.slots(), 4);

        let chunk = consumer.read_chunk(4).expect("4 samples readable");
        let (first, second) = chunk.as_slices();
        let mut out = Vec::with_capacity(4);
        out.extend_from_slice(first);
        out.extend_from_slice(second);
        chunk.commit_all();

        assert!((out[0] - 1.0).abs() < 1e-4);
        assert_eq!(out[1], 0.0);
        assert!((out[2] - (-1.0)).abs() < 1e-4);
        assert_eq!(out[3], 0.0);
    }

    #[test]
    fn creates_reads_and_drops_stream_cleanly() {
        let host = cpal::default_host();
        let Some(device) = host.default_input_device() else {
            return;
        };
        let Ok(cfg) = device.default_input_config() else {
            return;
        };

        let channels = u32::from(cfg.channels());
        let mut handle = HumCaptureHandle::create(
            None,
            cfg.sample_rate(),
            channels,
            2048,
            0,
        )
        .expect("default input config should open");

        assert!(!handle.is_stopped());

        let mut buf = vec![0.0_f32; 128 * channels as usize];
        let _read = handle.read_frames(&mut buf);
        assert!(handle.take_error().is_none());
    }

    #[test]
    fn supports_fixed_hardware_buffer_frames_and_rejects_out_of_range() {
        let host = cpal::default_host();
        let Some(device) = host.default_input_device() else {
            return;
        };
        let Ok(cfg) = device.default_input_config() else {
            return;
        };
        let SupportedBufferSize::Range { min, max } = *cfg.buffer_size() else {
            return;
        };

        let channels = u32::from(cfg.channels());
        let target = 64_u32.clamp(min, max);
        let handle = HumCaptureHandle::create(
            None,
            cfg.sample_rate(),
            channels,
            512,
            target,
        )
        .expect("fixed hardwareBufferFrames within range should open");
        assert!(!handle.is_stopped());
        drop(handle);

        assert!(
            HumCaptureHandle::create(
                None,
                cfg.sample_rate(),
                channels,
                512,
                max.saturating_add(1_000_000),
            )
            .is_err()
        );
    }
}

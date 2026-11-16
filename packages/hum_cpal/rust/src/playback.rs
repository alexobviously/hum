use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, SampleFormat, StreamConfig};

/// Active playback stream and lock-free ring buffer producer handle.
pub struct HumPlaybackHandle {
    producer: rtrb::Producer<f32>,
    _stream: cpal::Stream,
    channels: usize,
    stopped: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
    underruns: Arc<AtomicU64>,
}

fn find_output_device(
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
            Err(format!("Audio output device '{target_id}' was not found"))
        }
        None => host.default_output_device().ok_or_else(|| {
            String::from("No default audio output device available")
        }),
    }
}

fn validate_output_config(
    device: &cpal::Device,
    sample_rate: u32,
    channels: u16,
) -> Result<(), String> {
    let device_name = device
        .description()
        .map(|d| d.name().to_owned())
        .unwrap_or_else(|_| String::from("Unknown Device"));

    let config_ranges = device.supported_output_configs().map_err(|e| {
        format!("Failed to query output configs for '{device_name}': {e}")
    })?;

    for range in config_ranges {
        if range.sample_format() == SampleFormat::F32
            && range.channels() == channels
            && range.min_sample_rate() <= sample_rate
            && sample_rate <= range.max_sample_rate()
        {
            return Ok(());
        }
    }

    Err(format!(
        "Device '{device_name}' does not support f32 {channels}ch audio at {sample_rate}Hz"
    ))
}

impl HumPlaybackHandle {
    /// Opens and starts a cpal float32 playback stream backed by an `rtrb`
    /// ring buffer.
    pub fn create(
        device_id: Option<&str>,
        sample_rate: u32,
        channels: u32,
        buffer_frames: u32,
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
        let device = find_output_device(&host, device_id)?;
        validate_output_config(&device, sample_rate, channels_u16)?;

        let (producer, mut consumer) =
            rtrb::RingBuffer::<f32>::new(ring_capacity);
        let stopped = Arc::new(AtomicBool::new(false));
        let last_error = Arc::new(Mutex::new(None));
        let underruns = Arc::new(AtomicU64::new(0));

        let data_underruns = Arc::clone(&underruns);
        let error_stopped = Arc::clone(&stopped);
        let error_message = Arc::clone(&last_error);

        let config = StreamConfig {
            channels: channels_u16,
            sample_rate,
            buffer_size: BufferSize::Default,
        };

        let stream = device
            .build_output_stream(
                config,
                move |output: &mut [f32], _| {
                    let available = consumer.slots().min(output.len());
                    if available > 0
                        && let Ok(chunk) = consumer.read_chunk(available)
                    {
                        let (first, second) = chunk.as_slices();
                        output[..first.len()].copy_from_slice(first);
                        output[first.len()..available].copy_from_slice(second);
                        chunk.commit_all();
                    }

                    if available < output.len() {
                        output[available..].fill(0.0);
                        data_underruns.fetch_add(1, Ordering::Relaxed);
                    }
                },
                move |err| {
                    if let Ok(mut guard) = error_message.lock() {
                        *guard = Some(err.to_string());
                    }
                    error_stopped.store(true, Ordering::Release);
                },
                None,
            )
            .map_err(|e| format!("Failed to build output stream: {e}"))?;

        stream
            .play()
            .map_err(|e| format!("Failed to start output stream: {e}"))?;

        Ok(Self {
            producer,
            _stream: stream,
            channels: channels_usize,
            stopped,
            last_error,
            underruns,
        })
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Number of interleaved float32 frames currently free to write.
    pub fn available_write_frames(&self) -> u32 {
        (self.producer.slots() / self.channels) as u32
    }

    /// Pushes as many complete interleaved float32 frames as fit into the ring
    /// buffer and returns the number of frames written.
    pub fn write_frames(&mut self, interleaved_samples: &[f32]) -> u32 {
        if self.is_stopped() {
            return 0;
        }

        let requested_frames = interleaved_samples.len() / self.channels;
        let writable_frames =
            requested_frames.min(self.producer.slots() / self.channels);
        if writable_frames == 0 {
            return 0;
        }

        let sample_count = writable_frames * self.channels;
        let Ok(mut chunk) = self.producer.write_chunk(sample_count) else {
            return 0;
        };

        let (first, second) = chunk.as_mut_slices();
        let split = first.len();
        first.copy_from_slice(&interleaved_samples[..split]);
        second.copy_from_slice(&interleaved_samples[split..sample_count]);
        chunk.commit_all();

        writable_frames as u32
    }

    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }

    pub fn underruns(&self) -> u64 {
        self.underruns.load(Ordering::Relaxed)
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
        assert!(HumPlaybackHandle::create(None, 0, 2, 1024).is_err());
        assert!(HumPlaybackHandle::create(None, 48000, 0, 1024).is_err());
        assert!(HumPlaybackHandle::create(None, 48000, 2, 0).is_err());
        assert!(
            HumPlaybackHandle::create(
                Some("nonexistent-device-id"),
                48000,
                2,
                1024
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_mismatched_channel_or_sample_rate() {
        let host = cpal::default_host();
        if host.default_output_device().is_none() {
            return;
        }

        // Unlikely 99 channels / 12345 Hz should be explicitly rejected instead
        // of silently converted.
        assert!(HumPlaybackHandle::create(None, 48000, 99, 1024).is_err());
        assert!(HumPlaybackHandle::create(None, 12345, 2, 1024).is_err());
    }

    #[test]
    fn creates_writes_and_drops_stream_cleanly() {
        let host = cpal::default_host();
        let Some(device) = host.default_output_device() else {
            return;
        };
        let Ok(cfg) = device.default_output_config() else {
            return;
        };
        if cfg.sample_format() != SampleFormat::F32 {
            return;
        }

        let channels = u32::from(cfg.channels());
        let mut handle =
            HumPlaybackHandle::create(None, cfg.sample_rate(), channels, 2048)
                .expect("default output config should open");

        assert!(!handle.is_stopped());
        assert!(handle.available_write_frames() >= 512);

        let silent = vec![0.0_f32; 512 * channels as usize];
        let written = handle.write_frames(&silent);
        assert_eq!(written, 512);
        assert!(handle.take_error().is_none());
    }
}

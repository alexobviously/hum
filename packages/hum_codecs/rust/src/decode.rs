use std::io::{Cursor, ErrorKind};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
use symphonia::core::errors::Error;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Planar 32-bit float audio decoded from an encoded byte stream.
///
/// `samples` is laid out channel-by-channel (`[ch0_0..ch0_N, ch1_0..ch1_N]`).
pub struct DecodedAudio {
    pub samples: Vec<f32>,
    pub num_frames: u32,
    pub num_channels: u32,
    pub sample_rate: u32,
}

/// Decodes an encoded audio byte buffer into planar 32-bit float samples using
/// Symphonia.
///
/// `hint` is an optional file extension (e.g. `"mp3"`, `"flac"`, `"ogg"`) that
/// assists format probing.
pub fn decode_audio(
    bytes: &[u8],
    hint: Option<&str>,
) -> Result<DecodedAudio, String> {
    if bytes.is_empty() {
        return Err(String::from("Input audio buffer is empty"));
    }

    let cursor = Cursor::new(bytes.to_vec());
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());

    let mut probe_hint = Hint::new();
    if let Some(ext) = hint {
        let trimmed = ext.trim().trim_start_matches('.');
        if !trimmed.is_empty() {
            probe_hint.with_extension(trimmed);
        }
    }

    let format_opts = FormatOptions {
        enable_gapless: true,
        ..Default::default()
    };

    let probed = symphonia::default::get_probe()
        .format(
            &probe_hint,
            mss,
            &format_opts,
            &MetadataOptions::default(),
        )
        .map_err(|e| format!("Failed to probe audio format: {e}"))?;

    let mut format = probed.format;

    let track = format
        .default_track()
        .filter(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .or_else(|| {
            format
                .tracks()
                .iter()
                .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        })
        .ok_or_else(|| String::from("No supported audio track found"))?;

    let track_id = track.id;
    let mut sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let mut num_channels =
        track.codec_params.channels.map_or(0, |c| c.count());

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("Failed to create audio decoder: {e}"))?;

    let mut channel_vecs: Vec<Vec<f32>> = if num_channels > 0 {
        vec![Vec::new(); num_channels]
    } else {
        Vec::new()
    };

    let mut sample_buf: Option<SampleBuffer<f32>> = None;

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(Error::IoError(err))
                if err.kind() == ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(Error::ResetRequired) => {
                decoder.reset();
                continue;
            }
            Err(err) => {
                return Err(format!("Failed to read audio packet: {err}"));
            }
        };

        if packet.track_id() != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(Error::DecodeError(_)) => {
                // Skip recoverable/corrupt frames instead of aborting the file.
                continue;
            }
            Err(Error::IoError(err))
                if err.kind() == ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(err) => {
                return Err(format!("Failed to decode audio packet: {err}"));
            }
        };

        let spec = *decoded.spec();
        let packet_channels = spec.channels.count();
        if packet_channels == 0 {
            continue;
        }

        if sample_rate == 0 {
            sample_rate = spec.rate;
        }
        if num_channels == 0 {
            num_channels = packet_channels;
            channel_vecs = vec![Vec::new(); num_channels];
        } else if packet_channels != num_channels {
            return Err(format!(
                "Channel count changed mid-stream ({num_channels} -> {packet_channels})"
            ));
        }

        let frames = decoded.frames();
        if frames == 0 {
            continue;
        }

        let needed_capacity = decoded.capacity() as u64;
        let buf = match sample_buf.as_mut() {
            Some(buf) if buf.capacity() >= frames * num_channels => buf,
            _ => sample_buf.insert(SampleBuffer::<f32>::new(
                needed_capacity,
                spec,
            )),
        };

        buf.copy_planar_ref(decoded);
        let planar = buf.samples();

        for (ch, channel_out) in channel_vecs.iter_mut().enumerate() {
            let start = ch * frames;
            let end = start + frames;
            channel_out.extend_from_slice(&planar[start..end]);
        }
    }

    if sample_rate == 0 || num_channels == 0 {
        return Err(String::from("Audio stream contained no decodable frames"));
    }

    let num_frames = channel_vecs[0].len();
    let num_frames_u32 = u32::try_from(num_frames)
        .map_err(|_| String::from("Decoded frame count exceeds u32::MAX"))?;
    let num_channels_u32 = u32::try_from(num_channels)
        .map_err(|_| String::from("Channel count exceeds u32::MAX"))?;

    let mut flat_planar = Vec::with_capacity(num_frames * num_channels);
    for ch in channel_vecs {
        flat_planar.extend_from_slice(&ch);
    }

    Ok(DecodedAudio {
        samples: flat_planar,
        num_frames: num_frames_u32,
        num_channels: num_channels_u32,
        sample_rate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_stereo_pcm16_wav(sample_rate: u32, frames: &[(i16, i16)]) -> Vec<u8> {
        let data_size = (frames.len() * 4) as u32;
        let mut out = Vec::with_capacity(44 + data_size as usize);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_size).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&2u16.to_le_bytes()); // stereo
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * 4).to_le_bytes());
        out.extend_from_slice(&4u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_size.to_le_bytes());
        for &(l, r) in frames {
            out.extend_from_slice(&l.to_le_bytes());
            out.extend_from_slice(&r.to_le_bytes());
        }
        out
    }

    #[test]
    fn decodes_stereo_wav_into_planar_f32() {
        let wav = make_stereo_pcm16_wav(
            48_000,
            &[(16384, -16384), (8192, -8192), (0, 32767)],
        );
        let decoded = decode_audio(&wav, Some("wav")).expect("decode wav");
        assert_eq!(decoded.sample_rate, 48_000);
        assert_eq!(decoded.num_channels, 2);
        assert_eq!(decoded.num_frames, 3);
        assert_eq!(decoded.samples.len(), 6);
        assert!((decoded.samples[0] - 0.5).abs() < 1e-3);
        assert!((decoded.samples[1] - 0.25).abs() < 1e-3);
        assert!((decoded.samples[3] + 0.5).abs() < 1e-3);
        assert!((decoded.samples[4] + 0.25).abs() < 1e-3);
    }

    #[test]
    fn rejects_empty_or_invalid_input() {
        assert!(decode_audio(&[], None).is_err());
        assert!(decode_audio(b"not an audio file", Some("mp3")).is_err());
    }
}

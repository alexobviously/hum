use cpal::traits::{DeviceTrait, HostTrait};
use cpal::{
    SampleFormat, SupportedBufferSize, SupportedStreamConfig,
    SupportedStreamConfigRange,
};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostSnapshot {
    pub host_name: &'static str,
    pub devices: Vec<DeviceInfo>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub is_default_output: bool,
    pub is_default_input: bool,
    pub default_output: Option<DefaultConfig>,
    pub default_input: Option<DefaultConfig>,
    pub output_configs: Vec<ConfigRange>,
    pub input_configs: Vec<ConfigRange>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BufferSizeRange {
    pub min: u32,
    pub max: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub sample_format: &'static str,
    pub buffer_size: Option<BufferSizeRange>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigRange {
    pub channels: u16,
    pub min_sample_rate: u32,
    pub max_sample_rate: u32,
    pub sample_format: &'static str,
    pub buffer_size: Option<BufferSizeRange>,
}

fn format_name(format: SampleFormat) -> &'static str {
    match format {
        SampleFormat::F32 => "f32",
        SampleFormat::F64 => "f64",
        SampleFormat::I16 => "i16",
        SampleFormat::I32 => "i32",
        SampleFormat::U16 => "u16",
        _ => "other",
    }
}

fn map_buffer_size(size: &SupportedBufferSize) -> Option<BufferSizeRange> {
    match size {
        SupportedBufferSize::Range { min, max } => Some(BufferSizeRange {
            min: *min,
            max: *max,
        }),
        SupportedBufferSize::Unknown => None,
    }
}

fn map_default_config(cfg: &SupportedStreamConfig) -> DefaultConfig {
    DefaultConfig {
        sample_rate: cfg.sample_rate(),
        channels: cfg.channels(),
        sample_format: format_name(cfg.sample_format()),
        buffer_size: map_buffer_size(cfg.buffer_size()),
    }
}

fn map_config_range(range: &SupportedStreamConfigRange) -> ConfigRange {
    ConfigRange {
        channels: range.channels(),
        min_sample_rate: range.min_sample_rate(),
        max_sample_rate: range.max_sample_rate(),
        sample_format: format_name(range.sample_format()),
        buffer_size: map_buffer_size(range.buffer_size()),
    }
}

fn build_device_info(
    device: &cpal::Device,
    device_id: &cpal::DeviceId,
    is_default_output: bool,
    is_default_input: bool,
) -> DeviceInfo {
    let name = device
        .description()
        .map(|desc| desc.name().to_owned())
        .unwrap_or_else(|_| String::from("Unknown Device"));

    DeviceInfo {
        id: device_id.to_string(),
        name,
        is_default_output,
        is_default_input,
        default_output: device
            .default_output_config()
            .ok()
            .map(|c| map_default_config(&c)),
        default_input: device
            .default_input_config()
            .ok()
            .map(|c| map_default_config(&c)),
        output_configs: device
            .supported_output_configs()
            .map(|r| r.map(|c| map_config_range(&c)).collect())
            .unwrap_or_default(),
        input_configs: device
            .supported_input_configs()
            .map(|r| r.map(|c| map_config_range(&c)).collect())
            .unwrap_or_default(),
    }
}

/// Probes the default cpal host and serializes all device capabilities as JSON.
pub fn probe_devices_json() -> Result<String, serde_json::Error> {
    let host = cpal::default_host();
    let default_output = host.default_output_device();
    let default_input = host.default_input_device();
    let default_output_id = default_output.as_ref().and_then(|d| d.id().ok());
    let default_input_id = default_input.as_ref().and_then(|d| d.id().ok());

    let mut devices = Vec::new();
    let mut saw_default_output = false;
    let mut saw_default_input = false;

    if let Ok(iter) = host.devices() {
        for device in iter {
            let Ok(device_id) = device.id() else {
                continue;
            };
            let is_def_out = default_output_id.as_ref() == Some(&device_id);
            let is_def_in = default_input_id.as_ref() == Some(&device_id);
            saw_default_output |= is_def_out;
            saw_default_input |= is_def_in;

            devices.push(build_device_info(
                &device, &device_id, is_def_out, is_def_in,
            ));
        }
    }

    // Some backends (notably Android AAudio) expose a virtual default device
    // (`Device(None)`) from `default_output_device()` / `default_input_device()`
    // that is not included in `host.devices()`. Append it if not already seen.
    if !saw_default_output
        && let (Some(out_dev), Some(out_id)) =
            (default_output.as_ref(), default_output_id.as_ref())
    {
        let same_as_in =
            !saw_default_input && default_input_id.as_ref() == Some(out_id);
        if same_as_in {
            saw_default_input = true;
        }
        devices.push(build_device_info(out_dev, out_id, true, same_as_in));
    }

    if !saw_default_input
        && let (Some(in_dev), Some(in_id)) =
            (default_input.as_ref(), default_input_id.as_ref())
    {
        devices.push(build_device_info(in_dev, in_id, false, true));
    }

    serde_json::to_string(&HostSnapshot {
        host_name: host.id().name(),
        devices,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probes_host_snapshot_json() {
        let json =
            probe_devices_json().expect("JSON serialization should succeed");
        let parsed: serde_json::Value =
            serde_json::from_str(&json).expect("valid JSON payload");
        assert!(parsed["hostName"].is_string());
        assert!(parsed["devices"].is_array());
    }
}

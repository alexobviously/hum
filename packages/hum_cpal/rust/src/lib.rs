use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use cpal::traits::{DeviceTrait, HostTrait};
use cpal::{SampleFormat, SupportedBufferSize, SupportedStreamConfig, SupportedStreamConfigRange};
use serde::Serialize;

#[unsafe(no_mangle)]
pub extern "C" fn hum_cpal_add(a: i32, b: i32) -> i32 {
    a + b
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostSnapshot {
    host_name: &'static str,
    devices: Vec<DeviceInfo>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceInfo {
    id: String,
    name: String,
    is_default_output: bool,
    is_default_input: bool,
    default_output: Option<DefaultConfig>,
    default_input: Option<DefaultConfig>,
    output_configs: Vec<ConfigRange>,
    input_configs: Vec<ConfigRange>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BufferSizeRange {
    min: u32,
    max: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DefaultConfig {
    sample_rate: u32,
    channels: u16,
    sample_format: &'static str,
    buffer_size: Option<BufferSizeRange>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigRange {
    channels: u16,
    min_sample_rate: u32,
    max_sample_rate: u32,
    sample_format: &'static str,
    buffer_size: Option<BufferSizeRange>,
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

fn probe_devices_json() -> Result<String, serde_json::Error> {
    let host = cpal::default_host();
    let default_output_id = host.default_output_device().and_then(|d| d.id().ok());
    let default_input_id = host.default_input_device().and_then(|d| d.id().ok());

    let mut devices = Vec::new();
    if let Ok(iter) = host.devices() {
        for device in iter {
            let Ok(device_id) = device.id() else {
                continue;
            };
            let name = device
                .description()
                .map(|desc| desc.name().to_owned())
                .unwrap_or_else(|_| String::from("Unknown Device"));

            devices.push(DeviceInfo {
                id: device_id.to_string(),
                name,
                is_default_output: default_output_id.as_ref() == Some(&device_id),
                is_default_input: default_input_id.as_ref() == Some(&device_id),
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
            });
        }
    }

    serde_json::to_string(&HostSnapshot {
        host_name: host.id().name(),
        devices,
    })
}

/// Probes the default cpal host and returns a newly allocated UTF-8 JSON string.
///
/// The returned pointer must be freed with [hum_cpal_free_string]. Returns null
/// on serialization failure or panic.
#[unsafe(no_mangle)]
pub extern "C" fn hum_cpal_probe_devices_json() -> *mut c_char {
    let Ok(Ok(json)) = catch_unwind(AssertUnwindSafe(probe_devices_json)) else {
        return ptr::null_mut();
    };
    CString::new(json).map_or(ptr::null_mut(), CString::into_raw)
}

/// Frees a C string allocated by Rust (such as [hum_cpal_probe_devices_json]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn probes_host_devices_as_valid_json() {
        let raw = hum_cpal_probe_devices_json();
        assert!(!raw.is_null());

        unsafe {
            let json = CStr::from_ptr(raw).to_str().expect("valid UTF-8 JSON");
            let parsed: serde_json::Value = serde_json::from_str(json).expect("valid JSON payload");
            assert!(parsed["hostName"].is_string());
            assert!(parsed["devices"].is_array());
            hum_cpal_free_string(raw);
        }
    }
}

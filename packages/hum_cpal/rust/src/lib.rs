use std::ffi::c_char;

mod devices;
mod ffi;

#[unsafe(no_mangle)]
pub extern "C" fn hum_cpal_add(a: i32, b: i32) -> i32 {
    a + b
}

/// Probes the default cpal host and returns a newly allocated UTF-8 JSON string.
///
/// The returned pointer must be freed with [hum_cpal_free_string]. Returns null
/// on serialization failure or panic.
#[unsafe(no_mangle)]
pub extern "C" fn hum_cpal_probe_devices_json() -> *mut c_char {
    ffi::run_string_ffi(devices::probe_devices_json)
}

/// Frees a C string allocated by Rust (such as [hum_cpal_probe_devices_json]).
///
/// # Safety
/// `ptr` must be null or a live pointer returned by `hum_cpal_*`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_free_string(ptr: *mut c_char) {
    unsafe { ffi::free_c_string(ptr) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn probes_host_devices_over_ffi() {
        let raw = hum_cpal_probe_devices_json();
        assert!(!raw.is_null());

        unsafe {
            let json = CStr::from_ptr(raw).to_str().expect("valid UTF-8 JSON");
            assert!(json.contains("\"hostName\""));
            hum_cpal_free_string(raw);
        }
    }
}

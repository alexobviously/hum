use std::ffi::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::capture::HumCaptureHandle;
use crate::playback::HumPlaybackHandle;

mod capture;
mod devices;
mod ffi;
mod playback;

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

/// Creates and starts a playback stream for [device_id], or the default output
/// device when `device_id` is null.
///
/// # Safety
/// - `device_id` must be null or point to a valid NUL-terminated UTF-8 C string.
/// - `out_error` must be null or point to writable aligned `*mut c_char` storage.
///   Any non-null string written to `*out_error` must be freed via
///   [hum_cpal_free_string].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_create(
    device_id: *const c_char,
    sample_rate: u32,
    channels: u32,
    buffer_frames: u32,
    hardware_buffer_frames: u32,
    out_error: *mut *mut c_char,
) -> *mut HumPlaybackHandle {
    unsafe { ffi::clear_out_error(out_error) };

    let device_id = match unsafe { ffi::c_str_opt(device_id) } {
        Ok(id) => id,
        Err(msg) => {
            unsafe { ffi::write_out_error(out_error, &msg) };
            return ptr::null_mut();
        }
    };

    match catch_unwind(AssertUnwindSafe(|| {
        HumPlaybackHandle::create(
            device_id,
            sample_rate,
            channels,
            buffer_frames,
            hardware_buffer_frames,
        )
    })) {
        Ok(Ok(handle)) => Box::into_raw(Box::new(handle)),
        Ok(Err(msg)) => {
            unsafe { ffi::write_out_error(out_error, &msg) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe {
                ffi::write_out_error(
                    out_error,
                    "Unexpected panic creating cpal playback",
                )
            };
            ptr::null_mut()
        }
    }
}

/// Returns how many whole frames can be written without blocking.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_playback_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_available_write(
    handle: *const HumPlaybackHandle,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    handle.available_write_frames()
}

/// Writes up to `frames` interleaved `f32` frames into the playback ring buffer.
///
/// # Safety
/// - `handle` must be null or a live pointer returned by [hum_cpal_playback_create]
///   and not mutated concurrently on another thread.
/// - If `handle` and `data` are non-null and `frames > 0`, `data` must point to at
///   least `frames * channels` readable `f32` elements.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_write(
    handle: *mut HumPlaybackHandle,
    data: *const f32,
    frames: u32,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        return 0;
    };
    if data.is_null() || frames == 0 {
        return 0;
    }
    let Some(sample_count) = (frames as usize).checked_mul(handle.channels())
    else {
        return 0;
    };
    let slice = unsafe { std::slice::from_raw_parts(data, sample_count) };
    handle.write_frames(slice)
}

/// Returns `true` if the handle is null or the stream stopped unexpectedly.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_playback_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_is_stopped(
    handle: *const HumPlaybackHandle,
) -> bool {
    // https://www.youtube.com/watch?v=bLHL75H_VEM
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return true;
    };
    handle.is_stopped()
}

/// Returns the stream error message if one occurred and clears it.
///
/// Non-null return values must be freed with [hum_cpal_free_string].
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_playback_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_take_error(
    handle: *const HumPlaybackHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    match handle.take_error() {
        Some(err) => ffi::into_c_string(&err),
        None => ptr::null_mut(),
    }
}

/// Returns the number of hardware callback underruns observed so far.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_playback_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_underruns(
    handle: *const HumPlaybackHandle,
) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    handle.underruns()
}

/// Stops and frees a playback handle. No-op when `handle` is null.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_playback_create]
/// that has not already been closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_playback_close(
    handle: *mut HumPlaybackHandle,
) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Creates and starts an input capture stream for `device_id`, or the default
/// input device when `device_id` is null.
///
/// # Safety
/// - `device_id` must be null or point to a valid NUL-terminated UTF-8 C string.
/// - `out_error` must be null or point to writable aligned `*mut c_char` storage.
///   Any non-null string written to `*out_error` must be freed via
///   [hum_cpal_free_string].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_create(
    device_id: *const c_char,
    sample_rate: u32,
    channels: u32,
    buffer_frames: u32,
    hardware_buffer_frames: u32,
    out_error: *mut *mut c_char,
) -> *mut HumCaptureHandle {
    unsafe { ffi::clear_out_error(out_error) };

    let device_id = match unsafe { ffi::c_str_opt(device_id) } {
        Ok(id) => id,
        Err(msg) => {
            unsafe { ffi::write_out_error(out_error, &msg) };
            return ptr::null_mut();
        }
    };

    match catch_unwind(AssertUnwindSafe(|| {
        HumCaptureHandle::create(
            device_id,
            sample_rate,
            channels,
            buffer_frames,
            hardware_buffer_frames,
        )
    })) {
        Ok(Ok(handle)) => Box::into_raw(Box::new(handle)),
        Ok(Err(msg)) => {
            unsafe { ffi::write_out_error(out_error, &msg) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe {
                ffi::write_out_error(
                    out_error,
                    "Unexpected panic creating cpal capture",
                )
            };
            ptr::null_mut()
        }
    }
}

/// Returns how many whole frames are buffered and ready to read without blocking.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_capture_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_available_read(
    handle: *const HumCaptureHandle,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };

    handle.available_read_frames()
}

/// Reads up to `frames` interleaved `f32` frames from the capture ring buffer.
///
/// # Safety
/// - `handle` must be null or a live pointer returned by [hum_cpal_capture_create]
///   and not mutated concurrently on another thread.
/// - If `handle` and `data` are non-null and `frames > 0`, `data` must point to at
///   least `frames * channels` writable `f32` elements.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_read(
    handle: *mut HumCaptureHandle,
    data: *mut f32,
    frames: u32,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        return 0;
    };

    if data.is_null() || frames == 0 {
        return 0;
    }

    let Some(sample_count) = (frames as usize).checked_mul(handle.channels())
    else {
        return 0;
    };

    let slice = unsafe { std::slice::from_raw_parts_mut(data, sample_count) };
    handle.read_frames(slice)
}

/// Returns `true` if the handle is null or the capture stream stopped unexpectedly.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_capture_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_is_stopped(
    handle: *const HumCaptureHandle,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return true;
    };

    handle.is_stopped()
}

/// Returns the capture stream error message if one occurred and clears it.
///
/// Non-null return values must be freed with [hum_cpal_free_string].
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_capture_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_take_error(
    handle: *const HumCaptureHandle,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };

    match handle.take_error() {
        Some(err) => ffi::into_c_string(&err),
        None => ptr::null_mut(),
    }
}

/// Returns the number of hardware callback overruns observed so far.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_capture_create].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_overruns(
    handle: *const HumCaptureHandle,
) -> u64 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    handle.overruns()
}

/// Stops and frees a capture handle. No-op when `handle` is null.
///
/// # Safety
/// `handle` must be null or a live pointer returned by [hum_cpal_capture_create]
/// that has not already been closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_cpal_capture_close(handle: *mut HumCaptureHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
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

    #[test]
    fn reports_error_over_ffi_and_cleans_up_nulls() {
        let mut out_err: *mut c_char = ptr::null_mut();
        unsafe {
            let handle = hum_cpal_playback_create(
                ptr::null(),
                0,
                2,
                1024,
                0,
                &mut out_err,
            );
            assert!(handle.is_null());
            assert!(!out_err.is_null());

            let msg = CStr::from_ptr(out_err).to_str().expect("valid UTF-8");
            assert!(msg.contains("sampleRate"));
            hum_cpal_free_string(out_err);

            assert_eq!(hum_cpal_playback_available_write(ptr::null()), 0);
            assert_eq!(
                hum_cpal_playback_write(ptr::null_mut(), ptr::null(), 64),
                0
            );
            assert!(hum_cpal_playback_is_stopped(ptr::null()));
            assert!(hum_cpal_playback_take_error(ptr::null()).is_null());
            assert_eq!(hum_cpal_playback_underruns(ptr::null()), 0);
            hum_cpal_playback_close(ptr::null_mut());
        }
    }

    #[test]
    fn reports_capture_error_over_ffi_and_cleans_up_nulls() {
        let mut out_err: *mut c_char = ptr::null_mut();
        unsafe {
            let handle = hum_cpal_capture_create(
                ptr::null(),
                0,
                1,
                1024,
                0,
                &mut out_err,
            );
            assert!(handle.is_null());
            assert!(!out_err.is_null());

            let msg = CStr::from_ptr(out_err).to_str().expect("valid UTF-8");
            assert!(msg.contains("sampleRate"));
            hum_cpal_free_string(out_err);

            assert_eq!(hum_cpal_capture_available_read(ptr::null()), 0);
            assert_eq!(
                hum_cpal_capture_read(ptr::null_mut(), ptr::null_mut(), 64),
                0
            );
            assert!(hum_cpal_capture_is_stopped(ptr::null()));
            assert!(hum_cpal_capture_take_error(ptr::null()).is_null());
            assert_eq!(hum_cpal_capture_overruns(ptr::null()), 0);
            hum_cpal_capture_close(ptr::null_mut());
        }
    }
}

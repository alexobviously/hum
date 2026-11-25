mod decode;

use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::slice;

/// Result struct populated by [`hum_codecs_decode`] and freed by
/// [`hum_codecs_free_result`].
#[repr(C)]
pub struct HumDecodedBuffer {
    pub samples_ptr: *mut f32,
    pub samples_len: usize,
    pub num_frames: u32,
    pub num_channels: u32,
    pub sample_rate: u32,
    pub error_ptr: *mut c_char,
}

fn c_string_ptr(msg: &str) -> *mut c_char {
    let sanitized = msg.replace('\0', " ");
    match CString::new(sanitized) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Decodes encoded audio bytes into planar 32-bit float samples.
///
/// Returns `0` on success and non-zero on failure. In both cases, callers must
/// release any allocated buffers in `out_result` with [`hum_codecs_free_result`].
///
/// # Safety
/// - `out_result` must be a valid, writable pointer to a [`HumDecodedBuffer`].
/// - If `bytes_len > 0`, `bytes_ptr` must be valid for reads of `bytes_len` bytes.
/// - If `hint_ptr` is non-null, it must point to a valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_codecs_decode(
    bytes_ptr: *const u8,
    bytes_len: usize,
    hint_ptr: *const c_char,
    out_result: *mut HumDecodedBuffer,
) -> i32 {
    if out_result.is_null() {
        return -1;
    }

    unsafe {
        *out_result = HumDecodedBuffer {
            samples_ptr: ptr::null_mut(),
            samples_len: 0,
            num_frames: 0,
            num_channels: 0,
            sample_rate: 0,
            error_ptr: ptr::null_mut(),
        };
    }

    if bytes_ptr.is_null() || bytes_len == 0 {
        unsafe {
            (*out_result).error_ptr =
                c_string_ptr("Input audio buffer is empty");
        }
        return -2;
    }

    let bytes = unsafe { slice::from_raw_parts(bytes_ptr, bytes_len) };
    let hint = if hint_ptr.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(hint_ptr) }.to_str().ok()
    };

    match decode::decode_audio(bytes, hint) {
        Ok(decoded) => {
            let boxed = decoded.samples.into_boxed_slice();
            let len = boxed.len();
            let raw_ptr = if len > 0 {
                Box::into_raw(boxed) as *mut f32
            } else {
                ptr::null_mut()
            };
            unsafe {
                (*out_result).samples_ptr = raw_ptr;
                (*out_result).samples_len = len;
                (*out_result).num_frames = decoded.num_frames;
                (*out_result).num_channels = decoded.num_channels;
                (*out_result).sample_rate = decoded.sample_rate;
            }
            0
        }
        Err(err) => {
            unsafe {
                (*out_result).error_ptr = c_string_ptr(&err);
            }
            -3
        }
    }
}

/// Frees buffers allocated by [`hum_codecs_decode`].
///
/// # Safety
/// `result` must be either null or a pointer previously populated by
/// [`hum_codecs_decode`], and must not be freed more than once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hum_codecs_free_result(result: *mut HumDecodedBuffer) {
    if result.is_null() {
        return;
    }
    unsafe {
        let r = &mut *result;
        if !r.samples_ptr.is_null() && r.samples_len > 0 {
            let slice_ptr =
                ptr::slice_from_raw_parts_mut(r.samples_ptr, r.samples_len);
            drop(Box::from_raw(slice_ptr));
        }
        if !r.error_ptr.is_null() {
            drop(CString::from_raw(r.error_ptr));
        }
        r.samples_ptr = ptr::null_mut();
        r.samples_len = 0;
        r.error_ptr = ptr::null_mut();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_reports_error_and_frees_cleanly() {
        let mut out = HumDecodedBuffer {
            samples_ptr: ptr::null_mut(),
            samples_len: 0,
            num_frames: 0,
            num_channels: 0,
            sample_rate: 0,
            error_ptr: ptr::null_mut(),
        };
        let bad = b"not audio";
        let rc = unsafe {
            hum_codecs_decode(bad.as_ptr(), bad.len(), ptr::null(), &mut out)
        };
        assert_ne!(rc, 0);
        assert!(!out.error_ptr.is_null());
        unsafe { hum_codecs_free_result(&mut out) };
        assert!(out.error_ptr.is_null());
        assert!(out.samples_ptr.is_null());
    }
}

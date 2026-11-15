use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, UnwindSafe, catch_unwind};
use std::ptr;

/// Converts an optional nullable C string pointer into an optional `&str`.
///
/// Returns `Ok(None)` when `ptr` is null, or `Err` if the bytes are not valid UTF-8.
///
/// # Safety
/// If `ptr` is non-null, it must point to a valid NUL-terminated C string for `'a`.
pub unsafe fn c_str_opt<'a>(
    ptr: *const c_char,
) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        return Ok(None);
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(Some)
        .map_err(|_| String::from("Invalid UTF-8 string argument"))
}

/// Allocates a newly owned C string from a Rust `&str`, returning null if it
/// contains interior NUL bytes.
pub fn into_c_string(value: &str) -> *mut c_char {
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
}

/// Writes an error message into an optional `*mut *mut c_char` out-parameter.
///
/// Always resets `*out_error` to null first when `out_error` is non-null.
///
/// # Safety
/// `out_error` must be null or point to valid writable pointer storage.
pub unsafe fn write_out_error(out_error: *mut *mut c_char, message: &str) {
    if !out_error.is_null() {
        unsafe { *out_error = into_c_string(message) };
    }
}

/// Clears an optional `*mut *mut c_char` out-parameter to null.
///
/// # Safety
/// `out_error` must be null or point to valid writable pointer storage.
pub unsafe fn clear_out_error(out_error: *mut *mut c_char) {
    if !out_error.is_null() {
        unsafe { *out_error = ptr::null_mut() };
    }
}

/// Runs a string-returning closure across FFI without unwinding panics.
///
/// Returns null if the closure panics, returns `Err`, or produces an interior
/// NUL byte. Non-null pointers must be freed via [free_c_string].
pub fn run_string_ffi<E>(
    f: impl FnOnce() -> Result<String, E> + UnwindSafe,
) -> *mut c_char {
    let Ok(Ok(value)) = catch_unwind(AssertUnwindSafe(f)) else {
        return ptr::null_mut();
    };
    into_c_string(&value)
}

/// Frees a C string previously allocated by [CString::into_raw].
///
/// # Safety
/// `ptr` must either be null or a pointer returned by Rust via `CString::into_raw`
/// that has not yet been freed.
pub unsafe fn free_c_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

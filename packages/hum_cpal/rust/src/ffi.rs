use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, UnwindSafe, catch_unwind};
use std::ptr;

/// Runs a string-returning closure across FFI without unwinding panics.
///
/// Returns null if the closure panics, returns `Err`, or produces an interior
/// NUL byte. Non-null pointers must be freed via [free_c_string].
pub fn run_string_ffi<E>(f: impl FnOnce() -> Result<String, E> + UnwindSafe) -> *mut c_char {
    let Ok(Ok(value)) = catch_unwind(AssertUnwindSafe(f)) else {
        return ptr::null_mut();
    };
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
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

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::Mutex;

use olico_core::clipboard::Service;

pub struct OlicoHandle {
    service: Mutex<Service>,
}

fn json_error(code: &str, message: &str) -> *mut c_char {
    let body = serde_json::json!({
        "v": 1,
        "ok": false,
        "error": {"code": code, "message": message}
    })
    .to_string();
    CString::new(body)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn json_to_c(body: String) -> *mut c_char {
    CString::new(body)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Opens the core with the given data directory.
///
/// # Safety
/// `data_dir` must be null or a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn olico_core_new(data_dir: *const c_char) -> *mut OlicoHandle {
    if data_dir.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(|| {
        let Ok(dir) = CStr::from_ptr(data_dir).to_str() else {
            return std::ptr::null_mut();
        };
        match Service::open(Path::new(dir)) {
            Ok(service) => Box::into_raw(Box::new(OlicoHandle {
                service: Mutex::new(service),
            })),
            Err(_) => std::ptr::null_mut(),
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Releases a handle returned by [`olico_core_new`].
///
/// # Safety
/// `handle` must be null or a pointer previously returned by [`olico_core_new`]
/// that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn olico_core_free(handle: *mut OlicoHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(handle))));
}

/// Handles one JSON request and returns an owned JSON response string.
///
/// # Safety
/// `handle` must be a live handle from [`olico_core_new`] and `request_json`
/// must be null or a valid NUL-terminated UTF-8 string. The returned pointer
/// must be released with [`olico_string_free`].
#[no_mangle]
pub unsafe extern "C" fn olico_dispatch(
    handle: *mut OlicoHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() || request_json.is_null() {
        return json_error("invalid_handle", "null handle or request");
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(raw) = CStr::from_ptr(request_json).to_str() else {
            return json_error("invalid_payload", "request is not valid utf-8");
        };
        let handle = &*handle;
        let mut service = match handle.service.lock() {
            Ok(service) => service,
            Err(_) => return json_error("internal_error", "lock poisoned"),
        };
        json_to_c(olico_core::dispatch::dispatch(&mut service, raw))
    }))
    .unwrap_or_else(|_| json_error("internal_error", "panic"))
}

/// Frees a string returned by [`olico_dispatch`].
///
/// # Safety
/// `ptr` must be null or a pointer returned by [`olico_dispatch`] that has not
/// been freed.
#[no_mangle]
pub unsafe extern "C" fn olico_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

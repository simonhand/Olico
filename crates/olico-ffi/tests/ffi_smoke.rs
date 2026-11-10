use olico_ffi::{olico_core_free, olico_core_new, olico_dispatch, olico_string_free};
use std::ffi::{CStr, CString};
use tempfile::tempdir;

unsafe fn take_string(ptr: *mut std::ffi::c_char) -> String {
    assert!(!ptr.is_null());
    let text = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    olico_string_free(ptr);
    text
}

#[test]
fn config_get_via_ffi() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        assert!(!handle.is_null());
        let request = CString::new(r#"{"v":1,"op":"config_get","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(handle, request.as_ptr()));
        assert!(response.contains("\"ok\":true"));
        olico_core_free(handle);
    }
}

#[test]
fn clipboard_roundtrip_via_ffi() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        let add =
            CString::new(r#"{"v":1,"op":"clipboard_add","payload":{"kind":"text","text":"ffi"}}"#)
                .unwrap();
        let response = take_string(olico_dispatch(handle, add.as_ptr()));
        assert!(response.contains("\"ok\":true"));
        let list = CString::new(r#"{"v":1,"op":"clipboard_list","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(handle, list.as_ptr()));
        assert!(response.contains("\"text\":\"ffi\""));
        olico_core_free(handle);
    }
}

#[test]
fn invalid_json_returns_error_json() {
    let dir = tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    unsafe {
        let handle = olico_core_new(path.as_ptr());
        let request = CString::new("not json").unwrap();
        let response = take_string(olico_dispatch(handle, request.as_ptr()));
        assert!(response.contains("\"ok\":false"));
        assert!(response.contains("invalid_payload"));
        olico_core_free(handle);
    }
}

#[test]
fn null_handle_returns_error_json() {
    unsafe {
        let request = CString::new(r#"{"v":1,"op":"config_get","payload":{}}"#).unwrap();
        let response = take_string(olico_dispatch(std::ptr::null_mut(), request.as_ptr()));
        assert!(response.contains("\"ok\":false"));
    }
}

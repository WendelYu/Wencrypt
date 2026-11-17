use std::{
    ffi::{c_char, CString},
    sync::Mutex,
};
use zeroize::Zeroize;
static VAULT: Mutex<crate::vault::Vault> = Mutex::new(crate::vault::Vault::new());

#[no_mangle]
pub extern "C" fn wencrypt_alloc(len: usize) -> *mut u8 {
    if len == 0 || len > 2 * 1024 * 1024 {
        return std::ptr::null_mut();
    }
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}
/// # Safety
/// `ptr` must be an allocation returned by wencrypt_alloc with the same length, freed once.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let mut bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    bytes.zeroize();
}
/// # Safety
/// Input must point to len readable bytes for the duration of this synchronous call.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_command(ptr: *const u8, len: usize) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if ptr.is_null() || len > 2 * 1024 * 1024 {
            return Err("request_limit");
        }
        let input = std::slice::from_raw_parts(ptr, len);
        let mut value: serde_json::Value =
            serde_json::from_slice(input).map_err(|_| "invalid_json")?;
        let output = VAULT
            .lock()
            .map_err(|_| "core_unavailable")?
            .command(&value);
        wipe_value(&mut value);
        output
    })
    .unwrap_or(Err("core_unavailable"));
    let mut output = match result {
        Ok(v) => serde_json::json!({"ok":true,"result":v}),
        Err(e) => serde_json::json!({"ok":false,"error":e}),
    };
    let encoded = serde_json::to_vec(&output)
        .unwrap_or_else(|_| b"{\"ok\":false,\"error\":\"encoding\"}".to_vec());
    wipe_value(&mut output);
    CString::new(encoded).unwrap().into_raw()
}
fn wipe_value(v: &mut serde_json::Value) {
    match v {
        serde_json::Value::String(s) => s.zeroize(),
        serde_json::Value::Array(a) => {
            for v in a {
                wipe_value(v)
            }
        }
        serde_json::Value::Object(m) => {
            for v in m.values_mut() {
                wipe_value(v)
            }
        }
        _ => {}
    }
}
/// # Safety
/// ptr must be a live result returned by wencrypt_command and freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_result_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let mut bytes = CString::from_raw(ptr).into_bytes_with_nul();
    bytes.zeroize();
}

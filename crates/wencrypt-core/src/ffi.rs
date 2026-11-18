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

/// # Safety
/// Ticket must be valid UTF-8 bytes; output must point to 80 writable bytes.
/// Called only by native platform code, never through a Dart byte array.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_device_take(ticket: *const u8, len: usize, out: *mut u8) -> i32 {
    if ticket.is_null() || out.is_null() || len != 32 {
        return -1;
    }
    let result = std::panic::catch_unwind(|| {
        let ticket =
            std::str::from_utf8(std::slice::from_raw_parts(ticket, len)).map_err(|_| ())?;
        let payload = VAULT
            .lock()
            .map_err(|_| ())?
            .take_device_key(ticket)
            .map_err(|_| ())?;
        std::ptr::copy_nonoverlapping(payload.as_ptr(), out, 80);
        Ok::<_, ()>(())
    });
    if matches!(result, Ok(Ok(()))) {
        0
    } else {
        -1
    }
}
/// # Safety
/// Path points to path_len UTF-8 bytes, payload to 80 readable bytes,
/// token_out to 32 writable bytes. Native caller must wipe payload after return.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_device_open(
    path: *const u8,
    path_len: usize,
    payload: *const u8,
    epoch: u64,
    token_out: *mut u8,
) -> i32 {
    if path.is_null() || payload.is_null() || token_out.is_null() || path_len > 8192 {
        return -1;
    }
    let result = std::panic::catch_unwind(|| {
        let path =
            std::str::from_utf8(std::slice::from_raw_parts(path, path_len)).map_err(|_| ())?;
        let payload = std::slice::from_raw_parts(payload, 80);
        let token = VAULT
            .lock()
            .map_err(|_| ())?
            .open_device_key(path, payload, epoch)
            .map_err(|_| ())?;
        std::ptr::copy_nonoverlapping(token.as_ptr(), token_out, 32);
        Ok::<_, ()>(())
    });
    if matches!(result, Ok(Ok(()))) {
        0
    } else {
        -1
    }
}

/// # Safety
/// Payload must point to 80 readable bytes and ticket_out to 32 writable bytes.
/// Only the native hardware-backed authentication bridge calls this function.
#[no_mangle]
pub unsafe extern "C" fn wencrypt_device_backup_grant(
    payload: *const u8,
    epoch: u64,
    ticket_out: *mut u8,
) -> i32 {
    if payload.is_null() || ticket_out.is_null() {
        return -1;
    }
    let result = std::panic::catch_unwind(|| {
        let payload = std::slice::from_raw_parts(payload, 80);
        let ticket = VAULT
            .lock()
            .map_err(|_| ())?
            .authorize_device_backup(payload, epoch)
            .map_err(|_| ())?;
        std::ptr::copy_nonoverlapping(ticket.as_ptr(), ticket_out, 32);
        Ok::<_, ()>(())
    });
    if matches!(result, Ok(Ok(()))) {
        0
    } else {
        -1
    }
}

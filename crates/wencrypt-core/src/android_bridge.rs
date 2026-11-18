use jni::{
    objects::{JByteArray, JObject, JString},
    sys::{jbyteArray, jlong, jstring},
    JNIEnv,
};
use zeroize::Zeroizing;

#[no_mangle]
pub extern "system" fn Java_org_wencrypt_wencrypt_NativeVaultBridge_take(
    mut env: JNIEnv,
    _this: JObject,
    ticket: JString,
) -> jbyteArray {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let ticket: String = env.get_string(&ticket).ok()?.into();
        let mut bytes = Zeroizing::new([0u8; 80]);
        if unsafe {
            crate::ffi::wencrypt_device_take(ticket.as_ptr(), ticket.len(), bytes.as_mut_ptr())
        } != 0
        {
            return None;
        }
        Some(env.byte_array_from_slice(&*bytes).ok()?.into_raw())
    }));
    result.ok().flatten().unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub extern "system" fn Java_org_wencrypt_wencrypt_NativeVaultBridge_open(
    mut env: JNIEnv,
    _this: JObject,
    path: JString,
    body: JByteArray,
    epoch: jlong,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let path: String = env.get_string(&path).ok()?.into();
        let bytes = Zeroizing::new(env.convert_byte_array(&body).ok()?);
        if bytes.len() != 80 || epoch < 0 {
            return None;
        }
        let mut token = [0u8; 32];
        if unsafe {
            crate::ffi::wencrypt_device_open(
                path.as_ptr(),
                path.len(),
                bytes.as_ptr(),
                epoch as u64,
                token.as_mut_ptr(),
            )
        } != 0
        {
            return None;
        }
        Some(
            env.new_string(std::str::from_utf8(&token).ok()?)
                .ok()?
                .into_raw(),
        )
    }));
    result.ok().flatten().unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_org_wencrypt_wencrypt_NativeVaultBridge_backupGrant(
    env: JNIEnv,
    _this: JObject,
    body: JByteArray,
    epoch: jlong,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let body = Zeroizing::new(env.convert_byte_array(&body).ok()?);
        if body.len() != 80 || epoch < 0 {
            return None;
        }
        let mut ticket = Zeroizing::new([0u8; 32]);
        if unsafe {
            crate::ffi::wencrypt_device_backup_grant(
                body.as_ptr(),
                epoch as u64,
                ticket.as_mut_ptr(),
            )
        } != 0
        {
            return None;
        }
        Some(
            env.new_string(std::str::from_utf8(&*ticket).ok()?)
                .ok()?
                .into_raw(),
        )
    }));
    result.ok().flatten().unwrap_or(std::ptr::null_mut())
}

//! P0 protocol probes, not a production vault API.
pub mod envelope;
pub mod graph;
pub mod traffic;

pub fn build_info() -> String {
    format!(
        "Wencrypt core {} / WENC v1 prototype / {}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::ARCH
    )
}

/// P0 FFI surface. Only built-in, public test inputs are processed.
#[no_mangle]
pub extern "C" fn wencrypt_format_version() -> u32 {
    1
}

/// Returns the bootstrap unlock duration in milliseconds, or -1 on failure.
#[no_mangle]
pub extern "C" fn wencrypt_probe_unlock_ms() -> i64 {
    let password = "Wencrypt 公共测试 e\u{301} 密码";
    let marker = [0xa5; 32];
    let Ok(bootstrap) = envelope::create_bootstrap(password, &[1; 16], &marker) else {
        return -1;
    };
    let start = std::time::Instant::now();
    match envelope::unlock_bootstrap(password, &bootstrap) {
        Ok(dek) if *dek == marker && bootstrap.len() == envelope::BOOTSTRAP_LEN => {
            start.elapsed().as_millis().try_into().unwrap_or(-1)
        }
        _ => -1,
    }
}

#[cfg(target_os = "android")]
mod android_bridge;
mod ffi;
pub mod vault;

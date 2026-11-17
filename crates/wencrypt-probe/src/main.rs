fn main() {
    let start = std::time::Instant::now();
    let bytes =
        wencrypt_core::envelope::create_bootstrap("Wencrypt TEST ONLY 密码", &[1; 16], &[2; 32])
            .expect("P0 encryption failed");
    let create_ms = start.elapsed().as_millis();
    let start = std::time::Instant::now();
    let dek = wencrypt_core::envelope::unlock_bootstrap("Wencrypt TEST ONLY 密码", &bytes)
        .expect("P0 decryption failed");
    assert_eq!(*dek, [2; 32]);
    println!(
        "{}",
        serde_json::json!({"core":wencrypt_core::build_info(),"test_data_only":true,"bootstrap_bytes":bytes.len(),"argon2_memory_kib":65536,"argon2_iterations":3,"argon2_parallelism":1,"create_ms":create_ms,"unlock_ms":start.elapsed().as_millis()})
    );
}

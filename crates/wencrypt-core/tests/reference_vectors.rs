use wencrypt_core::envelope::{decrypt_object, unlock_bootstrap, Kind};

#[test]
fn python_reference_vectors() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../test-vectors/wenc-v1.json"
    ))
    .expect("run tools/generate_vectors.py first");
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    let dek: [u8; 32] = hex::decode(v["dek_hex"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    let id: [u8; 16] = hex::decode(v["vault_id_hex"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    for item in v["bootstrap_vectors"].as_array().unwrap() {
        let bytes = hex::decode(item["envelope_hex"].as_str().unwrap()).unwrap();
        assert_eq!(
            *unlock_bootstrap(item["password"].as_str().unwrap(), &bytes).unwrap(),
            dek
        );
        assert!(unlock_bootstrap("wrong-password", &bytes).is_err());
    }
    let bytes = hex::decode(v["revision"]["envelope_hex"].as_str().unwrap()).unwrap();
    let expected = hex::decode(v["revision"]["cbor_hex"].as_str().unwrap()).unwrap();
    assert_eq!(
        &**decrypt_object(&dek, &id, Kind::Revision, &bytes).unwrap(),
        expected
    );
}

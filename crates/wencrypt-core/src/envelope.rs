//! Fixed binary framing. Revision bodies are opaque in P0: schema validation is P1.
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use std::sync::Mutex;
use zeroize::Zeroizing;

pub const HEADER_LEN: usize = 75;
pub const BOOTSTRAP_HEADER_LEN: usize = 87;
pub const BOOTSTRAP_LEN: usize = 135;
static KDF_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Format,
    Bounds,
    Authentication,
    Random,
    Kdf,
}
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Bootstrap = 1,
    Revision = 2,
    Backup = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KdfParams {
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}
impl Default for KdfParams {
    fn default() -> Self {
        Self {
            memory_kib: 65536,
            iterations: 3,
            parallelism: 1,
        }
    }
}
impl KdfParams {
    fn validate(self) -> Result<()> {
        if !(65536..=262144).contains(&self.memory_kib)
            || !(3..=10).contains(&self.iterations)
            || !(1..=4).contains(&self.parallelism)
        {
            return Err(Error::Bounds);
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct Header {
    pub kind: Kind,
    pub vault_id: [u8; 16],
    pub salt: [u8; 32],
    pub nonce: [u8; 12],
    pub cipher_len: usize,
    pub kdf: Option<KdfParams>,
}
fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn max_len(kind: Kind) -> usize {
    match kind {
        Kind::Bootstrap => BOOTSTRAP_LEN,
        Kind::Revision => 1024 * 1024,
        Kind::Backup => 256 * 1024 * 1024,
    }
}

pub fn parse(bytes: &[u8]) -> Result<(Header, &[u8], &[u8])> {
    if bytes.len() < HEADER_LEN || &bytes[..8] != b"WENCRYPT" || bytes[8..10] != [1, 0] {
        return Err(Error::Format);
    }
    let kind = match bytes[10] {
        1 => Kind::Bootstrap,
        2 => Kind::Revision,
        3 => Kind::Backup,
        _ => return Err(Error::Format),
    };
    let n = if kind == Kind::Bootstrap {
        BOOTSTRAP_HEADER_LEN
    } else {
        HEADER_LEN
    };
    if bytes.len() < n || bytes.len() > max_len(kind) {
        return Err(Error::Bounds);
    }
    let cipher_len = u32_at(bytes, 71) as usize;
    if cipher_len < 16 || n.checked_add(cipher_len) != Some(bytes.len()) {
        return Err(Error::Bounds);
    }
    let kdf = if kind == Kind::Bootstrap {
        if bytes.len() != BOOTSTRAP_LEN || cipher_len != 48 {
            return Err(Error::Bounds);
        }
        let p = KdfParams {
            memory_kib: u32_at(bytes, 75),
            iterations: u32_at(bytes, 79),
            parallelism: u32_at(bytes, 83),
        };
        p.validate()?;
        Some(p)
    } else {
        None
    };
    Ok((
        Header {
            kind,
            vault_id: bytes[11..27].try_into().unwrap(),
            salt: bytes[27..59].try_into().unwrap(),
            nonce: bytes[59..71].try_into().unwrap(),
            cipher_len,
            kdf,
        },
        &bytes[..n],
        &bytes[n..],
    ))
}

fn header(
    kind: Kind,
    id: &[u8; 16],
    salt: &[u8; 32],
    nonce: &[u8; 12],
    len: usize,
    kdf: Option<KdfParams>,
) -> Result<Vec<u8>> {
    let n = if kind == Kind::Bootstrap {
        BOOTSTRAP_HEADER_LEN
    } else {
        HEADER_LEN
    };
    if len.checked_add(n).filter(|v| *v <= max_len(kind)).is_none() {
        return Err(Error::Bounds);
    }
    let mut b = Vec::with_capacity(n);
    b.extend(b"WENCRYPT");
    b.extend(1u16.to_le_bytes());
    b.push(kind as u8);
    b.extend(id);
    b.extend(salt);
    b.extend(nonce);
    b.extend((len as u32).to_le_bytes());
    if let Some(p) = kdf {
        p.validate()?;
        b.extend(p.memory_kib.to_le_bytes());
        b.extend(p.iterations.to_le_bytes());
        b.extend(p.parallelism.to_le_bytes());
    }
    Ok(b)
}
fn derive(password: &str, salt: &[u8; 32], p: KdfParams) -> Result<Zeroizing<[u8; 32]>> {
    if password.len() > 1024 {
        return Err(Error::Bounds);
    }
    p.validate()?;
    let _guard = KDF_LOCK.lock().map_err(|_| Error::Kdf)?;
    let params =
        Params::new(p.memory_kib, p.iterations, p.parallelism, Some(32)).map_err(|_| Error::Kdf)?;
    let mut key = Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), salt, &mut *key)
        .map_err(|_| Error::Kdf)?;
    Ok(key)
}
fn object_key(
    dek: &[u8; 32],
    id: &[u8; 16],
    salt: &[u8; 32],
    kind: Kind,
) -> Result<Zeroizing<[u8; 32]>> {
    let mut info = b"wencrypt/v1/object/".to_vec();
    info.push(kind as u8);
    info.extend(id);
    let mut key = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(salt), dek)
        .expand(&info, &mut *key)
        .map_err(|_| Error::Kdf)?;
    Ok(key)
}
fn seal(key: &[u8; 32], nonce: &[u8; 12], mut aad: Vec<u8>, plaintext: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| Error::Format)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| Error::Authentication)?;
    aad.extend(encrypted);
    Ok(aad)
}
fn open(key: &[u8; 32], h: &Header, aad: &[u8], body: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| Error::Format)?;
    cipher
        .decrypt(Nonce::from_slice(&h.nonce), Payload { msg: body, aad })
        .map(Zeroizing::new)
        .map_err(|_| Error::Authentication)
}
pub fn create_bootstrap(password: &str, id: &[u8; 16], dek: &[u8; 32]) -> Result<Vec<u8>> {
    if password.chars().count() < 12 || password.len() > 1024 {
        return Err(Error::Bounds);
    }
    let mut salt = [0; 32];
    let mut nonce = [0; 12];
    getrandom::getrandom(&mut salt).map_err(|_| Error::Random)?;
    getrandom::getrandom(&mut nonce).map_err(|_| Error::Random)?;
    let p = KdfParams::default();
    let key = derive(password, &salt, p)?;
    seal(
        &key,
        &nonce,
        header(Kind::Bootstrap, id, &salt, &nonce, 48, Some(p))?,
        dek,
    )
}
pub fn unlock_bootstrap(password: &str, bytes: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let (h, aad, body) = parse(bytes)?;
    if h.kind != Kind::Bootstrap {
        return Err(Error::Format);
    }
    let key = derive(password, &h.salt, h.kdf.ok_or(Error::Format)?)?;
    let plaintext = open(&key, &h, aad, body)?;
    let mut dek = Zeroizing::new([0u8; 32]);
    dek.copy_from_slice(&plaintext);
    Ok(dek)
}
pub fn encrypt_object(
    dek: &[u8; 32],
    id: &[u8; 16],
    kind: Kind,
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    if kind == Kind::Bootstrap {
        return Err(Error::Format);
    }
    // Check bounds before crypto or allocation.
    if plaintext.len() > max_len(kind) - HEADER_LEN - 16 {
        return Err(Error::Bounds);
    }
    let mut salt = [0; 32];
    let mut nonce = [0; 12];
    getrandom::getrandom(&mut salt).map_err(|_| Error::Random)?;
    getrandom::getrandom(&mut nonce).map_err(|_| Error::Random)?;
    let key = object_key(dek, id, &salt, kind)?;
    seal(
        &key,
        &nonce,
        header(kind, id, &salt, &nonce, plaintext.len() + 16, None)?,
        plaintext,
    )
}
pub fn decrypt_object(
    dek: &[u8; 32],
    expected_id: &[u8; 16],
    expected_kind: Kind,
    bytes: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    let (h, aad, body) = parse(bytes)?;
    if h.kind == Kind::Bootstrap || h.kind != expected_kind || &h.vault_id != expected_id {
        return Err(Error::Format);
    }
    let key = object_key(dek, &h.vault_id, &h.salt, h.kind)?;
    open(&key, &h, aad, body)
}

pub fn seal_ephemeral(
    key: &[u8; 32],
    info: &[u8],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    if plaintext.len() > 2 * 1024 * 1024 {
        return Err(Error::Bounds);
    }
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut salt).map_err(|_| Error::Random)?;
    getrandom::getrandom(&mut nonce).map_err(|_| Error::Random)?;
    let mut subkey = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(&salt), key)
        .expand(info, &mut *subkey)
        .map_err(|_| Error::Kdf)?;
    let mut full_aad = Vec::with_capacity(28 + aad.len());
    full_aad.extend_from_slice(&salt);
    full_aad.extend_from_slice(&nonce);
    full_aad.extend_from_slice(aad);
    let cipher = Aes256Gcm::new_from_slice(&*subkey).map_err(|_| Error::Format)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &full_aad,
            },
        )
        .map_err(|_| Error::Authentication)?;
    let mut out = Vec::with_capacity(28 + encrypted.len());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&encrypted);
    Ok(out)
}

pub fn open_ephemeral(
    key: &[u8; 32],
    info: &[u8],
    aad: &[u8],
    ciphertext: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    if ciphertext.len() < 44 || ciphertext.len() > 2 * 1024 * 1024 + 44 {
        return Err(Error::Bounds);
    }
    let (salt, rest) = ciphertext.split_at(16);
    let (nonce, body) = rest.split_at(12);
    let mut subkey = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(salt), key)
        .expand(info, &mut *subkey)
        .map_err(|_| Error::Kdf)?;
    let mut full_aad = Vec::with_capacity(28 + aad.len());
    full_aad.extend_from_slice(salt);
    full_aad.extend_from_slice(nonce);
    full_aad.extend_from_slice(aad);
    let cipher = Aes256Gcm::new_from_slice(&*subkey).map_err(|_| Error::Format)?;
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: body,
                aad: &full_aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| Error::Authentication)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn header_lengths_and_malformed_input() {
        assert_eq!(
            header(
                Kind::Bootstrap,
                &[0; 16],
                &[1; 32],
                &[2; 12],
                48,
                Some(KdfParams::default())
            )
            .unwrap()
            .len(),
            87
        );
        for n in 0..87 {
            assert!(parse(&vec![0; n]).is_err());
        }
        let mut b = header(
            Kind::Bootstrap,
            &[0; 16],
            &[1; 32],
            &[2; 12],
            48,
            Some(KdfParams::default()),
        )
        .unwrap();
        b.extend([0; 48]);
        assert!(parse(&b).is_ok());
        b[75..79].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(parse(&b).unwrap_err(), Error::Bounds);
    }
    #[test]
    fn object_roundtrip_tamper_and_randomization() {
        let a = encrypt_object(&[3; 32], &[4; 16], Kind::Revision, b"test-only").unwrap();
        let b = encrypt_object(&[3; 32], &[4; 16], Kind::Revision, b"test-only").unwrap();
        assert_ne!(a, b);
        assert_eq!(
            &**decrypt_object(&[3; 32], &[4; 16], Kind::Revision, &a).unwrap(),
            b"test-only"
        );
        for i in 0..a.len() {
            let mut bad = a.clone();
            bad[i] ^= 1;
            assert!(
                decrypt_object(&[3; 32], &[4; 16], Kind::Revision, &bad).is_err(),
                "byte {i}"
            );
        }
        let mut extra = a.clone();
        extra.push(0);
        assert!(parse(&extra).is_err());
        assert!(decrypt_object(&[3; 32], &[4; 16], Kind::Backup, &a).is_err());
    }
    #[test]
    fn password_utf8_and_authentication() {
        let password = "  中文主密码 e\u{301} 👩‍💻  ";
        let b = create_bootstrap(password, &[5; 16], &[6; 32]).unwrap();
        assert_eq!(b.len(), 135);
        assert_eq!(*unlock_bootstrap(password, &b).unwrap(), [6; 32]);
        assert!(unlock_bootstrap(password.trim(), &b).is_err());
        assert!(unlock_bootstrap(&password.replace("e\u{301}", "é"), &b).is_err());
    }
    #[test]
    fn ephemeral_roundtrip_and_domain_separation() {
        let key = [7u8; 32];
        let wrong_key = [8u8; 32];
        let ct =
            seal_ephemeral(&key, b"wencrypt/lan/v1/seed", b"aad-1", b"secret-payload").unwrap();
        assert_eq!(
            &**open_ephemeral(&key, b"wencrypt/lan/v1/seed", b"aad-1", &ct).unwrap(),
            b"secret-payload"
        );
        assert_eq!(
            open_ephemeral(&wrong_key, b"wencrypt/lan/v1/seed", b"aad-1", &ct).unwrap_err(),
            Error::Authentication
        );
        assert_eq!(
            open_ephemeral(&key, b"wencrypt/lan/v1/pack", b"aad-1", &ct).unwrap_err(),
            Error::Authentication
        );
        assert_eq!(
            open_ephemeral(&key, b"wencrypt/lan/v1/seed", b"aad-2", &ct).unwrap_err(),
            Error::Authentication
        );
        for i in 0..ct.len() {
            let mut tampered = ct.clone();
            tampered[i] ^= 1;
            assert!(open_ephemeral(&key, b"wencrypt/lan/v1/seed", b"aad-1", &tampered).is_err());
        }
        assert_eq!(
            open_ephemeral(&key, b"wencrypt/lan/v1/seed", b"aad-1", &ct[..43]).unwrap_err(),
            Error::Bounds
        );
    }
}

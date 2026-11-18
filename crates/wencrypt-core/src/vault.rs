//! Alpha local vault. Only authenticated ciphertext is persisted.
use crate::{
    envelope::{self, Kind},
    graph,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};
use zeroize::{Zeroize, Zeroizing};

type Result<T> = std::result::Result<T, &'static str>;
const LIMIT: usize = 10000;
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub title: String,
    pub username: String,
    pub password: String,
    pub url: String,
    pub notes: String,
    pub tags: String,
}
impl Drop for Entry {
    fn drop(&mut self) {
        self.title.zeroize();
        self.username.zeroize();
        self.password.zeroize();
        self.url.zeroize();
        self.notes.zeroize();
        self.tags.zeroize();
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Revision {
    schema: u32,
    id: String,
    entry: String,
    parents: Vec<String>,
    deleted: bool,
    updated_at: u64,
    data: Entry,
}
struct Session {
    token: String,
    db: Connection,
    id: [u8; 16],
    dek: Zeroizing<[u8; 32]>,
    revisions: BTreeMap<String, Revision>,
}
#[derive(Default)]
pub struct Vault {
    session: Option<Session>,
    epoch: u64,
    grant: Option<DeviceGrant>,
}
struct DeviceGrant {
    ticket: String,
    session: String,
    expires: std::time::Instant,
}
fn random<const N: usize>() -> Result<[u8; N]> {
    let mut b = [0; N];
    getrandom::getrandom(&mut b).map_err(|_| "random_failed")?;
    Ok(b)
}
fn identifier() -> Result<String> {
    Ok(hex::encode(random::<16>()?))
}
fn valid_id(s: &str) -> bool {
    s.len() == 32
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn crypto<T>(r: envelope::Result<T>) -> Result<T> {
    r.map_err(|_| "authentication_or_format_failed")
}
fn sql<T>(r: rusqlite::Result<T>) -> Result<T> {
    r.map_err(|_| "storage_failed")
}
fn connection(path: &str, create: bool) -> Result<Connection> {
    let mut flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE;
    if create {
        flags |= rusqlite::OpenFlags::SQLITE_OPEN_CREATE;
    }
    let db = sql(Connection::open_with_flags(path, flags))?;
    sql(db.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;",
    ))?;
    if create {
        sql(db.execute_batch("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL); CREATE TABLE IF NOT EXISTS objects (hash TEXT PRIMARY KEY, body BLOB NOT NULL);"))?;
    }
    Ok(db)
}
// Install a fully committed database without replacing any existing vault.
fn install(path: &str, bootstrap: &[u8], objects: &[Vec<u8>]) -> Result<()> {
    let temporary = format!("{}.{}.stage", path, identifier()?);
    let result = (|| {
        let mut db = connection(&temporary, true)?;
        let tx = sql(db.transaction())?;
        sql(tx.execute(
            "INSERT INTO metadata VALUES ('bootstrap',?1)",
            params![bootstrap],
        ))?;
        for body in objects {
            sql(tx.execute(
                "INSERT INTO objects VALUES (?1,?2)",
                params![hex::encode(Sha256::digest(body)), body],
            ))?;
        }
        sql(tx.commit())?;
        sql(db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);"))?;
        db.close().map_err(|_| "storage_failed")?;
        std::fs::File::open(&temporary)
            .and_then(|f| f.sync_all())
            .map_err(|_| "storage_failed")?;
        std::fs::hard_link(&temporary, path).map_err(|_| "install_failed_or_exists")?;
        Ok(())
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}
fn bootstrap(db: &Connection) -> Result<Vec<u8>> {
    sql(db.query_row(
        "SELECT value FROM metadata WHERE key='bootstrap'",
        [],
        |r| r.get(0),
    ))
}
fn view(revisions: &BTreeMap<String, Revision>) -> Result<graph::View> {
    graph::evaluate(
        &revisions
            .values()
            .map(|r| graph::Revision {
                id: r.id.clone(),
                entry: r.entry.clone(),
                parents: r.parents.clone(),
                deleted: r.deleted,
            })
            .collect::<Vec<_>>(),
    )
}
fn decode(dek: &[u8; 32], id: &[u8; 16], bytes: &[u8]) -> Result<Revision> {
    let plain = crypto(envelope::decrypt_object(dek, id, Kind::Revision, bytes))?;
    let mut reader = std::io::Cursor::new(&*plain);
    let r: Revision = ciborium::from_reader(&mut reader).map_err(|_| "invalid_revision")?;
    if reader.position() as usize != plain.len()
        || r.schema != 1
        || !valid_id(&r.id)
        || !valid_id(&r.entry)
        || r.parents.len() > 64
        || r.parents.iter().any(|p| !valid_id(p))
    {
        return Err("invalid_revision");
    }
    validate_entry(&r.data)?;
    Ok(r)
}
fn validate_entry(e: &Entry) -> Result<()> {
    if e.title.trim().is_empty()
        || [
            &e.title,
            &e.username,
            &e.password,
            &e.url,
            &e.notes,
            &e.tags,
        ]
        .iter()
        .any(|s| s.len() > 16384)
    {
        return Err("invalid_entry");
    }
    Ok(())
}
fn load(db: &Connection, dek: &[u8; 32], id: &[u8; 16]) -> Result<BTreeMap<String, Revision>> {
    let (count, size): (usize, usize) = sql(db.query_row(
        "SELECT count(*),coalesce(sum(length(body)),0) FROM objects",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    ))?;
    if count > LIMIT || size > 64 * 1024 * 1024 {
        return Err("vault_limit");
    }
    let mut stmt = sql(db.prepare("SELECT hash,body FROM objects"))?;
    let rows = sql(stmt.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    }))?;
    let mut revisions = BTreeMap::new();
    for row in rows {
        let (hash, bytes) = sql(row)?;
        if hex::encode(Sha256::digest(&bytes)) != hash {
            return Err("object_hash_mismatch");
        }
        let r = decode(dek, id, &bytes)?;
        if revisions.insert(r.id.clone(), r).is_some() {
            return Err("duplicate_revision");
        }
    }
    view(&revisions)?;
    Ok(revisions)
}
fn field<'a>(v: &'a Value, name: &str) -> Result<&'a str> {
    v.get(name).and_then(Value::as_str).ok_or("invalid_request")
}
impl Vault {
    pub const fn new() -> Self {
        Self {
            session: None,
            epoch: 0,
            grant: None,
        }
    }
    // Native-only: one-use grant issued after rechecking the master password.
    pub(crate) fn take_device_key(&mut self, ticket: &str) -> Result<Zeroizing<[u8; 80]>> {
        let grant = self.grant.take().ok_or("grant_missing")?;
        let s = self.session.as_ref().ok_or("locked")?;
        if grant.ticket != ticket
            || grant.session != s.token
            || std::time::Instant::now() > grant.expires
        {
            return Err("grant_expired");
        }
        let mut bytes = Zeroizing::new([0u8; 80]);
        bytes[..16].copy_from_slice(&s.id);
        bytes[16..48].copy_from_slice(&Sha256::digest(bootstrap(&s.db)?));
        bytes[48..].copy_from_slice(&*s.dek);
        Ok(bytes)
    }
    pub(crate) fn open_device_key(
        &mut self,
        path: &str,
        payload: &[u8],
        epoch: u64,
    ) -> Result<String> {
        if epoch != self.epoch {
            return Err("session_expired");
        }
        self.session = None;
        self.grant = None;
        if payload.len() != 80 {
            return Err("invalid_device_payload");
        }
        let db = connection(path, false)?;
        let b = bootstrap(&db)?;
        let id = crypto(envelope::parse(&b))?.0.vault_id;
        if payload[..16] != id || payload[16..48] != Sha256::digest(&b)[..] {
            return Err("device_binding_mismatch");
        }
        let mut dek = Zeroizing::new([0u8; 32]);
        dek.copy_from_slice(&payload[48..]);
        let proof: Vec<u8> = sql(db.query_row(
            "SELECT value FROM metadata WHERE key='device-key-proof'",
            [],
            |r| r.get(0),
        ))?;
        let expected = crypto(envelope::decrypt_object(&dek, &id, Kind::Backup, &proof))?;
        if expected.as_slice() != Sha256::digest(&b).as_slice() {
            return Err("device_binding_mismatch");
        }
        let revisions = load(&db, &dek, &id)?;
        let token = identifier()?;
        self.session = Some(Session {
            token: token.clone(),
            db,
            id,
            dek,
            revisions,
        });
        Ok(token)
    }
    pub fn command(&mut self, v: &Value) -> Result<Value> {
        let op = field(v, "op")?;
        if let Some(epoch) = v.get("epoch").and_then(Value::as_u64) {
            if op == "lock" && epoch >= self.epoch {
                self.epoch = epoch;
            }
            if epoch != self.epoch {
                return Err("session_expired");
            }
        }
        if op == "lock" {
            self.session = None;
            self.grant = None;
            return Ok(json!({"locked":true}));
        }
        if op == "device_info" {
            let db = connection(field(v, "path")?, false)?;
            let b = bootstrap(&db)?;
            crypto(envelope::parse(&b))?;
            return Ok(json!({"binding":hex::encode(Sha256::digest(&b))}));
        }
        if op == "restore" {
            self.session = None;
            let path = field(v, "path")?;
            if Path::new(path).exists() {
                return Err("vault_already_exists");
            }
            let b = hex::decode(field(v, "bootstrap")?).map_err(|_| "invalid_backup")?;
            let key = crypto(envelope::unlock_bootstrap(field(v, "password")?, &b))?;
            let id = crypto(envelope::parse(&b))?.0.vault_id;
            let backup = hex::decode(field(v, "backup")?).map_err(|_| "invalid_backup")?;
            let plain = crypto(envelope::decrypt_object(&key, &id, Kind::Backup, &backup))?;
            let objects: Vec<String> =
                serde_json::from_slice(&plain).map_err(|_| "invalid_backup")?;
            if objects.len() > LIMIT {
                return Err("vault_limit");
            }
            let mut revisions = BTreeMap::new();
            let mut bodies = Vec::new();
            let mut total = 0;
            for object in objects {
                let bytes = hex::decode(object).map_err(|_| "invalid_backup")?;
                total += bytes.len();
                if total > 64 * 1024 * 1024 {
                    return Err("vault_limit");
                }
                let r = decode(&key, &id, &bytes)?;
                if revisions.insert(r.id.clone(), r).is_some() {
                    return Err("duplicate_revision");
                }
                bodies.push(bytes);
            }
            if !view(&revisions)?.pending.is_empty() {
                return Err("incomplete_backup");
            }
            install(path, &b, &bodies)?;
            return Ok(json!({"restored":true}));
        }
        if op == "create" || op == "unlock" {
            self.session = None;
            let path = field(v, "path")?;
            let password = field(v, "password")?;
            if op == "create" && Path::new(path).exists() {
                return Err("vault_already_exists");
            }
            if op == "create" && (password.chars().count() < 12 || password.len() > 1024) {
                return Err("password_length");
            }
            if op == "create" {
                let id = random::<16>()?;
                let dek = Zeroizing::new(random::<32>()?);
                let b = crypto(envelope::create_bootstrap(password, &id, &dek))?;
                install(path, &b, &[])?;
            }
            let db = connection(path, false)?;
            let b = bootstrap(&db)?;
            let id = crypto(envelope::parse(&b))?.0.vault_id;
            let dek = crypto(envelope::unlock_bootstrap(password, &b))?;
            let revisions = load(&db, &dek, &id)?;
            let token = identifier()?;
            self.session = Some(Session {
                token: token.clone(),
                db,
                id,
                dek,
                revisions,
            });
            return Ok(json!({"session":token}));
        }
        let s = self.session.as_mut().ok_or("locked")?;
        if field(v, "session")? != s.token {
            return Err("session_expired");
        }
        match op {
            "device_grant" => {
                let b = bootstrap(&s.db)?;
                let key = crypto(envelope::unlock_bootstrap(field(v, "password")?, &b))?;
                if *key != *s.dek {
                    return Err("authentication_failed");
                }
                let proof = crypto(envelope::encrypt_object(
                    &key,
                    &s.id,
                    Kind::Backup,
                    &Sha256::digest(&b),
                ))?;
                sql(s.db.execute(
                    "INSERT OR REPLACE INTO metadata VALUES ('device-key-proof',?1)",
                    params![proof],
                ))?;
                let ticket = identifier()?;
                self.grant = Some(DeviceGrant {
                    ticket: ticket.clone(),
                    session: s.token.clone(),
                    expires: std::time::Instant::now() + std::time::Duration::from_secs(60),
                });
                Ok(json!({"ticket":ticket,"binding":hex::encode(Sha256::digest(&b))}))
            }
            "sync_settings_set" => {
                let settings = v.get("settings").ok_or("invalid_settings")?;
                let username = field(settings, "username")?;
                let password = field(settings, "password")?;
                if username.len() > 320 || password.len() > 1024 || username.contains(':') {
                    return Err("invalid_settings");
                }
                let plain = Zeroizing::new(
                    serde_json::to_vec(
                        &json!({"purpose":"wencrypt-local-sync-settings-v1","settings":settings}),
                    )
                    .map_err(|_| "encode_failed")?,
                );
                let bytes = crypto(envelope::encrypt_object(
                    &s.dek,
                    &s.id,
                    Kind::Backup,
                    &plain,
                ))?;
                sql(s.db.execute(
                    "INSERT OR REPLACE INTO metadata VALUES ('local-sync-settings',?1)",
                    params![bytes],
                ))?;
                Ok(json!({"saved":true}))
            }
            "sync_settings_get" => {
                let bytes: Option<Vec<u8>> = sql(s
                    .db
                    .query_row(
                        "SELECT value FROM metadata WHERE key='local-sync-settings'",
                        [],
                        |r| r.get(0),
                    )
                    .optional())?;
                match bytes {
                    None => Ok(json!({"settings":null})),
                    Some(bytes) => {
                        let plain = crypto(envelope::decrypt_object(
                            &s.dek,
                            &s.id,
                            Kind::Backup,
                            &bytes,
                        ))?;
                        let value: Value =
                            serde_json::from_slice(&plain).map_err(|_| "invalid_settings")?;
                        if value["purpose"] != "wencrypt-local-sync-settings-v1" {
                            return Err("invalid_settings");
                        }
                        Ok(json!({"settings":value["settings"]}))
                    }
                }
            }
            "sync_settings_clear" => {
                sql(s
                    .db
                    .execute("DELETE FROM metadata WHERE key='local-sync-settings'", []))?;
                Ok(json!({"removed":true}))
            }
            "list" => {
                // Refresh from disk so another writer cannot be silently overwritten.
                s.revisions = load(&s.db, &s.dek, &s.id)?;
                let state = view(&s.revisions)?;
                let entries = state
                    .heads
                    .iter()
                    .map(|id| &s.revisions[id])
                    .collect::<Vec<_>>();
                Ok(
                    json!({"entries":entries,"pending":state.pending.len(),"vault":hex::encode(s.id)}),
                )
            }
            "history" => {
                let entry = field(v, "entry")?;
                Ok(
                    json!({"revisions":s.revisions.values().filter(|r|r.entry==entry).collect::<Vec<_>>()}),
                )
            }
            "import" => {
                let entries: Vec<Entry> =
                    serde_json::from_value(v.get("entries").cloned().ok_or("invalid_entries")?)
                        .map_err(|_| "invalid_entries")?;
                if entries.is_empty() || entries.len() > 500 {
                    return Err("import_limit");
                }
                for entry in &entries {
                    validate_entry(entry)?;
                }
                let tx = sql(s
                    .db
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
                let mut revisions = load(&tx, &s.dek, &s.id)?;
                if revisions.len() + entries.len() > LIMIT {
                    return Err("vault_limit");
                }
                for data in entries {
                    let r = Revision {
                        schema: 1,
                        id: identifier()?,
                        entry: identifier()?,
                        parents: vec![],
                        deleted: false,
                        updated_at: std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map_err(|_| "clock_failed")?
                            .as_secs(),
                        data,
                    };
                    let mut plain = Zeroizing::new(Vec::new());
                    ciborium::into_writer(&r, &mut *plain).map_err(|_| "encode_failed")?;
                    let bytes = crypto(envelope::encrypt_object(
                        &s.dek,
                        &s.id,
                        Kind::Revision,
                        &plain,
                    ))?;
                    sql(tx.execute(
                        "INSERT INTO objects VALUES (?1,?2)",
                        params![hex::encode(Sha256::digest(&bytes)), bytes],
                    ))?;
                    revisions.insert(r.id.clone(), r);
                }
                sql(tx.commit())?;
                s.revisions = revisions;
                Ok(json!({"imported":true}))
            }
            "save" => {
                let data: Entry =
                    serde_json::from_value(v.get("data").cloned().ok_or("invalid_entry")?)
                        .map_err(|_| "invalid_entry")?;
                validate_entry(&data)?;
                let entry = match v.get("entry").and_then(Value::as_str) {
                    Some(e) if valid_id(e) => e.to_owned(),
                    None => identifier()?,
                    _ => return Err("invalid_entry_id"),
                };
                let parents: Vec<String> =
                    serde_json::from_value(v.get("parents").cloned().unwrap_or(json!([])))
                        .map_err(|_| "invalid_parents")?;
                let tx = sql(s
                    .db
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
                let mut current = load(&tx, &s.dek, &s.id)?;
                let state = view(&current)?;
                let heads: BTreeSet<String> = state
                    .heads
                    .iter()
                    .filter(|id| current[*id].entry == entry)
                    .cloned()
                    .collect();
                if heads != parents.iter().cloned().collect()
                    || parents.len() != heads.len()
                    || parents.len() > 64
                {
                    return Err("entry_changed_reload");
                }
                if !state.pending.is_empty() {
                    return Err("missing_ancestry");
                }
                if current.len() >= LIMIT {
                    return Err("vault_limit");
                }
                let r = Revision {
                    schema: 1,
                    id: identifier()?,
                    entry,
                    parents,
                    deleted: v.get("deleted").and_then(Value::as_bool).unwrap_or(false),
                    updated_at: std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_err(|_| "clock_failed")?
                        .as_secs(),
                    data,
                };
                let mut plain = Zeroizing::new(Vec::new());
                ciborium::into_writer(&r, &mut *plain).map_err(|_| "encode_failed")?;
                let bytes = crypto(envelope::encrypt_object(
                    &s.dek,
                    &s.id,
                    Kind::Revision,
                    &plain,
                ))?;
                sql(tx.execute(
                    "INSERT INTO objects VALUES (?1,?2)",
                    params![hex::encode(Sha256::digest(&bytes)), bytes],
                ))?;
                sql(tx.commit())?;
                current.insert(r.id.clone(), r);
                s.revisions = current;
                Ok(json!({"saved":true}))
            }
            "sync_objects" => {
                let b = bootstrap(&s.db)?;
                let mut stmt = sql(s.db.prepare("SELECT hash,body FROM objects ORDER BY hash"))?;
                let objects = sql(stmt.query_map([], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
                }))?
                .map(|r| sql(r).map(|(hash, b)| json!({"hash":hash,"body":hex::encode(b)})))
                .collect::<Result<Vec<_>>>()?;
                Ok(json!({"vault":hex::encode(s.id),"bootstrap":hex::encode(b),"objects":objects}))
            }
            "ingest" => {
                let bytes = hex::decode(field(v, "body")?).map_err(|_| "invalid_object")?;
                let hash = hex::encode(Sha256::digest(&bytes));
                if hash != field(v, "hash")? {
                    return Err("object_hash_mismatch");
                }
                decode(&s.dek, &s.id, &bytes)?;
                let tx = sql(s
                    .db
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
                sql(tx.execute(
                    "INSERT OR IGNORE INTO objects VALUES (?1,?2)",
                    params![hash, bytes],
                ))?;
                let current = load(&tx, &s.dek, &s.id)?;
                sql(tx.commit())?;
                s.revisions = current;
                Ok(json!({"received":true}))
            }
            "export" => {
                s.revisions = load(&s.db, &s.dek, &s.id)?;
                if !view(&s.revisions)?.pending.is_empty() {
                    return Err("incomplete_backup");
                }
                let b = bootstrap(&s.db)?;
                let key = crypto(envelope::unlock_bootstrap(field(v, "password")?, &b))?;
                if *key != *s.dek {
                    return Err("authentication_failed");
                }
                let mut stmt = sql(s.db.prepare("SELECT body FROM objects ORDER BY hash"))?;
                let objects = sql(stmt.query_map([], |r| r.get::<_, Vec<u8>>(0)))?
                    .map(|r| sql(r).map(hex::encode))
                    .collect::<Result<Vec<_>>>()?;
                // Outer AEAD authenticates the complete set, including an empty vault.
                let plain =
                    Zeroizing::new(serde_json::to_vec(&objects).map_err(|_| "encode_failed")?);
                let backup = crypto(envelope::encrypt_object(
                    &s.dek,
                    &s.id,
                    Kind::Backup,
                    &plain,
                ))?;
                Ok(
                    json!({"format":"WENBACK1-alpha","bootstrap":hex::encode(b),"backup":hex::encode(backup)}),
                )
            }
            _ => Err("unknown_operation"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(password: &str) -> Value {
        json!({"title":"测试账号","username":"alice","password":password,"url":"https://example.com","notes":"","tags":"测试"})
    }
    fn call(v: &mut Vault, token: &str, mut request: Value) -> Value {
        request["session"] = json!(token);
        v.command(&request).unwrap()
    }
    #[test]
    fn device_grants_are_one_use_bound_and_invalidated_by_lock() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let mut v = Vault::new();
        let pass = "device binding test password";
        let t = v
            .command(&json!({"op":"create","path":path,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        call(
            &mut v,
            &t,
            json!({"op":"save","data":entry("device-secret")}),
        );
        assert!(v
            .command(&json!({"op":"device_grant","session":t,"password":"wrong"}))
            .is_err());
        let grant = call(&mut v, &t, json!({"op":"device_grant","password":pass}));
        let ticket = grant["ticket"].as_str().unwrap();
        let payload = v.take_device_key(ticket).unwrap();
        assert!(v.take_device_key(ticket).is_err());
        v.command(&json!({"op":"lock","epoch":1})).unwrap();
        assert!(v
            .open_device_key(path.to_str().unwrap(), &*payload, 0)
            .is_err());
        let t = v
            .open_device_key(path.to_str().unwrap(), &*payload, 1)
            .unwrap();
        assert_eq!(
            call(&mut v, &t, json!({"op":"list"}))["entries"][0]["data"]["password"],
            "device-secret"
        );
        let mut wrong = payload.clone();
        wrong[16] ^= 1;
        assert!(v
            .open_device_key(path.to_str().unwrap(), &*wrong, 1)
            .is_err());
        assert!(v.session.is_none());
    }
    #[test]
    fn sync_credentials_stay_local_encrypted_and_locked() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let mut v = Vault::new();
        let pass = "local credentials test password";
        let t = v
            .command(&json!({"op":"create","path":path,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        let secret = "NEVER-SYNC-THIS-APP-PASSWORD";
        call(
            &mut v,
            &t,
            json!({"op":"sync_settings_set","settings":{"username":"test@example.com","password":secret,"auto":true}}),
        );
        assert_eq!(
            call(&mut v, &t, json!({"op":"sync_settings_get"}))["settings"]["password"],
            secret
        );
        let objects = call(&mut v, &t, json!({"op":"sync_objects"}));
        assert!(objects["objects"].as_array().unwrap().is_empty());
        let backup = call(&mut v, &t, json!({"op":"export","password":pass}));
        let restored = dir.path().join("restored.db");
        v.command(&json!({"op":"restore","path":restored,"password":pass,"bootstrap":backup["bootstrap"],"backup":backup["backup"]})).unwrap();
        let t = v
            .command(&json!({"op":"unlock","path":restored,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            call(&mut v, &t, json!({"op":"sync_settings_get"}))["settings"],
            Value::Null
        );
        for f in std::fs::read_dir(dir.path()).unwrap() {
            let b = std::fs::read(f.unwrap().path()).unwrap();
            assert!(!b.windows(secret.len()).any(|w| w == secret.as_bytes()));
        }
    }
    #[test]
    fn queued_unlock_cannot_reopen_after_lock() {
        let mut v = Vault::new();
        v.command(&json!({"op":"lock","epoch":2})).unwrap();
        assert_eq!(
            v.command(&json!({"op":"unlock","epoch":1,"path":"unused","password":"unused"}))
                .unwrap_err(),
            "session_expired"
        );
        assert!(v.session.is_none());
    }
    #[test]
    fn rejected_create_leaves_no_vault() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let mut v = Vault::new();
        assert!(v
            .command(&json!({"op":"create","path":path,"password":"short"}))
            .is_err());
        assert!(!path.exists());
    }
    #[test]
    fn offline_restart_conflict_backup_and_disk_secrecy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let pass = "my strong test password";
        let mut v = Vault::new();
        let token = v
            .command(&json!({"op":"create","path":path,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        let marker = "SECRET-MUST-NOT-EXIST-ON-DISK";
        call(&mut v, &token, json!({"op":"save","data":entry(marker)}));
        let list = call(&mut v, &token, json!({"op":"list"}));
        let rev = &list["entries"][0];
        let backup = call(&mut v, &token, json!({"op":"export","password":pass}));
        assert!(v.command(&json!({"op":"save","session":token,"entry":rev["entry"],"parents":[],"data":entry("stale")})).is_err());
        call(
            &mut v,
            &token,
            json!({"op":"save","entry":rev["entry"],"parents":[rev["id"]],"deleted":true,"data":entry(marker)}),
        );
        v.command(&json!({"op":"lock"})).unwrap();
        assert!(v.command(&json!({"op":"list","session":token})).is_err());
        assert!(v
            .command(&json!({"op":"unlock","path":path,"password":"wrong"}))
            .is_err());
        let token = v
            .command(&json!({"op":"unlock","path":path,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            call(&mut v, &token, json!({"op":"list"}))["entries"][0]["deleted"],
            true
        );
        for file in std::fs::read_dir(dir.path()).unwrap() {
            let bytes = std::fs::read(file.unwrap().path()).unwrap();
            assert!(!bytes.windows(marker.len()).any(|w| w == marker.as_bytes()));
        }
        let restored = dir.path().join("restored.db");
        v.command(&json!({"op":"restore","path":restored,"password":pass,"bootstrap":backup["bootstrap"],"backup":backup["backup"]})).unwrap();
        let token = v
            .command(&json!({"op":"unlock","path":restored,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            call(&mut v, &token, json!({"op":"list"}))["entries"][0]["data"]["password"],
            marker
        );
    }
    #[test]
    fn independent_edits_remain_conflicted_after_union() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.db");
        let b = dir.path().join("b.db");
        let pass = "another long password";
        let mut left = Vault::new();
        let mut right = Vault::new();
        let t = left
            .command(&json!({"op":"create","path":a,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        call(&mut left, &t, json!({"op":"save","data":entry("base")}));
        let base = call(&mut left, &t, json!({"op":"list"}))["entries"][0].clone();
        let bak = call(&mut left, &t, json!({"op":"export","password":pass}));
        right.command(&json!({"op":"restore","path":b,"password":pass,"bootstrap":bak["bootstrap"],"backup":bak["backup"]})).unwrap();
        let u = right
            .command(&json!({"op":"unlock","path":b,"password":pass}))
            .unwrap()["session"]
            .as_str()
            .unwrap()
            .to_owned();
        for (v, token, password) in [
            (&mut left, t.as_str(), "left"),
            (&mut right, u.as_str(), "right"),
        ] {
            call(
                v,
                token,
                json!({"op":"save","entry":base["entry"],"parents":[base["id"]],"data":entry(password)}),
            );
        }
        let objects = call(&mut right, &u, json!({"op":"sync_objects"}));
        for obj in objects["objects"].as_array().unwrap() {
            call(
                &mut left,
                &t,
                json!({"op":"ingest","hash":obj["hash"],"body":obj["body"]}),
            );
        }
        let list = call(&mut left, &t, json!({"op":"list"}));
        assert_eq!(list["entries"].as_array().unwrap().len(), 2);
        let parents = list["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["id"].clone())
            .collect::<Vec<_>>();
        call(
            &mut left,
            &t,
            json!({"op":"save","entry":base["entry"],"parents":parents,"data":entry("resolved")}),
        );
        assert_eq!(
            call(&mut left, &t, json!({"op":"list"}))["entries"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}

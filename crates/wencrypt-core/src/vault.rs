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
const PACK_LIMIT: usize = 512 * 1024;
const PACK_OBJECTS: usize = 128;
const PACK_MAGIC: &[u8] = b"WPK1";
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
// Encode clearing the trash as a schema-1 tombstone so earlier clients
// can still decrypt its revision and follow the same ancestry.
const DISCARDED_TITLE: &str = "已从回收站清除";
const DISCARDED_TAG: &str = "wencrypt:discarded:v1";

impl Revision {
    fn discarded(&self) -> bool {
        self.deleted
            && self.data.title == DISCARDED_TITLE
            && self.data.tags == DISCARDED_TAG
            && self.data.username.is_empty()
            && self.data.password.is_empty()
            && self.data.url.is_empty()
            && self.data.notes.is_empty()
    }
}

struct Session {
    token: String,
    db: Connection,
    id: [u8; 16],
    dek: Zeroizing<[u8; 32]>,
    revisions: BTreeMap<String, Revision>,
    backup_grant: Option<(String, std::time::Instant)>,
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
fn install(
    path: &str,
    bootstrap: &[u8],
    objects: &[Vec<u8>],
    sync_settings: Option<&[u8]>,
) -> Result<()> {
    let temporary = format!("{}.{}.stage", path, identifier()?);
    let result = (|| {
        let mut db = connection(&temporary, true)?;
        let tx = sql(db.transaction())?;
        sql(tx.execute(
            "INSERT INTO metadata VALUES ('bootstrap',?1)",
            params![bootstrap],
        ))?;
        if let Some(bytes) = sync_settings {
            sql(tx.execute(
                "INSERT INTO metadata VALUES ('local-sync-settings',?1)",
                params![bytes],
            ))?;
        }
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
fn sealed_sync_settings(dek: &[u8; 32], id: &[u8; 16], settings: &Value) -> Result<Vec<u8>> {
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
    crypto(envelope::encrypt_object(dek, id, Kind::Backup, &plain))
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
fn credential(e: &Entry) -> (&str, &str, &str, &str) {
    let url = e.url.trim();
    let title_without_url = if url.is_empty() { e.title.trim() } else { "" };
    (url, &e.username, &e.password, title_without_url)
}

fn merge_import_metadata(current: &mut Entry, incoming: &Entry) -> bool {
    let mut changed = false;
    let note = incoming.notes.trim();
    if !note.is_empty() {
        let existing = current.notes.trim();
        if existing.is_empty() {
            current.notes = note.to_owned();
            changed = true;
        } else if current.notes.len() + note.len() + 2 <= 16384 {
            let already_present = existing.char_indices().any(|(start, _)| {
                (start == 0 || existing[..start].ends_with("\n\n"))
                    && existing[start..]
                        .strip_prefix(note)
                        .is_some_and(|rest| rest.is_empty() || rest.starts_with("\n\n"))
            });
            if !already_present {
                current.notes.push_str("\n\n");
                current.notes.push_str(note);
                changed = true;
            }
        }
    }
    let tags = |c| matches!(c, ',' | '，' | ';' | '；');
    let mut existing = current
        .tags
        .split(tags)
        .map(|tag| tag.trim().to_lowercase())
        .collect::<BTreeSet<_>>();
    for tag in incoming.tags.split(tags).map(str::trim) {
        if tag.is_empty() || matches!(tag, "置顶") || tag.eq_ignore_ascii_case("pinned") {
            continue;
        }
        let separator = if current.tags.is_empty() { "" } else { ", " };
        if current.tags.len() + separator.len() + tag.len() <= 16384
            && existing.insert(tag.to_lowercase())
        {
            current.tags.push_str(separator);
            current.tags.push_str(tag);
            changed = true;
        }
    }
    changed
}

fn write_revision(
    db: &Connection,
    dek: &[u8; 32],
    vault: &[u8; 16],
    revision: &Revision,
) -> Result<()> {
    let mut plain = Zeroizing::new(Vec::new());
    ciborium::into_writer(revision, &mut *plain).map_err(|_| "encode_failed")?;
    let bytes = crypto(envelope::encrypt_object(dek, vault, Kind::Revision, &plain))?;
    sql(db.execute(
        "INSERT INTO objects VALUES (?1,?2)",
        params![hex::encode(Sha256::digest(&bytes)), bytes],
    ))?;
    Ok(())
}

fn object_hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn pack_objects(mut body: &[u8]) -> Result<Vec<&[u8]>> {
    if body.len() > PACK_LIMIT {
        return Err("invalid_sync_pack");
    }
    body = body.strip_prefix(PACK_MAGIC).ok_or("invalid_sync_pack")?;
    let mut objects = Vec::new();
    while !body.is_empty() {
        let (length, tail) = body.split_at_checked(4).ok_or("invalid_sync_pack")?;
        let len = u32::from_be_bytes(length.try_into().unwrap()) as usize;
        let (object, rest) = tail.split_at_checked(len).ok_or("invalid_sync_pack")?;
        if len == 0 || objects.len() == PACK_OBJECTS {
            return Err("invalid_sync_pack");
        }
        objects.push(object);
        body = rest;
    }
    if objects.is_empty() {
        return Err("invalid_sync_pack");
    }
    Ok(objects)
}

fn record_pack(db: &Connection, pack: &str, hashes: &[String]) -> Result<()> {
    let receipt = serde_json::to_vec(hashes).map_err(|_| "encode_failed")?;
    sql(db.execute(
        "INSERT OR IGNORE INTO metadata VALUES (?1,?2)",
        params![format!("sync-pack:{pack}"), receipt],
    ))?;
    Ok(())
}

fn ingest_objects(
    s: &mut Session,
    objects: &[&[u8]],
    hashes: &[String],
    pack: Option<&str>,
) -> Result<()> {
    let tx = sql(s
        .db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
    {
        let mut insert = sql(tx.prepare("INSERT OR IGNORE INTO objects VALUES (?1,?2)"))?;
        for (hash, body) in hashes.iter().zip(objects) {
            sql(insert.execute(params![hash, body]))?;
        }
    }
    // Authenticate all revisions and validate ancestry before committing the batch.
    let current = load(&tx, &s.dek, &s.id)?;
    view(&current)?;
    if let Some(pack) = pack {
        record_pack(&tx, pack, hashes)?;
    }
    sql(tx.commit())?;
    s.revisions = current;
    Ok(())
}

fn now() -> Result<u64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "clock_failed")?
        .as_secs())
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
            backup_grant: None,
        });
        Ok(token)
    }
    pub(crate) fn authorize_device_backup(&mut self, payload: &[u8], epoch: u64) -> Result<String> {
        if epoch != self.epoch {
            return Err("session_expired");
        }
        let s = self.session.as_mut().ok_or("locked")?;
        if payload.len() != 80
            || payload[..16] != s.id
            || payload[16..48] != Sha256::digest(bootstrap(&s.db)?)[..]
            || payload[48..] != s.dek[..]
        {
            return Err("device_binding_mismatch");
        }
        let ticket = identifier()?;
        s.backup_grant = Some((
            ticket.clone(),
            std::time::Instant::now() + std::time::Duration::from_secs(60),
        ));
        Ok(ticket)
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
            install(path, &b, &bodies, None)?;
            return Ok(json!({"restored":true}));
        }
        if matches!(op, "create" | "unlock" | "join") {
            self.session = None;
            let path = field(v, "path")?;
            let password = field(v, "password")?;
            if op != "unlock" && Path::new(path).exists() {
                return Err("vault_already_exists");
            }
            if op == "create" && (password.chars().count() < 12 || password.len() > 1024) {
                return Err("password_length");
            }
            if op == "create" {
                let id = random::<16>()?;
                let dek = Zeroizing::new(random::<32>()?);
                let b = crypto(envelope::create_bootstrap(password, &id, &dek))?;
                install(path, &b, &[], None)?;
            }
            let joined_key = if op == "join" {
                let b = hex::decode(field(v, "bootstrap")?).map_err(|_| "invalid_bootstrap")?;
                let key = crypto(envelope::unlock_bootstrap(password, &b))?;
                let id = crypto(envelope::parse(&b))?.0.vault_id;
                let settings = v
                    .get("settings")
                    .map(|settings| sealed_sync_settings(&key, &id, settings))
                    .transpose()?;
                install(path, &b, &[], settings.as_deref())?;
                Some(key)
            } else {
                None
            };
            let db = connection(path, false)?;
            let b = bootstrap(&db)?;
            let id = crypto(envelope::parse(&b))?.0.vault_id;
            let dek = match joined_key {
                Some(key) => key,
                None => crypto(envelope::unlock_bootstrap(password, &b))?,
            };
            let revisions = load(&db, &dek, &id)?;
            let token = identifier()?;
            self.session = Some(Session {
                token: token.clone(),
                db,
                id,
                dek,
                revisions,
                backup_grant: None,
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
                let bytes = sealed_sync_settings(&s.dek, &s.id, settings)?;
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
                let heads = state.heads.iter().map(|id| &s.revisions[id]);
                let visible = heads
                    .clone()
                    .filter(|r| !r.discarded())
                    .map(|r| &r.entry)
                    .collect::<BTreeSet<_>>();
                let entries = heads
                    .filter(|r| visible.contains(&r.entry))
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
                let state = view(&revisions)?;
                let mut batch: BTreeMap<_, Vec<_>> = BTreeMap::new();
                for entry in &entries {
                    batch.entry(credential(entry)).or_default().push(entry);
                }
                let mut head_counts = BTreeMap::new();
                let mut matches: BTreeMap<_, Vec<_>> = BTreeMap::new();
                for id in &state.heads {
                    let head = &revisions[id];
                    *head_counts.entry(&head.entry).or_insert(0) += 1;
                    if !head.deleted && batch.contains_key(&credential(&head.data)) {
                        matches
                            .entry(credential(&head.data))
                            .or_default()
                            .push(head);
                    }
                }

                let mut added = 0;
                let mut updated = 0;
                let mut writes = Vec::new();
                for (key, incoming) in batch {
                    let (entry, parents, mut data) = match matches.get(&key).map(Vec::as_slice) {
                        Some([head])
                            if head_counts[&head.entry] == 1 && state.pending.is_empty() =>
                        {
                            (head.entry.clone(), vec![head.id.clone()], head.data.clone())
                        }
                        Some(_) => continue,
                        None => (identifier()?, vec![], incoming[0].clone()),
                    };
                    let is_new = parents.is_empty();
                    let mut changed = false;
                    for next in incoming.iter().skip(usize::from(is_new)) {
                        changed |= merge_import_metadata(&mut data, next);
                    }
                    if !is_new && !changed {
                        continue;
                    }
                    added += usize::from(is_new);
                    updated += usize::from(!is_new);
                    writes.push(Revision {
                        schema: 1,
                        id: identifier()?,
                        entry,
                        parents,
                        deleted: false,
                        updated_at: now()?,
                        data,
                    });
                }
                if revisions.len() + writes.len() > LIMIT {
                    return Err("vault_limit");
                }
                for revision in writes {
                    write_revision(&tx, &s.dek, &s.id, &revision)?;
                    revisions.insert(revision.id.clone(), revision);
                }
                sql(tx.commit())?;
                s.revisions = revisions;
                Ok(
                    json!({"imported":true,"added":added,"updated":updated,"duplicates":entries.len()-added}),
                )
            }
            "set_deleted" | "discard_trash" => {
                let ids: BTreeSet<String> =
                    serde_json::from_value(v.get("heads").cloned().ok_or("invalid_entry_id")?)
                        .map_err(|_| "invalid_entry_id")?;
                let discard = op == "discard_trash";
                let deleted = discard
                    || v.get("deleted")
                        .and_then(Value::as_bool)
                        .ok_or("invalid_entry")?;
                let tx = sql(s
                    .db
                    .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
                let mut revisions = load(&tx, &s.dek, &s.id)?;
                let state = view(&revisions)?;
                if !state.pending.is_empty() {
                    return Err("missing_ancestry");
                }
                if ids.is_empty() || revisions.len() + ids.len() > LIMIT {
                    return Err("vault_limit");
                }
                let mut head_counts = BTreeMap::new();
                for id in &state.heads {
                    *head_counts.entry(&revisions[id].entry).or_insert(0) += 1;
                }
                let mut writes = Vec::with_capacity(ids.len());
                for id in &ids {
                    let head = revisions
                        .get(id)
                        .filter(|r| {
                            state.heads.contains(id)
                                && head_counts[&r.entry] == 1
                                && !r.discarded()
                                && r.deleted == (discard || !deleted)
                        })
                        .ok_or("entry_changed_reload")?;
                    let mut revision = head.clone();
                    revision.id = identifier()?;
                    revision.parents = vec![id.clone()];
                    if discard {
                        revision.data = Entry {
                            title: DISCARDED_TITLE.to_owned(),
                            tags: DISCARDED_TAG.to_owned(),
                            username: String::new(),
                            password: String::new(),
                            url: String::new(),
                            notes: String::new(),
                        };
                    }
                    revision.deleted = deleted;
                    revision.updated_at = now()?;
                    write_revision(&tx, &s.dek, &s.id, &revision)?;
                    writes.push(revision);
                }
                for revision in writes {
                    revisions.insert(revision.id.clone(), revision);
                }
                sql(tx.commit())?;
                s.revisions = revisions;
                Ok(json!({"changed":ids.len()}))
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
                if !heads.is_empty() && heads.iter().all(|id| current[id].discarded()) {
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
                    updated_at: now()?,
                    data,
                };
                write_revision(&tx, &s.dek, &s.id, &r)?;
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
            "sync_inventory" => {
                let mut stmt = sql(s
                    .db
                    .prepare("SELECT hash,length(body) FROM objects ORDER BY hash"))?;
                let objects = sql(
                    stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, usize>(1)?)))
                )?
                .map(sql)
                .collect::<Result<BTreeMap<_, _>>>()?;
                Ok(json!({
                    "vault":hex::encode(s.id),
                    "bootstrap":hex::encode(bootstrap(&s.db)?),
                    "objects":objects
                }))
            }
            "sync_receipts" => {
                let names: Vec<String> =
                    serde_json::from_value(v.get("packs").cloned().ok_or("invalid_sync_pack")?)
                        .map_err(|_| "invalid_sync_pack")?;
                let mut stmt = sql(s.db.prepare("SELECT value FROM metadata WHERE key=?1"))?;
                let mut receipts = BTreeMap::new();
                for name in names {
                    let stored = sql(stmt
                        .query_row(params![format!("sync-pack:{name}")], |r| {
                            r.get::<_, Vec<u8>>(0)
                        })
                        .optional())?;
                    if let Some(body) = stored {
                        let hashes: Vec<String> =
                            serde_json::from_slice(&body).map_err(|_| "invalid_sync_receipt")?;
                        receipts.insert(name, hashes);
                    }
                }
                Ok(json!({"packs":receipts}))
            }
            "sync_build_pack" => {
                let hashes: Vec<String> =
                    serde_json::from_value(v.get("hashes").cloned().ok_or("invalid_sync_pack")?)
                        .map_err(|_| "invalid_sync_pack")?;
                if hashes.is_empty()
                    || hashes.len() > PACK_OBJECTS
                    || hashes.iter().collect::<BTreeSet<_>>().len() != hashes.len()
                {
                    return Err("invalid_sync_pack");
                }
                let mut body = PACK_MAGIC.to_vec();
                let mut stmt = sql(s.db.prepare("SELECT body FROM objects WHERE hash=?1"))?;
                for hash in &hashes {
                    let bytes: Vec<u8> = sql(stmt.query_row(params![hash], |r| r.get(0)))?;
                    if body.len() + 4 + bytes.len() > PACK_LIMIT || object_hash(&bytes) != *hash {
                        return Err("invalid_sync_pack");
                    }
                    body.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
                    body.extend_from_slice(&bytes);
                }
                let pack = object_hash(&body);
                record_pack(&s.db, &pack, &hashes)?;
                Ok(json!({"hash":pack,"body":hex::encode(body)}))
            }
            "sync_ingest_pack" => {
                let body = hex::decode(field(v, "body")?).map_err(|_| "invalid_sync_pack")?;
                let pack = field(v, "hash")?;
                if object_hash(&body) != pack {
                    return Err("object_hash_mismatch");
                }
                let objects = pack_objects(&body)?;
                let hashes = objects
                    .iter()
                    .map(|bytes| object_hash(bytes))
                    .collect::<Vec<_>>();
                if hashes.iter().collect::<BTreeSet<_>>().len() != hashes.len() {
                    return Err("invalid_sync_pack");
                }
                ingest_objects(s, &objects, &hashes, Some(pack))?;
                Ok(json!({"hashes":hashes}))
            }
            "ingest" => {
                let bytes = hex::decode(field(v, "body")?).map_err(|_| "invalid_object")?;
                let hash = object_hash(&bytes);
                if hash != field(v, "hash")? {
                    return Err("object_hash_mismatch");
                }
                ingest_objects(s, &[&bytes], &[hash], None)?;
                Ok(json!({"received":true}))
            }
            "export" => {
                s.revisions = load(&s.db, &s.dek, &s.id)?;
                if !view(&s.revisions)?.pending.is_empty() {
                    return Err("incomplete_backup");
                }
                let b = bootstrap(&s.db)?;
                if let Some(ticket) = v.get("biometric_ticket").and_then(Value::as_str) {
                    let (expected, expires) =
                        s.backup_grant.take().ok_or("biometric_grant_expired")?;
                    if ticket != expected || std::time::Instant::now() > expires {
                        return Err("biometric_grant_expired");
                    }
                } else {
                    let key = crypto(envelope::unlock_bootstrap(field(v, "password")?, &b))?;
                    if *key != *s.dek {
                        return Err("authentication_failed");
                    }
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
    fn three_vaults_converge_beyond_the_legacy_directory_limit() {
        let dir = tempfile::tempdir().unwrap();
        let password = "public migration fixture passphrase";
        let mut source = Vault::new();
        let opened = source
            .command(&json!({"op":"create","path":dir.path().join("a.db"),"password":password}))
            .unwrap();
        let token = opened["session"].as_str().unwrap();
        for range in [0..500, 500..647] {
            let entries = range
                .map(|i| entry(&format!("fixture-{i}")))
                .collect::<Vec<_>>();
            call(&mut source, token, json!({"op":"import","entries":entries}));
        }
        let listed = call(&mut source, token, json!({"op":"list"}));
        let heads = listed["entries"]
            .as_array()
            .unwrap()
            .iter()
            .take(644)
            .map(|revision| &revision["id"])
            .collect::<Vec<_>>();
        call(
            &mut source,
            token,
            json!({"op":"set_deleted","heads":heads,"deleted":true}),
        );
        let inventory = call(&mut source, token, json!({"op":"sync_inventory"}));
        let hashes = inventory["objects"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>();
        assert_eq!(hashes.len(), 1291);
        let packs = hashes
            .chunks(128)
            .map(|hashes| {
                call(
                    &mut source,
                    token,
                    json!({"op":"sync_build_pack","hashes":hashes}),
                )
            })
            .collect::<Vec<_>>();
        let expected = call(&mut source, token, json!({"op":"list"}));

        let path = dir.path().join("b.db");
        let mut second = Vault::new();
        let mut join = json!({
            "op":"join","path":path,"password":"incorrect",
            "bootstrap":inventory["bootstrap"],
            "settings":{"username":"fixture@example.com","password":"fixture-app-password","joinPending":true}
        });
        assert!(second.command(&join).is_err());
        assert!(!path.exists());
        join["password"] = json!(password);
        let second_opened = second.command(&join).unwrap();
        let second_token = second_opened["session"].as_str().unwrap();
        let settings = call(&mut second, second_token, json!({"op":"sync_settings_get"}));
        assert_eq!(settings["settings"]["joinPending"], true);

        // Even with a matching content address, an unauthenticated member must
        // leave the whole pack uncommitted.
        let mut invalid = hex::decode(packs[0]["body"].as_str().unwrap()).unwrap();
        *invalid.last_mut().unwrap() ^= 1;
        let invalid_hash = object_hash(&invalid);
        assert!(second
            .command(&json!({
                "op":"sync_ingest_pack","session":second_token,
                "hash":invalid_hash,"body":hex::encode(invalid)
            }))
            .is_err());
        assert!(
            call(&mut second, second_token, json!({"op":"sync_inventory"}))["objects"]
                .as_object()
                .unwrap()
                .is_empty()
        );
        assert!(call(
            &mut second,
            second_token,
            json!({"op":"sync_receipts","packs":[invalid_hash]})
        )["packs"]
            .as_object()
            .unwrap()
            .is_empty());

        let mut third = Vault::new();
        join["path"] = json!(dir.path().join("c.db"));
        let third_opened = third.command(&join).unwrap();
        let third_token = third_opened["session"].as_str().unwrap();
        for pack in packs.iter().rev() {
            call(
                &mut second,
                second_token,
                json!({
                    "op":"sync_ingest_pack","hash":pack["hash"],"body":pack["body"]
                }),
            );
        }
        for pack in &packs {
            call(
                &mut third,
                third_token,
                json!({
                    "op":"sync_ingest_pack","hash":pack["hash"],"body":pack["body"]
                }),
            );
        }
        assert_eq!(
            call(&mut second, second_token, json!({"op":"list"})),
            expected
        );
        assert_eq!(
            call(&mut third, third_token, json!({"op":"list"})),
            expected
        );
        second.command(&json!({"op":"lock"})).unwrap();
        let reopened = second
            .command(&json!({"op":"unlock","path":path,"password":password}))
            .unwrap();
        let second_token = reopened["session"].as_str().unwrap();
        let receipts = call(
            &mut second,
            second_token,
            json!({
                "op":"sync_receipts","packs":packs.iter().map(|pack| &pack["hash"]).collect::<Vec<_>>()
            }),
        );
        assert_eq!(receipts["packs"].as_object().unwrap().len(), packs.len());
    }

    #[test]
    fn import_merges_exact_credentials_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let mut vault = Vault::new();
        let opened = vault
            .command(
                &json!({"op":"create","path":path,"password":"public import fixture passphrase"}),
            )
            .unwrap();
        let token = opened["session"].as_str().unwrap();
        let mut saved = entry("original");
        saved["notes"] = json!("Keep\n");
        saved["tags"] = json!("置顶, Work");
        call(&mut vault, token, json!({"op":"save","data":saved}));

        let mut imported = entry("original");
        imported["title"] = json!("Browser title");
        imported["url"] = json!(" https://example.com ");
        imported["notes"] = json!("Added");
        imported["tags"] = json!("work；导入");
        let changed_password = entry("changed");
        let mut second_file = changed_password.clone();
        second_file["notes"] = json!("Another export");
        let mut untitled_site_a = entry("shared");
        untitled_site_a["url"] = json!("");
        let mut untitled_site_b = untitled_site_a.clone();
        untitled_site_b["title"] = json!("Different item without a URL");

        let request = json!({"op":"import","entries":[
            imported, imported, changed_password, second_file, untitled_site_a, untitled_site_b
        ]});
        assert_eq!(
            call(&mut vault, token, request.clone()),
            json!({"imported":true,"added":3,"updated":1,"duplicates":3})
        );
        assert_eq!(
            call(&mut vault, token, request),
            json!({"imported":true,"added":0,"updated":0,"duplicates":6})
        );
        let listed = call(&mut vault, token, json!({"op":"list"}));
        let rows = listed["entries"].as_array().unwrap();
        assert_eq!(rows.len(), 4);
        let original = rows
            .iter()
            .find(|r| r["data"]["password"] == "original")
            .unwrap();
        assert_eq!(original["data"]["title"], "测试账号");
        assert_eq!(original["data"]["notes"], "Keep\n\n\nAdded");
        assert_eq!(original["data"]["tags"], "置顶, Work, 导入");
        let changed = rows
            .iter()
            .find(|r| r["data"]["password"] == "changed")
            .unwrap();
        assert_eq!(changed["data"]["notes"], "Another export");
    }

    #[test]
    fn quick_delete_is_atomic_and_preserves_the_account_for_restore() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let mut vault = Vault::new();
        let opened = vault
            .command(
                &json!({"op":"create","path":path,"password":"public delete fixture passphrase"}),
            )
            .unwrap();
        let token = opened["session"].as_str().unwrap();
        call(
            &mut vault,
            token,
            json!({"op":"import","entries":[entry("first"),entry("second")]}),
        );
        let listed = call(&mut vault, token, json!({"op":"list"}));
        let rows = listed["entries"].as_array().unwrap();
        let heads: Vec<_> = rows.iter().map(|r| &r["id"]).collect();
        assert_eq!(
            vault.command(&json!({"op":"set_deleted","session":token,"heads":[heads[0],"z-invalid"],"deleted":true})),
            Err("entry_changed_reload")
        );
        assert_eq!(call(&mut vault, token, json!({"op":"list"})), listed);
        assert_eq!(
            call(
                &mut vault,
                token,
                json!({"op":"set_deleted","heads":heads,"deleted":true})
            ),
            json!({"changed":2})
        );
        let deleted = call(&mut vault, token, json!({"op":"list"}));
        let tombstones = deleted["entries"].as_array().unwrap();
        assert!(tombstones.iter().all(|r| r["deleted"] == true));
        let tombstone = &tombstones[0];
        call(
            &mut vault,
            token,
            json!({"op":"set_deleted","heads":[tombstone["id"]],"deleted":false}),
        );
        let restored = call(&mut vault, token, json!({"op":"list"}));
        let current = restored["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["entry"] == tombstone["entry"])
            .unwrap();
        assert_eq!(current["deleted"], false);
        assert_eq!(current["data"], tombstone["data"]);
    }

    #[test]
    fn cleared_trash_is_hidden_on_a_peer_but_keeps_ciphertext_history() {
        let dir = tempfile::tempdir().unwrap();
        let pass = "public trash fixture passphrase";
        let mut source = Vault::new();
        let opened = source
            .command(&json!({"op":"create","path":dir.path().join("source.db"),"password":pass}))
            .unwrap();
        let token = opened["session"].as_str().unwrap();
        call(
            &mut source,
            token,
            json!({"op":"save","data":entry("archived")}),
        );
        let listed = call(&mut source, token, json!({"op":"list"}));
        let active = &listed["entries"][0]["id"];
        assert_eq!(
            source.command(&json!({"op":"discard_trash","heads":[active],"session":token})),
            Err("entry_changed_reload")
        );
        call(
            &mut source,
            token,
            json!({"op":"set_deleted","heads":[active],"deleted":true}),
        );
        let listed = call(&mut source, token, json!({"op":"list"}));
        let trash = &listed["entries"][0];
        call(
            &mut source,
            token,
            json!({"op":"discard_trash","heads":[trash["id"]]}),
        );
        assert_eq!(
            call(&mut source, token, json!({"op":"list"}))["entries"],
            json!([])
        );
        let history = call(
            &mut source,
            token,
            json!({"op":"history","entry":trash["entry"]}),
        );
        let revisions = history["revisions"].as_array().unwrap();
        assert_eq!(revisions.len(), 3);
        let clear = revisions
            .iter()
            .find(|revision| revision["data"]["tags"] == DISCARDED_TAG)
            .unwrap();
        assert_eq!(clear["data"]["password"], "");
        assert_eq!(
            source.command(
                &json!({"op":"set_deleted","heads":[clear["id"]],"session":token,"deleted":false})
            ),
            Err("entry_changed_reload")
        );

        let snapshot = call(&mut source, token, json!({"op":"sync_objects"}));
        let mut peer = Vault::new();
        let opened = peer
            .command(&json!({"op":"join","path":dir.path().join("peer.db"),"password":pass,"bootstrap":snapshot["bootstrap"]}))
            .unwrap();
        let peer_token = opened["session"].as_str().unwrap();
        for object in snapshot["objects"].as_array().unwrap() {
            call(
                &mut peer,
                peer_token,
                json!({"op":"ingest","hash":object["hash"],"body":object["body"]}),
            );
        }
        let listed = call(&mut peer, peer_token, json!({"op":"list"}));
        assert_eq!(listed["entries"], json!([]));
        assert_eq!(listed["pending"], 0);
    }

    #[test]
    fn fingerprint_export_grant_is_one_use_and_backup_restores_with_master_password() {
        let dir = tempfile::tempdir().unwrap();
        let pass = "public backup fixture passphrase";
        let mut source = Vault::new();
        let opened = source
            .command(&json!({"op":"create","path":dir.path().join("source.db"),"password":pass}))
            .unwrap();
        let token = opened["session"].as_str().unwrap();
        call(
            &mut source,
            token,
            json!({"op":"save","data":entry("portable")}),
        );
        let grant = call(
            &mut source,
            token,
            json!({"op":"device_grant","password":pass}),
        );
        let payload = source
            .take_device_key(grant["ticket"].as_str().unwrap())
            .unwrap();
        assert!(source.authorize_device_backup(&*payload, 42).is_err());
        let ticket = source.authorize_device_backup(&*payload, 0).unwrap();
        let request = json!({"op":"export","biometric_ticket":ticket,"session":token});
        let backup = source.command(&request).unwrap();
        assert_eq!(source.command(&request), Err("biometric_grant_expired"));
        assert_eq!(
            call(&mut source, token, json!({"op":"list"}))["entries"][0]["data"]["password"],
            "portable"
        );

        let destination = dir.path().join("restored.db");
        let mut restored = Vault::new();
        restored
            .command(&json!({
                "op":"restore","path":destination,"password":pass,
                "bootstrap":backup["bootstrap"],"backup":backup["backup"]
            }))
            .unwrap();
        let opened = restored
            .command(&json!({"op":"unlock","path":destination,"password":pass}))
            .unwrap();
        let listed = call(
            &mut restored,
            opened["session"].as_str().unwrap(),
            json!({"op":"list"}),
        );
        assert_eq!(listed["entries"][0]["data"]["password"], "portable");
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
            json!({"op":"sync_settings_set","settings":{"username":"test@example.com","password":secret,"auto":false}}),
        );
        assert_eq!(
            call(&mut v, &t, json!({"op":"sync_settings_get"}))["settings"]["password"],
            secret
        );
        assert_eq!(
            call(&mut v, &t, json!({"op":"sync_settings_get"}))["settings"]["auto"],
            false
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

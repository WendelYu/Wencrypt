#!/usr/bin/env python3
"""Independent Python reference generator; constants are PUBLIC TEST DATA ONLY."""
import hashlib
import json
import struct
from pathlib import Path
import cbor2
from argon2.low_level import Type, hash_secret_raw
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

ROOT=Path(__file__).resolve().parents[1]
VAULT=bytes.fromhex("00112233445546778899aabbccddeeff")
DEK=bytes(range(32))

def header(kind,salt,nonce,size):
    h=struct.pack("<8sHB16s32s12sI",b"WENCRYPT",1,kind,VAULT,salt,nonce,size)
    return h+struct.pack("<III",65536,3,1) if kind==1 else h

def main():
    vectors=[]
    for i,password in enumerate(["Wencrypt TEST password", "  中文主密码 空格保留  ", "Combining-e\u0301-密码", "Combining-é-密码"]):
        salt=bytes([16+i])*32; nonce=bytes([32+i])*12
        key=hash_secret_raw(password.encode("utf-8"),salt,3,65536,1,32,Type.ID,version=19)
        aad=header(1,salt,nonce,48)
        encrypted=aad+AESGCM(key).encrypt(nonce,DEK,aad)
        assert len(encrypted)==135
        vectors.append({"password":password,"password_utf8_hex":password.encode().hex(),"envelope_hex":encrypted.hex(),"sha256":hashlib.sha256(encrypted).hexdigest()})
    revision={"schema_version":1,"revision_id":bytes.fromhex("10112233445546778899aabbccddeeff"),"entry_id":bytes.fromhex("20112233445546778899aabbccddeeff"),"parents":[],"device_id":bytes.fromhex("30112233445546778899aabbccddeeff"),"updated_at":0,"is_deleted":False,"entry":{"title":"测试账号","username":"test@example.invalid","password":"PUBLIC-TEST-ONLY","urls":["https://example.invalid"],"notes":"","tags":["test"],"custom_fields":[]},"action":"create"}
    body=cbor2.dumps(revision,canonical=True)
    salt=bytes([77])*32; nonce=bytes([88])*12
    info=b"wencrypt/v1/object/"+bytes([2])+VAULT
    key=HKDF(algorithm=hashes.SHA256(),length=32,salt=salt,info=info).derive(DEK)
    aad=header(2,salt,nonce,len(body)+16)
    encrypted=aad+AESGCM(key).encrypt(nonce,body,aad)
    data={"notice":"PUBLIC TEST DATA; NEVER USE THESE KEYS/SALTS/NONCES IN A REAL VAULT","format_version":1,"vault_id_hex":VAULT.hex(),"dek_hex":DEK.hex(),"bootstrap_vectors":vectors,"revision":{"cbor_hex":body.hex(),"envelope_hex":encrypted.hex(),"sha256":hashlib.sha256(encrypted).hexdigest()}}
    dest=ROOT/"test-vectors/wenc-v1.json"; dest.parent.mkdir(exist_ok=True)
    dest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n")
    print("Generated public cross-implementation vectors:",dest.relative_to(ROOT))

if __name__=="__main__": main()

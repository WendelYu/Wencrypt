#!/usr/bin/env python3
"""Jianguoyun P0: public fixtures only, credentials prompted locally, no redirects."""
import base64
import getpass
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

BASE = 'https://dav.jianguoyun.com/dav/'
class ProbeError(Exception):
    def __init__(self, message, **diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics

def failure_report(error):
    return {'status': 'not_passed', 'reason': str(error), **error.diagnostics}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args): return None

def diagnostic_code(raw):
    # Only return fixed labels; never server-provided strings or element names.
    if len(raw) > 8192 or b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
        return 'unclassified'
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return 'unclassified'
    text = ' '.join(root.itertext()).lower()
    for needle, label in (
        ('sandbox name is too long', 'top_level_directory_name_too_long'),
        ('operationnotallowed', 'operation_not_allowed'),
        ('objectnotfound', 'object_not_found'),
        ('quota-not-exceeded', 'quota_limit'),
    ):
        if needle in text:
            return label
    return 'unclassified'

def probe_folder():
    # Keep the top-level collection short. It is a Jianguoyun sandbox,
    # whose constraints can differ from ordinary nested directory names.
    # 64 random bits; a collision fails MKCOL before any upload.
    return 'wp0-' + uuid.uuid4().hex[:16] + '/'

def listing(raw, expected):
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
        raise ProbeError('Unsafe XML')
    try: root = ET.fromstring(raw)
    except ET.ParseError: raise ProbeError('Invalid XML') from None
    if root.tag != '{DAV:}multistatus': raise ProbeError('Expected DAV multistatus')
    records = root.findall('{DAV:}response')
    if len(records) >= 700: raise ProbeError('Directory limit reached; completeness not established')
    names = set()
    for record in records:
        href = record.findtext('{DAV:}href')
        if not href: raise ProbeError('Missing href')
        url = urllib.parse.urljoin(BASE, href)
        p = urllib.parse.urlsplit(url)
        path = urllib.parse.unquote(p.path)
        if p.scheme != 'https' or p.netloc != 'dav.jianguoyun.com' or not path.startswith(expected):
            raise ProbeError('Unexpected DAV href')
        if not any((x.findtext('{DAV:}status') or '').split()[1:2] == ['200'] for x in record.findall('{DAV:}propstat')):
            raise ProbeError('Partial DAV response')
        tail = path[len(expected):].strip('/')
        if tail:
            if '/' in tail or tail in ('.', '..'): raise ProbeError('Unexpected child')
            names.add(tail)
    return names

class Client:
    def __init__(self, account, password):
        self.authorization = 'Basic ' + base64.b64encode((account+':'+password).encode()).decode()
        self.opener = urllib.request.build_opener(NoRedirect())
        self.last = 0.0
    def request(self, path, method='GET', data=None, *, stage='request', depth='1'):
        if path.startswith('/') or any(x in path for x in ('..', '?', '#', ':')):
            raise ProbeError('Unsafe relative path')
        for attempt in range(3):
            time.sleep(max(0,4-(time.monotonic()-self.last)))
            headers = {'Authorization': self.authorization, 'User-Agent': 'Wencrypt-P0/0.1'}
            if method == 'MKCOL':
                # urllib only auto-frames empty POST/PUT/PATCH, not MKCOL.
                # Explicitly frame an empty DAV request for strict servers/proxies.
                data = b''
                headers['Content-Length'] = '0'
            elif data is not None:
                headers['Content-Type'] = 'application/octet-stream'
            if method == 'PROPFIND':
                headers.update({'Depth': depth, 'Content-Type': 'application/xml; charset=utf-8'})
            self.last = time.monotonic()
            try:
                with self.opener.open(urllib.request.Request(BASE+path, data=data, headers=headers, method=method),timeout=20) as response:
                    raw=response.read(2*1024*1024+1)
                    if len(raw)>2*1024*1024: raise ProbeError('Response limit')
                    if method=='PROPFIND' and response.status!=207: raise ProbeError('Expected HTTP 207')
                    return raw
            except urllib.error.HTTPError as e:
                if e.code in (429,503) and method in ('GET','PUT','PROPFIND') and attempt<2:
                    try: delay=float(e.headers.get('Retry-After','10'))
                    except ValueError: delay=10
                    if delay>60: raise ProbeError('Rate limited; retry later') from None
                    time.sleep(max(4,delay)); continue
                mime = e.headers.get('Content-Type', '').split(';')[0].lower()
                kind = mime if mime in ('text/html','text/plain','application/xml','text/xml','application/json') else 'other'
                # Read only a bounded body and emit an allowlisted diagnostic label.
                try:
                    dav_code = diagnostic_code(e.read(8193))
                except (OSError, ValueError):
                    dav_code = 'unclassified'
                raise ProbeError(f'HTTP {e.code}; response body withheld',
                                 stage=stage, method=method, http_status=e.code,
                                 response_type=kind, dav_error=dav_code) from None
            except (urllib.error.URLError,TimeoutError,OSError):
                raise ProbeError('Network failure; local data unchanged', stage=stage, method=method) from None
        raise ProbeError('Retry limit')

def run(account, password):
    fixture=Path(__file__).resolve().parents[1]/'test-vectors/wenc-v1.json'
    blob=bytes.fromhex(json.loads(fixture.read_text())['bootstrap_vectors'][0]['envelope_hex'])
    folder=probe_folder()
    name=hashlib.sha256(blob).hexdigest()+'.wenc'
    client=Client(account,password)
    try:
        xml=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        client.request('', 'PROPFIND', xml, stage='authenticate_root', depth='0')
        client.request(folder,'MKCOL', stage='create_directory')
        client.request(folder+name,'PUT',blob, stage='upload')
        client.request(folder+name,'PUT',blob, stage='repeat_upload')
        if client.request(folder+name, stage='download')!=blob: raise ProbeError('Ciphertext mismatch')
        xml=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        names=listing(client.request(folder,'PROPFIND',xml, stage='list_directory'),'/dav/'+folder)
        if names!={name}: raise ProbeError('Listing mismatch')
        return {'provider':'jianguoyun','status':'basic_probe_passed','folder':folder,'public_test_data_only':True,'repeat_put':True,'remaining':['offline/reconnect','Android network','large-directory completeness','credential revocation']}
    finally: client.authorization=''

if __name__=='__main__':
    account=input('坚果云账号（邮箱）: ').strip()
    password=getpass.getpass('应用密码（不是登录密码，不会保存）: ')
    try: print(json.dumps(run(account,password),ensure_ascii=False,indent=2))
    except ProbeError as e:
        print(json.dumps(failure_report(e),ensure_ascii=False)); raise SystemExit(1)
    finally: password=''

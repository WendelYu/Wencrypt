#!/usr/bin/env python3
"""P0 public-client PKCE probe. Tokens stay in memory; uploads public test vectors only."""
import argparse
import base64
import hashlib
import hmac
import http.server
import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from pathlib import Path

GRAPH = "https://graph.microsoft.com/v1.0"
AUTH = "https://login.microsoftonline.com/consumers/oauth2/v2.0"
SCOPES = "https://graph.microsoft.com/Files.ReadWrite.AppFolder offline_access"
MAX_RESPONSE = 2 * 1024 * 1024

class ProbeError(Exception):
    """Only safe, fixed text is exposed; never include an HTTP body or URL."""

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

def graph_url(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme != "https" or p.hostname != "graph.microsoft.com" or p.port not in (None,443) or p.username or p.password or not p.path.startswith("/v1.0/") or p.fragment:
        raise ProbeError("Rejected unexpected Graph URL")
    return url

def validate_scopes(scope):
    normalized = {s.rsplit("/",1)[-1].lower() for s in scope.split()}
    if "files.readwrite.appfolder" not in normalized:
        raise ProbeError("AppFolder scope missing; no permission escalation attempted")
    if normalized - {"files.readwrite.appfolder", "offline_access", "openid", "profile", "email"}:
        raise ProbeError("Unexpected granted scopes; use a dedicated least-privilege app")
    return sorted(normalized)

def callback_code(path, state):
    p=urllib.parse.urlsplit(path)
    if p.path != "/callback":
        return None
    q=urllib.parse.parse_qs(p.query)
    if len(q.get("state",[]))!=1 or not hmac.compare_digest(q["state"][0],state):
        return None
    if "error" in q:
        raise ProbeError("Microsoft sign-in cancelled or rejected")
    if len(q.get("code",[])) != 1 or not q["code"][0]:
        raise ProbeError("Invalid authorization response")
    return q["code"][0]

def request_bytes(url, *, method="GET", data=None, headers=None, allow_redirect=False, attempts=3):
    # Never use automatic redirects: Graph bearer tokens must not reach download hosts.
    opener=urllib.request.build_opener(NoRedirect())
    for attempt in range(attempts):
        try:
            req=urllib.request.Request(url,data=data,headers=headers or {},method=method)
            with opener.open(req,timeout=20) as response:
                raw=response.read(MAX_RESPONSE+1)
                if len(raw)>MAX_RESPONSE:
                    raise ProbeError("Response exceeds probe limit")
                return raw
        except urllib.error.HTTPError as exc:
            if allow_redirect and exc.code in (301,302,303,307,308):
                location=exc.headers.get("Location","")
                p=urllib.parse.urlsplit(location)
                if p.scheme!="https" or not p.hostname or p.username or p.password:
                    raise ProbeError("Rejected download redirect") from None
                # Public Graph download URLs are credentials themselves; never log them.
                return request_bytes(location,headers={},attempts=attempts)
            if exc.code in (429,503) and attempt+1<attempts and method in ("GET","PUT"):
                try: delay=float(exc.headers.get("Retry-After",2**attempt))
                except ValueError: delay=2**attempt
                time.sleep(max(0,min(delay,15)))
                continue
            raise ProbeError(f"HTTP {exc.code}; response body deliberately omitted") from None
        except (urllib.error.URLError,TimeoutError,OSError):
            if method in ("GET","PUT") and attempt+1<attempts:
                time.sleep(2**attempt)
                continue
            raise ProbeError("Network failure; retry the probe when connected") from None
    raise ProbeError("Retry limit reached")

def request_json(url, **kwargs):
    try: return json.loads(request_bytes(url,**kwargs))
    except (ValueError,TypeError): raise ProbeError("Invalid JSON response") from None

def token_request(fields):
    result=request_json(AUTH+"/token",method="POST",data=urllib.parse.urlencode(fields).encode(),headers={"Content-Type":"application/x-www-form-urlencoded"})
    if not isinstance(result.get("access_token"),str) or not result["access_token"]:
        raise ProbeError("Token response incomplete")
    validate_scopes(result.get("scope",""))
    return result

def login(client_id):
    verifier=b64url(secrets.token_bytes(32)); state=b64url(secrets.token_bytes(32))
    result={}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
            try:
                code=callback_code(self.path,state)
                if code is None:
                    self.send_error(400,"Invalid callback"); return
                result["code"]=code
            except ProbeError:
                result["error"]=True
            self.send_response(200)
            self.send_header("Content-Type","text/plain; charset=utf-8")
            self.send_header("Cache-Control","no-store")
            self.send_header("Referrer-Policy","no-referrer")
            self.end_headers()
            self.wfile.write(b"Wencrypt P0: return to the terminal. You can close this tab.")
    with http.server.HTTPServer(("127.0.0.1",0),Handler) as server:
        server.timeout=1
        redirect=f"http://localhost:{server.server_port}/callback"
        query=urllib.parse.urlencode({"client_id":client_id,"response_type":"code","redirect_uri":redirect,"scope":SCOPES,"state":state,"code_challenge":b64url(hashlib.sha256(verifier.encode()).digest()),"code_challenge_method":"S256","response_mode":"query","prompt":"select_account"})
        print("Opening Microsoft sign-in in the system browser. Do not paste tokens into chat.",flush=True)
        if not webbrowser.open(AUTH+"/authorize?"+query):
            raise ProbeError("Cannot open system browser")
        deadline=time.monotonic()+180
        while not result and time.monotonic()<deadline:
            server.handle_request()
    if "code" not in result:
        raise ProbeError("Sign-in cancelled or timed out")
    return token_request({"client_id":client_id,"grant_type":"authorization_code","code":result.pop("code"),"redirect_uri":redirect,"code_verifier":verifier,"scope":SCOPES})

class Graph:
    def __init__(self,access_token): self.token=access_token
    def json(self,path,*,method="GET",data=None):
        url=graph_url(path if path.startswith("https:") else GRAPH+path)
        headers={"Authorization":"Bearer "+self.token}
        if data is not None: headers["Content-Type"]="application/json"
        return request_json(url,method=method,headers=headers,data=json.dumps(data).encode() if data is not None else None)
    def put(self,path,data):
        return request_json(graph_url(GRAPH+path),method="PUT",data=data,headers={"Authorization":"Bearer "+self.token,"Content-Type":"application/octet-stream"})
    def download(self,item):
        safe=urllib.parse.quote(item,safe="")
        return request_bytes(graph_url(GRAPH+f"/me/drive/items/{safe}/content"),headers={"Authorization":"Bearer "+self.token},allow_redirect=True)
    def list_all(self,folder):
        path=f"/me/drive/items/{urllib.parse.quote(folder,safe='')}/children?$top=2"
        values=[]; seen=set(); pages=0
        while path:
            if path in seen or pages>=100: raise ProbeError("Invalid pagination")
            seen.add(path); page=self.json(path); values.extend(page.get("value",[])); pages+=1
            path=page.get("@odata.nextLink")
        return values,pages

def run(client_id):
    fixture=Path(__file__).resolve().parents[1]/"test-vectors/wenc-v1.json"
    if not fixture.exists(): raise ProbeError("Generate public test vectors first")
    payload=bytes.fromhex(json.loads(fixture.read_text())["bootstrap_vectors"][0]["envelope_hex"])
    tokens=login(client_id)
    report={"probe":"WEN-002","test_data_only":True,"granted_scopes":validate_scopes(tokens["scope"])}
    graph=Graph(tokens["access_token"])
    try:
        root=graph.json("/me/drive/special/approot")
        if not root.get("id"): raise ProbeError("AppFolder missing")
        folder_name="wencrypt-p0-"+uuid.uuid4().hex
        folder=graph.json("/me/drive/special/approot/children",method="POST",data={"name":folder_name,"folder":{},"@microsoft.graph.conflictBehavior":"fail"})
        folder_id=urllib.parse.quote(folder["id"],safe="")
        ids=[]
        for i in range(5):
            path=f"/me/drive/items/{folder_id}:/sample-{i}.wenc:/content"
            item=graph.put(path,payload); ids.append(item["id"])
            # Idempotent repeated PUT of the exact same synthetic ciphertext.
            again=graph.put(path,payload)
            if item["id"]!=again["id"] or graph.download(item["id"])!=payload:
                raise ProbeError("Upload/download or repeated-write mismatch")
        items,pages=graph.list_all(folder["id"])
        if set(ids)!={x["id"] for x in items}: raise ProbeError("Pagination did not return expected objects")
        refresh=tokens.get("refresh_token")
        if not refresh: raise ProbeError("Refresh token missing")
        renewed=token_request({"client_id":client_id,"grant_type":"refresh_token","refresh_token":refresh,"scope":SCOPES})
        graph.token=renewed["access_token"]
        graph.json("/me/drive/special/approot")
        report.update({"status":"passed_basic_live_probe","objects":5,"pages":pages,"paging_exercised":pages>1,"byte_roundtrip":True,"repeat_put":True,"refresh":True,"local_token_disposal":True,"test_folder":folder_name,"remaining":["real offline/reconnect","429/503 real service behavior","Android network","account revocation","multi-device concurrency"]})
        renewed.clear()
        return report
    finally:
        graph.token=""; tokens.clear()
        # Python does not guarantee memory zeroization. Process exits after this probe.

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-id",required=True,type=lambda value:str(uuid.UUID(value)))
    args=parser.parse_args()
    try:
        print(json.dumps(run(args.client_id),ensure_ascii=False,indent=2))
    except (ProbeError,KeyError,ValueError) as exc:
        message=str(exc) if isinstance(exc,ProbeError) else "Unexpected response shape; no remote details logged"
        print(json.dumps({"probe":"WEN-002","status":"not_passed","reason":message},ensure_ascii=False))
        raise SystemExit(1)

if __name__=="__main__": main()

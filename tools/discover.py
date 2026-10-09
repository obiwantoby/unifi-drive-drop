#!/usr/bin/env python3
"""
UniFi Drive API discovery harness.

Logs into a UniFi OS console with a local account, keeps the `TOKEN` session cookie,
then probes the Drive service under /proxy/drive/api/ and dumps every response.

Stdlib only. Safe to re-run. Nothing is sent anywhere except the console you name.

    export UNIFI_HOST=192.0.2.10
    export UNIFI_USER=...            # optional; prompts if unset
    export UNIFI_PASS=...            # optional; prompts if unset
    python3 tools/discover.py            # read-only crawl
    python3 tools/discover.py --mutate   # also test upload + share creation
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

RAW = Path(__file__).resolve().parent.parent / "spec" / "raw"
TOKEN_FILE = Path(__file__).resolve().parent.parent / ".token"


# ---------------------------------------------------------------- transport

class Console:
    def __init__(self, host: str, insecure: bool = True):
        self.host = host if "://" in host else f"https://{host}"
        self.host = self.host.rstrip("/")
        ctx = ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        self.ctx = ctx
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=ctx),
        )

    def call(self, method: str, path: str, body=None, headers=None, timeout=20):
        url = path if path.startswith("http") else f"{self.host}{path}"
        data = None
        hdrs = {"Accept": "application/json", **(headers or {})}
        if body is not None:
            if isinstance(body, (dict, list)):
                data = json.dumps(body).encode()
                hdrs.setdefault("Content-Type", "application/json")
            else:
                data = body if isinstance(body, bytes) else str(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with self.opener.open(req, timeout=timeout) as r:
                raw = r.read()
                return r.status, dict(r.headers), raw
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()
        except Exception as e:  # noqa: BLE001
            return 0, {}, f"__transport_error__: {e}".encode()

    @staticmethod
    def as_json(raw: bytes):
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return None

    def token(self) -> str | None:
        for c in self.jar:
            if c.name == "TOKEN":
                return c.value
        return None


# ---------------------------------------------------------------- recording

class Recorder:
    def __init__(self, name: str):
        RAW.mkdir(parents=True, exist_ok=True)
        self.path = RAW / f"{name}.json"
        self.entries: list[dict] = []

    def record(self, label: str, status: int, headers: dict, raw: bytes, request=None):
        body = self.as_json(raw) if raw else None
        entry = {
            "label": label,
            "status": status,
            "request": request,
            "interesting_headers": {
                k: v
                for k, v in headers.items()
                if k.lower()
                in (
                    "location",
                    "x-csrf-token",
                    "x-updated-csrf-token",
                    "x-file-id",
                    "x-token-expire-time",
                    "upload-offset",
                    "upload-length",
                    "upload-url",
                    "tus-version",
                    "tus-resumable",
                    "tus-max-size",
                    "tus-extension",
                    "content-type",
                    "set-cookie",
                )
            },
            "json": body,
            "raw_preview": None
            if body
            else raw[:400].decode("utf-8", "replace"),
        }
        self.entries.append(entry)
        flag = "  "
        if status in (0, 401, 403, 500):
            flag = "!!"
        elif status and status < 400:
            flag = "ok"
        preview = json.dumps(body)[:110] if body else (entry["raw_preview"] or "")[:110]
        print(f"  {flag:>2} {status:>3} {label:<46} {preview}")
        return entry

    @staticmethod
    def as_json(raw):
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return None

    def save(self):
        self.path.write_text(json.dumps(self.entries, indent=2))
        print(f"\n  -> wrote {len(self.entries)} entries to {self.path.relative_to(RAW.parent.parent)}")


# ---------------------------------------------------------------- phases

def login(c: Console, user: str, pw: str, rec: Recorder):
    print("\n[1] authenticate")
    st, hd, raw = c.call("POST", "/api/auth/login", {"username": user, "password": pw})
    e = rec.record("POST /api/auth/login", st, hd, raw, {"username": user, "password": "***"})
    if st >= 400:
        print("\n  Login failed. Check the account. If it needs MFA, see notes below.")
        return False
    tok = c.token()
    if not tok:
        print("  Logged in but no TOKEN cookie found — inspect the response above.")
    else:
        TOKEN_FILE.write_text(tok)
        os.chmod(TOKEN_FILE, 0o600)
        print(f"  TOKEN acquired ({tok[:12]}...), saved to .token (chmod 600)")
    return True


def crawl(c: Console, rec: Recorder):
    print("\n[2] console / identity")
    for p in ["/api/ping", "/api/apps", "/api/system", "/api/info",
              "/api/integrations", "/api/availableIntegrations"]:
        st, hd, raw = c.call("GET", p)
        if st != 404:
            rec.record(f"GET {p}", st, hd, raw)

    print("\n[3] drive identity + storage")
    for p in ["/proxy/drive/api/v1/users/me",
              "/proxy/drive/api/v1/users",
              "/proxy/drive/api/v2/storage",
              "/proxy/drive/api/v2/drives",
              "/proxy/drive/api/v1/drives"]:
        st, hd, raw = c.call("GET", p)
        rec.record(f"GET {p}", st, hd, raw)

    print("\n[4] file listing — try the obvious shapes")
    listing = [
        "/proxy/drive/api/v1/files",
        "/proxy/drive/api/v1/files?limit=50&offset=0",
        "/proxy/drive/api/v1/files?path=/",
        "/proxy/drive/api/v1/files/list?path=/",
        "/proxy/drive/api/v1/folders",
        "/proxy/drive/api/v1/folders?path=/",
        "/proxy/drive/api/v1/files/root",
        "/proxy/drive/api/v1/search?query=a",
    ]
    for p in listing:
        st, hd, raw = c.call("GET", p)
        rec.record(f"GET {p}", st, hd, raw)

    print("\n[5] share / public-link surface")
    for p in ["/proxy/drive/api/v1/shares",
              "/proxy/drive/api/v1/share",
              "/proxy/drive/api/v1/public",
              "/proxy/drive/api/v1/links",
              "/proxy/drive/api/v1/files/share",
              "/proxy/drive/public/"]:
        st, hd, raw = c.call("GET", p)
        rec.record(f"GET {p}", st, hd, raw)

    print("\n[6] upload handshake (tus?)")
    for p in ["/proxy/drive/api/v1/files", "/proxy/drive/api/v1/upload"]:
        for m in ("OPTIONS", "HEAD"):
            st, hd, raw = c.call(m, p)
            rec.record(f"{m} {p}", st, hd, raw)


def mutate(c: Console, rec: Recorder):
    """Creates a real file and a real share link, then reports the URL.
    Leaves them on the box; delete via the Drive UI or --cleanup."""
    print("\n[7] MUTATING: upload + share")

    payload = f"drive-drop discovery test {time.strftime('%Y-%m-%d %H:%M:%S')}\n".encode()
    name = "drive-drop-discovery.txt"

    # 7a. plain multipart POST to the file route
    boundary = "----drivedropboundary0123"
    mp = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f"Content-Type: text/plain\r\n\r\n"
    ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()

    for p in ["/proxy/drive/api/v1/files",
              "/proxy/drive/api/v1/files/upload"]:
        st, hd, raw = c.call(
            "POST", p, mp,
            {"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        rec.record(f"POST(multipart) {p}", st, hd, raw, {"filename": name})

    # 7b. tus-style creation
    st, hd, raw = c.call(
        "POST", "/proxy/drive/api/v1/files", None,
        {"Upload-Length": str(len(payload)),
         "Upload-Metadata": f"filename {b64(name)},filetype dGV4dC9wbGFpbg==",
         "Content-Type": "application/octet-stream"},
    )
    rec.record("POST(tus create) /v1/files", st, hd, raw,
               {"Upload-Length": len(payload), "filename": name})
    if st in (200, 201) and hd.get("Location"):
        loc = hd["Location"]
        print(f"  tus location: {loc}")
        st2, hd2, raw2 = c.call(
            "PATCH", loc, payload,
            {"Content-Type": "application/offset+octet-stream",
             "Upload-Offset": hd.get("Upload-Offset", "0")},
        )
        rec.record("PATCH(tus upload) <location>", st2, hd2, raw2)

    # 7c. share creation attempts against whatever file the above returned
    fid = None
    for e in rec.entries:
        if e["label"].startswith("POST") and isinstance(e["json"], dict):
            blob = json.dumps(e["json"])
            for key in ("fileId", "id", "uuid"):
                j = e["json"]
                cand = j.get("data") if isinstance(j.get("data"), dict) else j
                if isinstance(cand, dict) and cand.get(key):
                    fid = str(cand[key])
                    break
        if fid:
            break
    print(f"  discovered file id: {fid}")

    if fid:
        for p, body in [
            (f"/proxy/drive/api/v1/files/{fid}/share", {}),
            (f"/proxy/drive/api/v1/files/{fid}/share", {"public": True}),
            ("/proxy/drive/api/v1/shares", {"fileId": fid}),
            ("/proxy/drive/api/v1/public", {"fileId": fid}),
        ]:
            st, hd, raw = c.call("POST", p, body)
            rec.record(f"POST {p}", st, hd, raw, body)
            if st < 400:
                print(f"  SHARE CREATED: {json.dumps(Recorder.as_json(raw))[:300]}")
                break
    else:
        print("  no file id captured; share tests skipped")


def b64(s: str) -> str:
    import base64
    return base64.b64encode(s.encode()).decode()


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("UNIFI_HOST", "192.0.2.10"))
    ap.add_argument("--user", default=os.environ.get("UNIFI_USER"))
    ap.add_argument("--pass", dest="pw", default=os.environ.get("UNIFI_PASS"))
    ap.add_argument("--mutate", action="store_true",
                    help="actually upload a file and create a share link")
    ap.add_argument("--verify-tls", action="store_true")
    args = ap.parse_args()

    user = args.user or input("UniFi OS username: ")
    pw = args.pw or getpass.getpass("UniFi OS password: ")

    c = Console(args.host, insecure=not args.verify_tls)
    rec = Recorder("discovery")

    print(f"target: {c.host}")
    if not login(c, user, pw, rec):
        rec.save()
        sys.exit(1)

    crawl(c, rec)
    if args.mutate:
        mutate(c, rec)

    rec.save()
    print("\ndone. Send me spec/raw/discovery.json (or just tell you to run it here).")


if __name__ == "__main__":
    main()

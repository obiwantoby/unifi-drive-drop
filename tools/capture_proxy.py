#!/usr/bin/env python3
"""
Logging reverse proxy for capturing the UniFi Drive web UI's real traffic.

Why this works: the Drive SPA calls relative paths (/proxy/drive/api/v1/...). If you load
the UI through http://localhost:8080 instead of the console, those calls come here
in cleartext and we forward them on to the console over TLS. No CA, no cert pinning,
no browser configuration, no pcap decryption.

    python3 tools/capture_proxy.py                 # http://localhost:8080
    python3 tools/capture_proxy.py --port 8080 --filter upload

Then, in the browser:
    1. open http://localhost:8080/drive/
    2. sign in
    3. upload one small file (a few KB)
    4. create a share link for it, then delete both
    5. Ctrl-C here

Everything is appended to spec/raw/capture.jsonl with full headers and a body preview,
including the tus Upload-* headers and Upload-Metadata we could not derive statically.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "spec" / "raw" / "capture.jsonl"

# No default on purpose: this repo is public, and an example address that happens to be
# somebody's real console is a leak. Set UNIFI_HOST before running.
TARGET_HOST = os.environ.get("UNIFI_HOST") or ""
TARGET_PORT = 443

# Hop-by-hop headers must not be forwarded in either direction.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade",
}

# Headers worth printing in full when present.
INTERESTING = (
    "upload-length", "upload-offset", "upload-metadata", "upload-concat",
    "tus-resumable", "x-csrf-token", "x-updated-csrf-token", "x-file-id",
    "x-token-expire-time", "location", "content-type", "content-length",
    "content-range", "range", "authorization", "cookie", "x-uidtoken", "jwt",
)

# Only log these path fragments by default (empty list = log everything).
DEFAULT_FILTER = [
    "/proxy/drive/api",
    "/api/auth/",
]

lock = threading.Lock()


def interesting_headers(h):
    # accepts a dict, a HTTPMessage, or an http.client.HTTPResponse
    if hasattr(h, "headers"):
        h = h.headers
    pairs = h.items() if hasattr(h, "items") else list(h)
    return {k: v for k, v in pairs if k.lower() in INTERESTING}


def scrub_cookies(header_value: str) -> str:
    """
    We serve over plain http, so attributes that require a secure context must go,
    otherwise the browser silently drops the cookie and the UI loops on login:
      * Secure        -> we are not on https
      * SameSite=None -> requires Secure
      * Partitioned   -> requires Secure  (this is the one that broke login)
    """
    parts = []
    for chunk in header_value.split(";"):
        c = chunk.strip()
        low = c.lower()
        if low in ("secure", "partitioned", ""):
            continue
        if low.startswith("samesite=none"):
            continue
        parts.append(c)
    return "; ".join(parts) or header_value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    filter_prefixes = DEFAULT_FILTER
    quiet = False

    def log_message(self, fmt, *args):  # silence the default access log
        pass

    # ---- helpers -------------------------------------------------------

    def _should_log(self) -> bool:
        if not self.filter_prefixes:
            return True
        return any(f in self.path for f in self.filter_prefixes)

    def _read_body(self):
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            # de-chunk so we can see and forward a plain body
            buf = bytearray()
            while True:
                line = self.rfile.readline().strip()
                if not line:
                    continue
                try:
                    size = int(line.split(b";")[0], 16)
                except ValueError:
                    break
                if size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                buf += self.rfile.read(size)
                self.rfile.readline()
                if len(buf) > 64 * 1024 * 1024:
                    break
            return bytes(buf)
        n = self.headers.get("Content-Length")
        if n:
            return self.rfile.read(int(n))
        return None

    def _forward(self, body):
        conn = http.client.HTTPSConnection(
            TARGET_HOST, TARGET_PORT, timeout=180,
            context=__import__("ssl")._create_unverified_context(),
        )
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP and k.lower() != "host"}
        headers["Host"] = TARGET_HOST
        if body is not None:
            headers["Content-Length"] = str(len(body))
        conn.request(self.command, self.path, body=body, headers=headers)
        return conn.getresponse()

    def _record(self, status, resp_headers, resp_body, req_body):
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "method": self.command,
            "path": self.path,
            "req_headers": interesting_headers(self.headers),
            "req_body_len": len(req_body) if req_body else 0,
            "req_body_preview": None,
            "status": status,
            "resp_headers": interesting_headers(resp_headers),
            "resp_body_preview": None,
        }
        if req_body:
            txt = req_body[:2000].decode("utf-8", "replace")
            entry["req_body_preview"] = (
                txt if _printable(txt) else f"<{len(req_body)} bytes binary>"
            )
        if resp_body:
            entry["resp_body_preview"] = resp_body[:1200].decode("utf-8", "replace")
        with lock:
            with OUT.open("a") as f:
                f.write(json.dumps(entry) + "\n")
            if not self.quiet:
                self._print(entry)

    def _print(self, e):
        tag = "  "
        if any(k in e["req_headers"] or k in e["resp_headers"]
               for k in ("upload-length", "upload-offset", "upload-metadata",
                         "upload-concat", "x-file-id")):
            tag = "**"   # <-- a tus request, this is what we're hunting
        elif e["status"] and e["status"] >= 400:
            tag = "!!"
        print(f"{tag} {e['method']:6} {e['status'] or '---':>3} {e['path'][:96]}")
        for k, v in e["req_headers"].items():
            if k.lower().startswith(("upload-", "tus-", "x-file")):
                print(f"       > {k}: {v}")
        for k, v in e["resp_headers"].items():
            if k.lower() in ("location", "upload-offset", "x-file-id",
                             "x-updated-csrf-token"):
                print(f"       < {k}: {v}")
        if e["resp_body_preview"] and e["status"] and e["status"] >= 400:
            print(f"       ! {e['resp_body_preview'][:200]}")

    # ---- verbs ---------------------------------------------------------

    def do_GET(self): self._handle()
    def do_POST(self): self._handle()
    def do_PUT(self): self._handle()
    def do_PATCH(self): self._handle()
    def do_DELETE(self): self._handle()
    def do_HEAD(self): self._handle()
    def do_OPTIONS(self): self._handle()

    def _handle(self):
        req_body = self._read_body()
        try:
            resp = self._forward(req_body)
        except Exception as ex:  # noqa: BLE001
            self.send_error(502, f"proxy forward failed: {ex}")
            return

        # Browsers abort keep-alive connections freely; that is not an error worth a traceback.
        try:
            self._respond(resp, req_body)
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            pass

    def _respond(self, resp, req_body):
        is_textish = True

        is_textish = True
        resp_body = b""
        ctype = (resp.getheader("Content-Type") or "").lower()
        # stream big binaries straight through, only record metadata
        cl = resp.getheader("Content-Length")
        big = cl is not None and int(cl) > 4 * 1024 * 1024
        if big or not any(t in ctype for t in
                          ("json", "html", "text", "javascript", "xml", "svg")):
            is_textish = False
        else:
            resp_body = resp.read()

        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            lk = k.lower()
            if lk in HOP_BY_HOP or lk == "set-cookie":
                continue
            # keep-alive is managed by our HTTP/1.1 handler
            self.send_header(k, v)
        for raw in resp.headers.get_all("Set-Cookie") or []:
            self.send_header("Set-Cookie", scrub_cookies(raw))
        if not big:
            self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        if not big and resp_body and self.command != "HEAD":
            self.wfile.write(resp_body)
        elif big and self.command != "HEAD":
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

        if self._should_log():
            self._record(resp.status, resp, resp_body if is_textish else b"", req_body)
        try:
            resp.close()
        except Exception:  # noqa: BLE001
            pass


def _printable(s: str) -> bool:
    return sum(ch.isprintable() or ch in "\r\n\t" for ch in s) >= max(1, len(s) - 4)


def main():
    global TARGET_HOST
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=TARGET_HOST)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--filter", nargs="*", default=None,
                    help="only log requests containing these substrings")
    ap.add_argument("--all", action="store_true", help="log every request")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    TARGET_HOST = args.host
    Handler.filter_prefixes = [] if args.all else (args.filter or DEFAULT_FILTER)
    Handler.quiet = args.quiet

    OUT.parent.mkdir(parents=True, exist_ok=True)
    print(f"target      https://{TARGET_HOST}")
    print(f"open in a browser   http://localhost:{args.port}/drive/")
    print(f"logging to          {OUT}")
    print("hunting for: POST/POST-with-Upload-Length -> PATCH Upload-Offset\n")
    print("NOTE: use Firefox, or Chrome with 'Use safe DNS/HTTPS-only' OFF,")
    print("      otherwise the browser may upgrade http://localhost to https.\n")

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print(f"\nstopped. {OUT}")


if __name__ == "__main__":
    main()

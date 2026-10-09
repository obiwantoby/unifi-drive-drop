#!/usr/bin/env python3
"""
Verified Drive upload, reconstructed from the captured web-UI traffic.

tus contract (spec/api.md s7):
  POST  /proxy/drive/api/v1/files
        Tus-Resumable: 1.0.0
        Upload-Length: <bytes>
        Upload-Metadata: filename <b64>,dir <b64>,task-id <b64>,
                         modify-time <b64>,checksum <b64>
        -> 201, Location: /api/v1/files/<uploadId>
  PATCH /proxy/drive/api/v1/files/<uploadId>
        Tus-Resumable: 1.0.0
        Upload-Offset: <n>
        Content-Type: application/offset+octet-stream
        body: <= 512 KiB
        -> 204, Upload-Offset: <n+len>

Every request also needs X-Csrf-Token and X-Connection-Type: local.
"""
import base64, json, ssl, sys, time, uuid, zlib
import http.client
from datetime import datetime

HOST = "192.0.2.10"
TOKEN = open("/Users/***REMOVED***/Developer/unifi-drive-drop/.token").read().strip()
CHUNK = 512 * 1024


def b64(s):
    return base64.b64encode(str(s).encode()).decode()


def ctx():
    return ssl._create_unverified_context()


def call(method, path, headers=None, body=None):
    c = http.client.HTTPSConnection(HOST, 443, context=ctx(), timeout=120)
    h = {"Cookie": f"TOKEN={TOKEN}", "X-Connection-Type": "local", **(headers or {})}
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    hdrs = {k.lower(): v for k, v in r.getheaders()}
    c.close()
    return r.status, hdrs, data


def csrf():
    s, h, _ = call("GET", "/proxy/drive/api/v1/users/me")
    return h.get("x-csrf-token")


def upload(local_path, drive_path, name=None, checksum_algo="crc32"):
    raw = open(local_path, "rb").read()
    name = name or local_path.rsplit("/", 1)[-1]
    token = csrf()

    if checksum_algo == "crc32":
        checksum = format(zlib.crc32(raw) & 0xFFFFFFFF, "08x")
    elif checksum_algo == "md5_8":
        import hashlib
        checksum = hashlib.md5(raw).hexdigest()[:8]
    else:
        checksum = "0" * 8

    meta = ",".join([
        f"filename {b64(name)}",
        f"dir {b64(drive_path)}",
        f"task-id {b64(str(uuid.uuid4()))}",
        f"modify-time {b64(datetime.now().astimezone().replace(microsecond=0).isoformat())}",
        f"checksum {b64(checksum)}",
    ])

    print(f"  name={name} size={len(raw)} dir={drive_path} checksum={checksum} ({checksum_algo})")

    s, h, body = call("POST", "/proxy/drive/api/v1/files", {
        "Tus-Resumable": "1.0.0",
        "Upload-Length": str(len(raw)),
        "Upload-Metadata": meta,
        "X-Csrf-Token": token,
    })
    print(f"  POST -> {s}  Location={h.get('location')}")
    if s not in (200, 201):
        print("   ", body[:300])
        return False
    upload_path = h["location"].replace("/api/v1/files", "/proxy/drive/api/v1/files")

    offset = 0
    while offset < len(raw):
        piece = raw[offset:offset + CHUNK]
        s, h, body = call("PATCH", upload_path, {
            "Tus-Resumable": "1.0.0",
            "Upload-Offset": str(offset),
            "Content-Type": "application/offset+octet-stream",
            "X-Csrf-Token": token,
        }, body=piece)
        if s not in (200, 204):
            print(f"  PATCH @{offset} -> {s}: {body[:200]}")
            return False
        offset = int(h.get("upload-offset", offset + len(piece)))
    print(f"  PATCH complete, offset={offset}/{len(raw)}")

    # Did it land?
    target = "/proxy/drive/api/v1/resources" + drive_path.rstrip("/") + "/" + name
    import urllib.parse as up
    enc = "/".join(up.quote(p) for p in target.split("/"))
    s, h, body = call("GET", enc)
    print(f"  verify GET {target} -> {s}")
    if s == 200:
        print("   ", body[:200].decode("utf-8", "replace"))
    return s == 200


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/drive-probe.txt"
    algo = sys.argv[2] if len(sys.argv) > 2 else "crc32"
    if path == "/tmp/drive-probe.txt":
        open(path, "w").write("DriveDrop upload probe %d\n" % time.time())
    ok = upload(path, "/", checksum_algo=algo)
    print("RESULT:", "UPLOADED" if ok else "FAILED")

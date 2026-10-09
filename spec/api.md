# UniFi Drive API — verified spec

Console: `https://192.0.2.10` — **UNAS Pro**, UniFi OS **4.0.4**, Drive controller **4.4.9**
(`uiCdn: https://cdn.pkg.svc.ui.com/unifi-drive-ui/4.4.9-0d145a`).

Everything below was exercised live on 2026-10-09 against that box. Each endpoint is tagged:

| Tag | Meaning |
|---|---|
| ✅ | called successfully, response captured |
| 🔬 | behaviour confirmed by error envelope / route oracle, payload not yet exercised |
| ❓ | still unknown |

---

## 1. Base URLs

From the Drive UI bundle config:

```js
apiUrlBase:          "/api/v1"
apiUrlBaseV2:        "/api/v2"
wsUrlBase:           "/api/ws"
standaloneApiPrefix: "/proxy/drive"     // console-proxied
publicApiPrefix:     "/public"          // unauthenticated share site
localDrivePortalEntryName: "unifi-drive"
```

So the authenticated API root is:

```
https://<console>/proxy/drive/api/v1
https://<console>/proxy/drive/api/v2
```

and the unauthenticated share root is `https://<console>/proxy/drive/public/api/v1`.

The Drive SPA is served at `/unifi-drive/*` (510-byte shell, client-side routing).
`/drive/*` and every other unknown path fall back to the 1533-byte UniFi OS portal HTML —
**use the response size to tell "no such route" from a real handler.**

---

## 2. Authentication

### `POST /api/auth/login` ✅

```json
{"username": "string", "password": "string"}
```

| Result | Status | Body |
|---|---|---|
| success | 200 | full user object (`_id`, `unique_id`, `fullName`, `email`, `roles`) |
| malformed body | 400 | `{"code":"VALIDATION_ERROR","validationErrors":[...]}` (zod-shaped) |
| bad credentials | 403 | `{"code":"AUTHENTICATION_FAILED_INVALID_CREDENTIALS","message":"Invalid username or password"}` |

Success sets the session cookie:

```
set-cookie: TOKEN=<jwt>; path=/; samesite=none; secure; httponly; partitioned
```

### Session lifetime — and how to stop it dying after 2 hours ✅

The default `TOKEN` JWT is short-lived:

| login body | `exp - iat` | `isRemembered` |
|---|---|---|
| `{username, password}` | **7 200 s (2 h)** | `false` |
| `{username, password, rememberMe: true}` | **2 592 000 s (30 d)** | `true` |
| `{..., remember: true}` | 7 200 s | `false` — wrong key |
| `{..., remember_user: true}` | 7 200 s | `false` — wrong key |

**`rememberMe` is the only spelling that works.** DriveDrop sends it, and also re-logs in
transparently on any 401, so a session effectively never expires for the user.

The response carries `X-Token-Expire-Time` (epoch **milliseconds**), which matches the JWT
`exp` exactly — verified to the second. The app surfaces this as a countdown in the menu bar.

### Login fails if you already have a cookie ✅ — gotcha

```
POST /api/auth/login   Cookie: TOKEN=<anything>
→ 403 {"error":{"code":403,"message":"Forbidden"}}
```

The gateway refuses login when a `TOKEN` cookie is attached. Any client whose cookie jar
survives between launches must **clear cookies before logging in**, or the second run can
never sign in. (This bit us: URLSession's shared jar persisted and every subsequent launch
403'd.)

### CSRF ✅

Every **write** (POST/PUT/PATCH/DELETE) is rejected with `403 {"error":{"code":403,"message":"Forbidden"}}`
unless the header `X-Csrf-Token` is sent.

- The token is returned by the **console** (`/api/...`) — reliably on the login response:
  ```
  x-csrf-token: <REDACTED-CSRF>
  ```
  Do **not** count on it from proxied Drive service responses (`/proxy/drive/...` GETs came
  back without it). Take it from login.
- Any response may rotate it via `x-updated-csrf-token` — mirror it into the next write.
- `x-token-expire-time` (epoch ms) accompanies it; re-login before it lapses.

**The CSRF token is a claim inside the TOKEN JWT** (`payload.csrfToken`), so the two are
fused. Pairing a CSRF token from login A with the JWT from login B fails the CSRF gate —
which looks exactly like a bad token. Always capture cookie and header from the *same*
login round-trip, and never refresh one without the other.

### The API key does **not** work for Drive ✅

| Credential on `/proxy/drive/api/v1/users` | Result |
|---|---|
| none | `401 {"error":{"code":401,"message":"Unauthorized"}}` (gateway) |
| `X-API-KEY: <key>` | reaches the service, `403 invalid auth user ID` |
| `Authorization: Bearer <key>` | `401` (gateway) |

The key authenticates the *connection* but carries no *user identity*. It can read exactly
one Drive route (`/api/v2/storage`). The portal's own API-key doc generator only knows
Network / Protect / Access — **there is no Drive scope**. Drive is session-auth only.

### Accepted auth-ish headers (from CORS preflight) ✅

```
Content-Type, Cache-Control, If-Modified-Since, Jwt, Range, Tus-Resumable,
Upload-Length, Upload-Metadata, Upload-Offset, X-Connection-Type, X-Csrf-Token,
X-Requested-With, X-Token-Expire-Time, X-UidToken, X-Updated-Csrf-Token,
X-User-Agent, X-Api-Key, X-Ui-Setup-Poll-Token, Authorization
```

---

## 3. Error envelopes — two different ones

```jsonc
// Drive service (has "err")
{"err": null, "type": "single", "data": {...}}          // success, single
{"err": null, "type": "collection", "data": [...]}      // success, list
{"err": {"msg": "route not found", "code": "ErrNotFound"}}
{"err": {"msg": "invalid auth user ID", "data": [], "metadata": null}, "type": "single", "data": null}
{"err": {"msg": "duplicated file sharing link", "code": "ErrForbidden"}}
{"err": {"msg": "Bad Request", "data": [], "metadata": {"error": "invalid drive type"}}}

// Gateway (has "error")
{"error": {"code": 401, "message": "Unauthorized"}}
{"error": {"code": 403, "message": "Forbidden"}}
```

`{"data":"OK","type":"single"}` is the success shape for DELETE.

---

## 4. Identity & inventory

| Method | Path | Status | Notes |
|---|---|---|---|
| GET | `/api/v1/users/me` | ✅ | current Drive user: `id`, `username`, `isOwner`, `roles[].systemKey`, `usage`, `appliedStorageProfile` |
| GET | `/api/v1/users` | ✅ | collection of Drive users |
| GET | `/api/v1/groups` | ✅ | Drive groups (`Drive Manager` default group) |
| GET | `/api/v1/drives` | ✅ | `{drives:[...]}` |
| GET | `/api/v2/drives` | ✅ | same shape |
| GET | `/api/v2/storage` | ✅ | RAID pools — **the only route the API key can read** |
| GET | `/api/v1/search` | 🔬 | exists; GET with `?query=` times out (>25 s), POST → route not found |

### Drive object

```json
{
  "id": "0a527470-b749-4630-8f0b-3eb3e568dc02",
  "type": "shared | personal",
  "name": "***REMOVED***",
  "status": "active",
  "storagePoolId": "cf78bf79-af1c-4ee6-97c5-155c602aca90",
  "quota": -1,
  "usage": 6102280962048,
  "role": "owner | admin | editor | viewer",
  "protections": {
    "encryptionStatus": "unencrypted",
    "remoteBackupEnabled": false,
    "snapshotEnabled": false
  },
  "memberCount": 1,
  "nfsIsolated": false
}
```

Observed drives: `shared/netboot_assets`, `shared/Backups`, `shared/Prox_Backup`,
`shared/All`, `personal/***REMOVED***`.

---

## 5. Resource listing ✅ — this is the one you want

```
GET /proxy/drive/api/v1/resources/mydrive/<path>
GET /proxy/drive/api/v1/resources/shared/<driveName>/<path>
```

Returns **JSON**, unlike `/files/...` (see §6).

```json
{
  "err": null, "type": "single",
  "data": {
    "name": "", "isDir": true, "isSymlink": false, "extension": "",
    "birthTime": "2025-09-02T19:00:55.484005818-04:00",
    "items": [
      {
        "name": "RiftCommand.zip",
        "path": "RiftCommand.zip",
        "isDir": false, "type": "blob",
        "size": 117058589, "usage": 0, "quota": 0,
        "mode": 432, "extension": ".zip",
        "birthTime": "...", "modifyTime": "2026-09-12T17:47:51-04:00",
        "owner": {"id": "...", "fullName": "Example User", "firstName": "***REMOVED***"},
        "numDirs": 0, "numFiles": 0, "items": null
      }
    ]
  }
}
```

Path grammar (confirmed by the error oracle):

| Path | Response |
|---|---|
| `/resources/mydrive/` | ✅ 200 — personal drive root |
| `/resources/shared/Backups/` | ✅ 200 — shared drive root |
| `/resources/mydrive/RiftCommand.zip` | ✅ 200 — single file |
| `/resources/shared/nope/` | `400 {"metadata":{"error":"get drive path failed"}}` |
| `/resources/<badtype>/...` | `400 {"metadata":{"error":"invalid drive type"}}` |

Valid drive-type segments are **`mydrive`** and **`shared`** only. `personal`, `home`,
`user`, `mine`, `self`, `private` all return *invalid drive type* — the `type` field in the
drives list (`"personal"`) is **not** the URL keyword.

### `/resources/{path}` supports more than GET ✅

| Method | Effect | Response |
|---|---|---|
| GET | list dir / stat file | JSON (above) |
| POST | **create file or directory** | `200 null` — `{}​` / empty body makes a 0-byte **file**; `{"isDir":true}` makes a **directory** |
| PATCH | update metadata | `200`; **requires a JSON body** — raw bytes give `{"metadata":{"error":"invalid character 'h' looking for beginning of value"}}` |
| DELETE | **move to trash** | `{"err":null,"type":"single","data":{"path":"/trash/mydrive/<name>"}}` |
| PUT | — | `route not found` |

DELETE is a soft delete into the trash; the response names the trash path. Verified against
three files, all removed cleanly.

**mkdir** — the body is *not* ignored, despite the earlier note:

```
POST /proxy/drive/api/v1/resources/mydrive/Archive/2026
X-Csrf-Token: …            body: {"isDir":true}
→ 200 null
GET  …/resources/mydrive/Archive/2026 → {"isDir":true, "path":"/mydrive/Archive/2026"}
```

Nested paths work, so this doubles as `mkdir -p`.

**Duplicate uploads are auto-renamed, never overwritten.** Dropping `report.txt` into a
folder that already has one yields `report (1).txt`, then `report (2).txt`. So an upload
succeeding does **not** mean it replaced anything — re-list the folder and read back the name
that actually landed if the exact filename matters.

**Listing the drive root needs the trailing slash.** `GET /resources/mydrive` →
`{"err":{"msg":"route not found"}}`; `GET /resources/mydrive/` → 200. Children come back
under `data.items` (not `children`), and each `path` is fully qualified (`/mydrive/dev`).

Also present: `/trash-resources/trash/mydrive`, `/trash-resources/trash/shared/<name>` 🔬

---

## 6. Download ✅

```
GET /proxy/drive/api/v1/files/mydrive/<path>
GET /proxy/drive/api/v1/files/shared/<driveName>/<path>
```

- **File** → raw bytes, `Content-Disposition`, `Accept-Ranges`, honours `Range`.
- **Directory** → streams a **ZIP** of the subtree. There is no flag to disable this;
  `?list=`, `?depth=`, `?recursive=`, `Accept: application/json` all still return a zip.
  Use `/resources/...` (§5) for listings.

⚠️ Range requests are **ignored** on the zip path — a ranged probe pulled 635 MB.

The route is **GET/HEAD only**. POST/PUT/PATCH/DELETE on any `/files/{type}/...` path
returns `route not found` ✅.

---

## 7. Upload — ✅ SOLVED, verified byte-exact

The whole mystery was one field: **`Upload-Metadata: checksum` must be the file's real
CRC32.** Every other symptom was a red herring.

### The contract

```
POST /proxy/drive/api/v1/files
  Cookie: TOKEN=<jwt>
  X-Csrf-Token: <csrf>
  X-Connection-Type: local
  Origin: https://192.0.2.10
  Tus-Resumable: 1.0.0
  Upload-Length: 1300000
  Upload-Metadata: filename <b64>,dir <b64>,task-id <b64>,modify-time <b64>,checksum <b64>
→ 201 Created
   Location: /api/v1/files/08e0a12b-cf93-48db-8b91-09dd2088b075
```

```
PATCH /proxy/drive/api/v1/files/<uploadId>      # NOTE the /proxy/drive prefix
  Tus-Resumable: 1.0.0
  Upload-Offset: 0
  Content-Type: application/offset+octet-stream
  <up to 524288 bytes>
→ 204 No Content
   Upload-Offset: 524288
```

Repeat PATCH until `Upload-Offset == Upload-Length`.

### Two traps that cost hours

**1. `Location:` is relative to the Drive service root, not the console root.**
`PATCH https://host/api/v1/files/<id>` → **404**. You must prepend the proxy prefix:

```python
upload_url = console + "/proxy/drive" + location   # location == "/api/v1/files/<id>"
```

**2. A wrong checksum is accepted, then silently discarded.** Every `PATCH` answers `204`
with a correct `Upload-Offset`. Only at finalize does the server drop the session, so a bad
checksum looks like a successful upload until the object simply never appears under
`/resources`. Our earlier attempts sent `parentPath` (a key that does not exist) and no
checksum at all — hence `{"status":"failed"}`.

### Which metadata keys actually matter

Isolation test, 4096-byte file, one key varied at a time:

| metadata sent | PATCH | object landed |
|---|---|---|
| `filename` + `dir` + `task-id` + `modify-time` + valid `checksum` | 204 | ✅ yes |
| same but `checksum` = `deadbeef` | 204 | ❌ **no** |
| `filename` + `dir` + `task-id` + `checksum`, **no `modify-time`** | 204 | ✅ yes |
| `filename` + `task-id` + `checksum`, **no `dir`** | 204 | ✅ yes |

So **`filename` and `checksum` are mandatory; `dir`, `task-id` and `modify-time` are optional.**

### `dir` semantics — it creates the folder for you ✅

`dir` is **relative to the personal-drive root**, not a `/mydrive/...` path, and absent means
the drive root. Missing parents are **created by the upload itself**:

```
dir = base64("/zz-autodir")     filename = auto.txt
→ POST 201, PATCH 204
GET /resources/mydrive/zz-autodir/auto.txt → 200   (landed)
GET /resources/mydrive/zz-autodir          → 200   {"isDir":true}   (did not exist before)
```

So DriveDrop's `/Public` default needs no `mkdir` and no existence check — first drop creates
it. Normalise the value anyway (`Public`, `Public/`, `/Public/` → `/Public`); a trailing slash
is not silently trimmed by the server.

### `checksum` is CRC32, 8 lowercase hex chars

Base64-encoded like every other metadata value:

```python
checksum = base64.b64encode(format(zlib.crc32(data) & 0xffffffff, "08x").encode())
```

Verified against `zlib.crc32`: `""` → `00000000`, `"abc"` → `352441c2`,
`"The quick brown fox jumps over the lazy dog"` → `414fa339`.

### Chunk size

**512 KiB (524288 bytes)**, straight from the UI capture — the second PATCH carries
`Upload-Offset: 524288`. The Drive UI uploads a 5,608,957-byte JPEG as 11 such PATCHes.

### Pre-flight duplicate check

The UI asks before uploading:

```
POST /proxy/drive/api/v2/drives/{driveId}/files/%2F%2F/check-filenames
  Content-Type: application/json; charset=utf-8
  {"filenames":["IMG_1039.jpg"]}
```

The `%2F%2F` is a literal `//` — the parent path is empty for the drive root, so the route
is `/files/{parentPath}/check-filenames`. Personal drive id:
`0a527470-b749-4630-8f0b-3eb3e568dc02`.

### Optional metadata seen in the bundle

| key | when |
|---|---|
| `shared-drive` | uploading into a shared drive (value = drive name) |
| `conflict-handling: overwrite` | user chose to overwrite |

### End-to-end verification

Via the shipped Swift client (`LiveDriveClient.upload`), against 192.0.2.10:

```
upload "drop test ☂ éè.bin"  1,500,000 bytes  crc32=8e08c332
  → landed at /mydrive/drop test ☂ éè.bin
  → downloaded back, crc32=8e08c332, IDENTICAL to source
```

Spaces and non-ASCII in the filename round-trip fine (percent-encode each path segment,
leave the `/` separators alone).

### Previous findings that still stand

The tus handshake, the drive-scoped route family, and the ruled-out alternatives below are
all still accurate — they were simply not the missing piece.


Endpoint: `POST /proxy/drive/api/v1/files`

```
POST /proxy/drive/api/v1/files
  X-Csrf-Token: <csrf>
  Tus-Resumable: 1.0.0
  Upload-Length: 45
  Upload-Metadata: filename <b64>,contentType <b64>
→ 201 Created
   Location: /api/v1/files/75298dca-2792-4486-a84f-f021b0cb9612
```

```
PATCH /proxy/drive/api/v1/files/<uploadId>
  X-Csrf-Token: <csrf>
  Tus-Resumable: 1.0.0
  Upload-Offset: 0
  Content-Type: application/offset+octet-stream
  <bytes>
→ 204 No Content
   Upload-Offset: 45
```

Both steps succeed. The Drive UI uses **tus-js-client** (confirmed in the bundle, including
`Upload-Concat: partial` / `final;` parallel-upload support).

### The exact metadata schema (read out of the UI bundle) ✅

```js
const h = join(prefixPath, relativePath);            // "/mydrive/sub/file.txt"
const {driveId, driveName, relPath} = parseDrivePath(h);

endpoint = driveId ? pathScoped(h) : "/files";

metadata = {
  filename:        b64(basename(h)),
  dir:             b64(relPath),          // directory INSIDE the drive
  "task-id":       taskId,
  "modify-time":   "YYYY-MM-DDTHH:mm:ss.SSSZ",   // from file.lastModified
  ...(driveName ? {"shared-drive": driveName} : {}),   // shared drives only
  ...(override  ? {"conflict-handling": "overwrite"} : {}),
};
```

Metadata key constants, verbatim from the bundle:
`"shared-drive"`, `"task-id"`, `"conflict-handling"`, `"modify-time"`, `"overwrite"`.

### Ruled out (still true)

`POST /files/{drivepath}`, `PUT /resources/{path}`, raw-bytes `POST /resources/{path}`
(creates a 0-byte file, body ignored), and query params `?driveType= ?path= ?dir= ?parent=
?drive=`.

### Drive-scoped route family (found, partially mapped) 🔬

The UI builds a second, drive-id-addressed path space:

```js
const v = `/drives/${driveId}/files/${filePath}`;
request(Y.p({path: [v, "children"], query: {...}}));   // directory listing
request(Y.p({path: [v, "content"]}));                  // file download
request(Y.p({path: [v, "thumbnail"]}));
request(Y.p({path: [v, "streaming", "<id>", "m3u8"]})); // HLS
```

Confirmed present on the server:

| Call | Result |
|---|---|
| `GET /api/v1/drives/{id}/files//children` | `301` → `/api/v1/drives/{id}/files/children` — **route exists**, the 301 is slash-normalisation |
| `GET /api/v1/drives/{id}/files/x/children` | `404 {"err":{"msg":"Not Found","code":"ErrNotFound"}}` — note this is a *different* 404 (`msg:"Not Found"`) than the router's, i.e. the handler ran and the path missed |
| `POST /api/v1/drives/{id}/files/{name}` + tus headers | `201` + `Location: /api/v1/files/<uuid>` — same tus session as `POST /files` |

So both the drive-scoped and the flat `POST /files` entry points hand back the *same* tus
session, and PATCHing that session returns `204` with the correct `Upload-Offset`, yet the
session reports `{"status":"failed"}` and no object appears.

`Y.p` is the drive-scoped URL builder; `_$` = `apiUrlBase + path`, `fO` = `apiUrlBaseV2 + path`,
and `UL(template,{params,query})` substitutes `:param` segments and appends a query string:

```js
const _$ = p => `${apiUrlBase}${p}`;      // /api/v1…
const fO = p => `${apiUrlBaseV2}${p}`;    // /api/v2…
const UL = (e,{params,query}) => { /* :param substitution + qs */ };
```

---

## 8. Share links — full CRUD ✅

Registry from the bundle:

```js
{
  info:         "/file-sharing/info",
  enable:       "/file-sharing/enable",
  disable:      "/file-sharing/disable",
  links:        "/file-sharing/links",
  linkById:     "/file-sharing/links/:linkId",
  archives:     "/file-sharing/links/:linkId/archives",
  downloadFile: "/file-sharing/links/:linkId/files/:resourcePath",
  resourceLink: "/file-sharing/resource-links/:path"
}
```

### `GET /file-sharing/info` ✅ → `{"enabled":true}`

### `GET /file-sharing/links` ✅ → all links, `{"err":null,"type":"collection","data":[...]}`

### `POST /file-sharing/links` ✅ — create

Payload (from the bundle's share-link form builder):

```json
{
  "type": "public",
  "path": "/mydrive/.DS_Store",
  "expiresAt": "2026-10-16T11:28:20.000Z",
  "accessLimit": 0,
  "password": "optional"
}
```

- `path` is the **drive-qualified** path: `/mydrive/<rel>` or `/shared/<driveName>/<rel>`
- `expiresAt` is optional (omit for no expiry); ISO-8601
- `accessLimit` optional, `0` = unlimited
- `password` optional; sets `hasPassword: true`

Response `200` with the link wrapped in the standard envelope:

```json
{"err":null,"type":"single","data":{
  "id": "fdabd558-603f-47ee-943a-2aca755574b6",
  "token": "8c9b26a6-1414-45bd-9983-66515bc20018",
  "path": "/mydrive/.DS_Store",
  "type": "public",
  "expiresAt": "2026-10-16T11:28:20-04:00",
  "hasPassword": false,
  "accessLimit": 0,
  "accessedTimes": 0,
  "driveId": "0a527470-b749-4630-8f0b-3eb3e568dc02",
  "driveLocked": false,
  "createdBy": {"id": "...", "username": "***REMOVED***", "fullName": "Example User"},
  "sharedWith": [],
  "resource": {"name": ".DS_Store", "size": 24580, "isDir": false, "type": "blob", "...": "..."}
}}
```

**Take `token`/`id` from the response — never construct them.**

Duplicate link on the same path → `403 {"err":{"msg":"duplicated file sharing link","code":"ErrForbidden"}}`

### `GET /file-sharing/links/:linkId` ✅ → single link detail (same object)

### `DELETE /file-sharing/links/:linkId` ✅ → `{"data":"OK","type":"single"}`

### `GET /file-sharing/links/:linkId/files/:resourcePath` ✅ — **direct download URL**

Returns the raw file (`200 application/octet-stream`, byte-exact size). This is the
"copy direct download link" target.

### The shareable URL is `https://drop.ui.com/<token>` ✅

Captured from a real link created in the Drive UI:

```
link.id    = 0538b549-4339-4828-bcf8-f1f82a612f34
link.token = 45612462-ce2d-47ca-bdfd-3d7020c0f007
share URL  = https://drop.ui.com/45612462-ce2d-47ca-bdfd-3d7020c0f007
path       = /mydrive/Screenshot 2026-10-06 at 2.32.08 PM.png   (4,437,823 bytes)
```

**The URL embeds `token`, not `id`.** So:

```python
share_url = f"https://drop.ui.com/{link['token']}"
```

`https://drop.ui.com/<token>` returns a 217-byte shell loading `/index.1c8c7c3a0ba0803c9b90.js`
(3.3 MB) — a separate hosted SPA, distinct from the console's Drive UI.

### How the share page works (read from the drop.ui.com bundle)

```js
const PUBLIC = "/api/v1/file-sharing/public";          // base
const build  = sub => PUBLIC + (sub ? "/" + sub : ""); // sub-path builder
fetch("/api/v1/file-sharing/public/drive-info");       // 20 s timeout, boot probe
```

Hosts it talks to: `cloudaccess.svc.ui.com`, `cloudaccess.svc.ubnt.com`,
`api-gw.uid.df.ui.com`, `config.ubnt.com` — **the share page is brokered by Ubiquiti's cloud,
not served by the console.** Remote access must be enrolled for links to work for other people.

### The console does not expose those public routes ✅

| Path (no cookie) | Result |
|---|---|
| `/proxy/drive/api/v1/file-sharing/public/drive-info` | `401 {"error":{"code":401,...}}` — gateway blocks all of `/proxy/drive/api/*` |
| `/proxy/drive/public/api/v1/file-sharing/public/drive-info` | `404 page not found` |
| `/proxy/drive/public/api/v1/systems/info` | `200 {"data":{"isSetup":true}}` — the public root exists, but only carries boot/activation routes |
| `/proxy/drive/public/api/v1/unauthenticated-access` | 🔬 from the bundle: `POST {loginType, username}` |
| `/proxy/drive/public/api/v1/user-activation` | 🔬 `POST {password}`, `Authorization: Bearer <token>` |
| `/unifi-drive/<token>` | `200` 510-byte SPA shell (client-side route, unproven for shares) |

### Owner-side direct link (requires a session)

```
GET /proxy/drive/api/v1/file-sharing/links/{linkId}/files/{resourcePath}
```

`200 application/octet-stream`, byte-exact — but **`401` without a cookie** ✅. This is a
"copy my own direct link" affordance, *not* something to hand to another person.

So DriveDrop should offer two distinct copy actions:

| Menu item | Value |
|---|---|
| Copy share URL | `https://drop.ui.com/{token}` — works for anyone, needs remote access enrolled |
| Copy direct link (mine) | `/proxy/drive/api/v1/file-sharing/links/{id}/files/{path}` — needs your session |

---

## 9. Other route families found in the bundle 🔬

Extracted from the endpoint registry — all relative to `/proxy/drive/api/v1`:

```
# operations
/file-operation/:asyncId
/file-batch-operation                      /file-batch-operation/:asyncId
/resources/batch-operation

# trash
/trash
/trash-resources/trash/mydrive
/trash-resources/trash/shared/:sharedDriveName
/trash-resources:filePath

# snapshots
/snapshots/mydrive                         /snapshots/mydrive/:snapshotId
/snapshots/mydrive/:snapshotId/lock        /snapshots/mydrive/:snapshotId/restorations
/snapshots/shared/:sharedDriveName         /snapshots/shared/:sharedDriveName/:snapshotId
/snapshots/shared/.../restorations
/snapshot-settings/mydrive                 /snapshot-settings/personal/:userId
/snapshot-settings/shared/:sharedDriveName
/snapshot-deletion                         /snapshot-resources:filePath
/snapshot-resource-restorations

# encryption
/encryption/passwords                      /encryption/migration
/encryption/migration/snapshots/{mydrive,shared/:name}/:snapshotId[/time-estimation]
/encryption/migration-restoration/snapshots/...
/encryption/shared-drive-err-list/:driveId
/encryption/storage/pools/:poolId/password

# storage / systems
/systems/storage/shared                    /systems/storage/shared/:sharedDriveName/archives
/systems/storage/shared/:storageName/files
/systems/storage/shared/batch-operation    /systems/storage/personal/batch-operation
/systems/storage/snapshot/mydrive          /systems/storage/snapshot/drives/:driveId/:snapshotId
/systems/snapshot                          /systems/snapshot/mydrive
/systems/performance/file-operations       /systems/info
/admin/ldap/config/base

# M365 / OneDrive backup
/m365-backup/users/:userId/onedrive/versions
/m365-backup/tasks/:taskId/users/:userId/onedrive/versions/:version[/files[/:itemId[/content|/thumbnail|/preview]]]
```

---

## 10. Console-level endpoints (not Drive) ✅

```
POST /api/auth/login            POST /api/auth/logout      POST /api/auth/refresh
POST /api/auth/nca              requires {token, ssoId}
POST /api/sso/login             /api/sso/login/mfa/send    /api/sso/login/mfa/poll
GET  /api/ping                  204, no auth
GET  /api/apps                  {apps:[{name:"users",...}], controllers:[{name:"drive",
                                version:"4.4.9", uiCdn:".../unifi-drive-ui/4.4.9-0d145a"}]}
GET  /api/system                hardware: disks[], raid, firmware, isSetup
GET  /api/integrations          API keys (session-auth)
```

`GET /api/apps` → `controllers[]` is how you discover the Drive version and UI bundle.

---

## 11. Port / topology notes ✅

| Port | Service | Unknown-path behaviour |
|---|---|---|
| 443 | nginx: portal + `/proxy/*` | 1533-byte portal SPA fallback |
| 9443 | UniFi core gateway | `{"code":404,"codeS":"CODE_NOT_FOUND","msg":"The API was not found.","error":"you entered no-man zone"}` |
| 80 | → 301 to 443 | |
| 22 | SSH | |

Only 80/443/9443 are open.

---

## 12. Still open

1. ~~Upload destination~~ ✅ **solved** — it was `Upload-Metadata: checksum`, a real CRC32,
   plus the `/proxy/drive` prefix on the tus `Location` (§7). Verified byte-exact through the
   shipped Swift client.
2. ~~Visitor share URL~~ ✅ **solved** — `https://drop.ui.com/<token>` (§8).
3. **Search** ❓ — `/api/v1/search` GET hangs; find the right parameters.
4. **Password-protected links** 🔬 — `hasPassword` confirmed as an output field; the
   visitor-side unlock (`/proxy/drive/public/api/v1/user-activation` with
   `Authorization: Bearer <token>`) is untested.

---

## 13. Re-deriving anything in this document

```bash
# 1. authenticate, keep the TOKEN cookie
curl -k -c jar.txt -X POST https://192.0.2.10/api/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"u","password":"..."}'

# 2. grab the csrf token off any response
curl -k -b jar.txt -D - -o /dev/null https://192.0.2.10/proxy/drive/api/v1/users/me \
  | grep -i x-csrf-token

# 3. discover the Drive version + UI bundle
curl -k -b jar.txt https://192.0.2.10/api/apps | jq '.controllers[]|select(.name=="drive")'

# 4. read the endpoint registry out of the bundle
curl -k https://192.0.2.10/unifi-drive/index.<hash>.js -o drive_ui.js
grep -oE '\("(/[a-z0-9_/.:{},-]{3,110})"\)' drive_ui.js | sort -u
```

Step 4 is the one that matters — the bundle is a complete, authoritative route map.
Always pass `--max-filesize` when probing `/files/...`: directories stream whole-subtree
ZIPs and Range is ignored (one probe pulled 635 MB).

---

## 14. Live-verified product flows

These are the exact calls DriveDrop makes, all confirmed against the console:

| Product action | Call |
|---|---|
| Sign in | `POST /api/auth/login` → `TOKEN` cookie |
| Free-space footer | `GET /api/v2/storage` |
| Populate the list | `GET /api/v1/file-sharing/links` |
| Right-click → Copy share URL | `https://drop.ui.com/{link.token}` — **token, not id** |
| Right-click → Copy direct download URL | `GET /api/v1/file-sharing/links/{id}/files/{resourcePath}` (session required) |
| Right-click → Set expiration | `PATCH /api/v1/file-sharing/links/{id}` `{"expiresAt": iso}` |
| Right-click → Delete link | `DELETE /api/v1/file-sharing/links/{id}` |
| Browse for upload destination | `GET /api/v1/resources/{mydrive\|shared/<name>}/{path}` |
| Delete an uploaded file | `DELETE /api/v1/resources/{path}` → moves to trash |
| Upload | `POST /api/v1/files` + `PATCH` 512 KiB chunks, `checksum` = CRC32 (§7) |

Whole flow exercised end-to-end by the client harness: login → usage → list → upload →
byte-exact download compare → create share → re-expire → delete link → delete file.

# UniFi Drive API — reference

Verified against **UNAS Pro**, UniFi OS **4.0.4**, Drive controller **4.4.9**
(`uiCdn: …/unifi-drive-ui/4.4.9-0d145a`), 2026-10-09.

Working implementations: [`apps/macos`](../apps/macos) (Swift), [`apps/windows`](../apps/windows) (Rust).
How any of this was established, and what was ruled out along the way, lives in
[discovery.md](discovery.md).

## 0. How to read this

Every statement here was exercised against a live console. Confidence is marked per section:

| Marker | Meaning |
|---|---|
| **Verified** | called successfully; request and response captured |
| **Mapped** | route and shape confirmed by the error oracle or the UI bundle; payload not exercised |
| **Unknown** | see [§13](#13-open-questions) |

Behavior that will break a client if it is not followed is written as a numbered
**constraint** (C1…C20). They are indexed below and referenced from the section that
explains them.

## 1. Constraint index

| # | Rule | § |
|---|---|---|
| C1 | Login must be sent **without** a `TOKEN` cookie, or the gateway returns 403 | [3.2](#32-login) |
| C2 | `rememberMe: true` is the only spelling that extends the session (2 h → 30 d) | [3.3](#33-session-lifetime) |
| C3 | The CSRF token is a claim inside the `TOKEN` JWT; capture cookie and header from the same login | [3.4](#34-csrf) |
| C4 | The tus `Location` header is Drive-relative; prefix `/proxy/drive` before PATCH | [8.2](#82-the-contract) |
| C5 | `Upload-Metadata: checksum` must be the file's real CRC32 | [8.4](#84-checksum) |
| C6 | tus finalize is asynchronous; poll before creating a share link | [8.6](#86-finalize-is-asynchronous) |
| C7 | A **drive root** needs a trailing slash (`mydrive/`, `shared/<name>/`); subdirectories accept either form | [6.1](#61-listing) |
| C8 | Valid drive-type path segments are `mydrive` and `shared` only | [6.1](#61-listing) |
| C9 | `GET /files/<directory>` streams a ZIP and ignores `Range`; never probe it blindly | [7](#7-download) |
| C10 | Duplicate uploads are auto-renamed `name (1).ext`; re-read the name that landed | [6.4](#64-conflicts) |
| C11 | `DELETE /resources/{path}` is a soft delete into `/trash` | [6.3](#63-methods-on-resourcespath) |
| C12 | A share URL embeds `link.token`, never `link.id` | [9.4](#94-the-visitor-url) |
| C13 | The owner-side direct link requires your session; it is not a visitor URL | [9.5](#95-owner-side-direct-link) |
| C14 | Paths match byte-exactly. Resolve them from the listing, never from a displayed name | [6.5](#65-paths-are-identifiers) |
| C15 | Upload `dir` is personal-drive-relative; missing parents are created for you | [8.5](#85-dir) |
| C16 | Chunk size is 524288 bytes | [8.7](#87-chunking) |
| C17 | Two different error envelopes: gateway `{error:…}` and Drive `{err:…}` | [4](#4-response-envelopes) |
| C18 | A UniFi OS API key cannot authorize Drive file operations | [3.5](#35-api-keys) |
| C19 | A second link on the same path returns 403 `ErrForbidden`, not the existing link | [9.2](#92-create) |
| C20 | Unknown paths fall back to the portal HTML; use response size to tell "no route" from a handler | [2](#2-base-urls-and-routing) |
| C21 | The direct-link route takes the resource **name**; the drive-qualified path returns 403 | [9.5](#95-owner-side-direct-link) |
| C22 | `conflict-handling: overwrite` replaces in place, and an existing share link follows the new bytes | [6.4](#64-conflicts) |
| C23 | `expiresAt` is **create-only**. `PATCH` returns 200 and ignores it; changing expiry rotates the token | [9.3](#93-update-and-delete) |
| C24 | A share link's `type` accepts only `public` | [9.2](#92-create) |
| C25 | An unset `expiresAt` comes back as `""`, not `null` | [9.1](#91-read) |

---

## 2. Base URLs and routing

From the Drive UI bundle configuration:

```js
apiUrlBase:          "/api/v1"
apiUrlBaseV2:        "/api/v2"
wsUrlBase:           "/api/ws"
standaloneApiPrefix: "/proxy/drive"     // console-proxied, session-authenticated
publicApiPrefix:     "/public"          // unauthenticated share site
localDrivePortalEntryName: "unifi-drive"
```

The authenticated root is therefore:

```
https://<console>/proxy/drive/api/v1
https://<console>/proxy/drive/api/v2
```

The Drive SPA is served under `/unifi-drive/*`. Any other unknown path returns the UniFi OS
portal HTML. **C20** — the fallback is 1533 bytes and a real handler's 404 is a JSON
envelope, so response size distinguishes "there is no such route" from "the route exists and
rejected your arguments".

---

## 3. Authentication
Drive is session-authenticated. There is no token, key or header that substitutes for a
session (C18).

### 3.1 Request

```
POST /api/auth/login
Content-Type: application/json

{"username": "<REDACTED-USER>", "password": "…", "rememberMe": true}
```

| Result | Status | Body |
|---|---|---|
| success | 200 | user object: `unique_id`, `full_name`, `email`, `roles`, `password_revision` |
| malformed body | 400 | `{"code":"VALIDATION_ERROR","validationErrors":[…]}` |
| bad credentials | 403 | `{"code":"AUTHENTICATION_FAILED_INVALID_CREDENTIALS"}` |
| too many attempts | 429 | `{"code":"AUTHENTICATION_FAILED_LIMIT_REACHED"}` |

Success sets the session cookie:

```
set-cookie: TOKEN=<jwt>; path=/; samesite=none; secure; httponly; partitioned
```

The `partitioned` attribute matters for browser embeds only; native clients should strip
`Secure`/`SameSite`/`Partitioned` if their cookie store rejects them.

The 429 is easy to hit by accident: a client that logs in once per command will lock itself
out mid-script. Cache the session.

### 3.2 Login

**C1** — login is refused when a `TOKEN` cookie is attached:

```
POST /api/auth/login   Cookie: TOKEN=<anything>
→ 403 {"error":{"code":403,"message":"Forbidden"}}
```

That 403 is indistinguishable from a CSRF failure or a permissions problem, and it is
**permanent**: any client whose cookie jar survives between launches can never sign in again.
Start every login from an empty cookie jar. Most cookie stores expose no "clear", so
construct a new client.

### 3.3 Session lifetime

**C2** — the login body controls the token lifetime:

| body | `exp - iat` | `isRemembered` |
|---|---|---|
| `{username, password}` | 7 200 s (2 h) | `false` |
| `{username, password, rememberMe: true}` | **2 592 000 s (30 d)** | `true` |
| `{…, remember: true}` | 7 200 s | `false` — wrong key |
| `{…, remember_user: true}` | 7 200 s | `false` — wrong key |

The response also carries `X-Token-Expire-Time` in epoch **milliseconds**, which equals the
JWT `exp` exactly. Use it for a countdown rather than decoding the JWT yourself.

Changing the account password bumps `password_revision`, which invalidates every outstanding
token.

### 3.4 CSRF

Every write (POST, PUT, PATCH, DELETE) is rejected with
`403 {"error":{"code":403,"message":"Forbidden"}}` unless `X-Csrf-Token` is sent.

- Read it from the **login response** header `x-csrf-token`. Proxied Drive GETs do not
  reliably carry it.
- Any response may rotate it via `x-updated-csrf-token`; mirror that into the next write.
- **C3** — the CSRF value is also a claim *inside* the `TOKEN` JWT (`payload.csrfToken`).
  Pairing a CSRF token from one login with the cookie from another fails the gate, and the
  failure looks identical to an expired token. Capture cookie and header from the same
  round trip and replace them together.

### 3.5 API keys

**C18** — a UniFi OS API key authenticates the *connection* but carries no *user identity*,
so it cannot authorize Drive file operations:

| Credential sent to `/proxy/drive/api/v1/users` | Result |
|---|---|
| none | 401 `Unauthorized` (gateway) |
| `X-API-KEY: <key>` | reaches the service, `403 invalid auth user ID` |
| `Authorization: Bearer <key>` | 401 (gateway) |

Exactly one Drive route accepts it: `GET /api/v2/storage`. The portal's own API-key
documentation generator covers Network, Protect and Access — **there is no Drive scope**.

### 3.6 Headers accepted at the CORS preflight

```
Content-Type, Cache-Control, If-Modified-Since, Jwt, Range, Tus-Resumable,
Upload-Length, Upload-Metadata, Upload-Offset, X-Connection-Type, X-Csrf-Token,
X-Requested-With, X-Token-Expire-Time, X-UidToken, X-Updated-Csrf-Token,
X-User-Agent, X-Api-Key, X-Ui-Setup-Poll-Token, Authorization
```

**Only the `TOKEN` cookie is required for reads, plus `X-Csrf-Token` for writes.** Verified
by omission: a `GET` with just the cookie returns 200, and a `POST` with cookie + CSRF but no
`X-Connection-Type` and no `Origin` also succeeds, while the same `POST` without CSRF gets
403. The clients still send `X-Connection-Type: local` and `Origin: https://<console>` because
the UI does, not because they are needed.

---

## 4. Response envelopes

Two independent producers, two shapes. **C17** — a client that parses only one will treat a
gateway rejection as an empty successful body.

```jsonc
// Drive service: "err"
{"err": null, "type": "single", "data": {…}}
{"err": null, "type": "collection", "data": […]}
{"err": {"msg": "route not found", "code": "ErrNotFound"}}
{"err": {"msg": "duplicated file sharing link", "code": "ErrForbidden"}}
{"err": {"msg": "Bad Request", "data": [], "metadata": {"error": "invalid drive type"}}}

// Console gateway: "error"
{"error": {"code": 401, "message": "Unauthorized"}}
{"error": {"code": 403, "message": "Forbidden"}}
```

`{"data":"OK","type":"single"}` is the success shape for DELETE.

Note the two distinct 404s: the router answers `msg:"route not found"`, while a handler that
ran and missed answers `msg:"Not Found"`. The second one tells you the route is real.

---

## 5. Identity and inventory
| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/users/me` | current user: `id`, `username`, `isOwner`, `roles[].systemKey`, `usage`, `appliedStorageProfile` |
| GET | `/api/v1/users` | collection of Drive users |
| GET | `/api/v1/groups` | Drive groups |
| GET | `/api/v1/drives`, `/api/v2/drives` | `{drives:[…]}` |
| GET | `/api/v2/storage` | RAID pools. **Top-level `{"pools":[…]}`, not wrapped in `data`.** The only route an API key can read (C18) |

Usage is the sum over `pools[]` of `capacity` and `usage`.

Drive object:

```json
{
  "id": "0a527470-b749-4630-8f0b-3eb3e568dc02",
  "type": "shared | personal",
  "name": "example-user",
  "status": "active",
  "storagePoolId": "cf78bf79-af1c-4ee6-97c5-155c602aca90",
  "quota": -1,
  "usage": 6102280962048,
  "role": "owner | admin | editor | viewer",
  "protections": {"encryptionStatus": "unencrypted", "remoteBackupEnabled": false, "snapshotEnabled": false},
  "memberCount": 1,
  "nfsIsolated": false
}
```

`type` here is `personal`, but that is **not** the URL keyword — see C8.

---

## 6. Resources

`/resources/{path}` is the metadata and mutation surface for files and directories. Verified.

### 6.1 Listing

```
GET /proxy/drive/api/v1/resources/mydrive/<rel>
GET /proxy/drive/api/v1/resources/shared/<driveName>/<rel>
```

```json
{
  "err": null, "type": "single",
  "data": {
    "name": "", "isDir": true, "isSymlink": false,
    "birthTime": "2025-09-02T19:00:55.484005818-04:00",
    "items": [
      {
        "name": "RiftCommand.zip",
        "path": "/mydrive/RiftCommand.zip",
        "isDir": false, "type": "blob",
        "size": 117058589, "mode": 432, "extension": ".zip",
        "birthTime": "…", "modifyTime": "2026-09-12T17:47:51-04:00",
        "owner": {"id": "…", "fullName": "Example User"}
      }
    ]
  }
}
```

Children are under `data.items`, never `children`. Each `path` is fully qualified
(`/mydrive/dev`).

**C7** — the trailing slash is load-bearing: `GET /resources/mydrive` returns
`route not found`, `GET /resources/mydrive/` returns 200.

**C8** — valid drive-type segments are `mydrive` and `shared` only. `personal`, `home`,
`user`, `mine`, `self`, `private` all return `{"metadata":{"error":"invalid drive type"}}`.

| Path | Result |
|---|---|
| `/resources/mydrive/` | 200 — personal drive root |
| `/resources/shared/Backups/` | 200 — shared drive root |
| `/resources/mydrive/report.pdf` | 200 — single object |
| `/resources/shared/nope/` | 400 `get drive path failed` |
| `/resources/personal/` | 400 `invalid drive type` |

### 6.2 Create

```
POST /proxy/drive/api/v1/resources/mydrive/Archive/2026
X-Csrf-Token: …
{"isDir": true}
→ 200 null
```

An empty body (`{}`) creates a 0-byte **file**; `{"isDir":true}` creates a **directory**.
Nested paths are created in one call, so this is `mkdir -p`. In practice you rarely need it:
upload creates missing parents itself (C15).

### 6.3 Methods on `/resources/{path}`

| Method | Effect | Response |
|---|---|---|
| GET | list directory, or stat one object | JSON, §6.1 |
| POST | create file or directory | `200 null` |
| PATCH | update metadata | 200; the body must be JSON |
| DELETE | move to trash | `{"data":{"path":"/trash/mydrive/<name>"}}` |
| PUT | — | `route not found` |

**C11** — DELETE is soft. The response names the trash path; emptying the trash is a
different route family ([§10](#10-other-route-families), Mapped).

### 6.4 Conflicts

**C10** — by default uploads never overwrite. Dropping `report.txt` where one exists yields
`report (1).txt`, then `report (2).txt`. A successful upload therefore does **not** mean your
file is at the name you sent; read the name back from the listing when it matters.

**C22** — adding `conflict-handling` (base64 of `overwrite`) to `Upload-Metadata` replaces the
existing object instead. Verified end to end:

| step | result |
|---|---|
| upload `probe.txt` (100 B), then upload the same name with `conflict-handling: overwrite` (250 B) | **one** object, 250 B — no `(1)` sibling |
| create a share link, then overwrite the file | link still resolves; `resource.size` tracks the new object |

That makes "publish a new build to the same URL" possible without deleting and re-linking.
It also means an overwrite silently invalidates whatever people already downloaded, so it
belongs behind an explicit user choice, not a default.

### 6.5 Paths are identifiers

**C14** — the server matches paths byte-exactly, and macOS filenames routinely contain
characters that render as a space. Screenshot names use **U+202F** (narrow no-break space)
before "AM"/"PM":

```
stored   /mydrive/Public/Screenshot 2026-10-05 at 3.23.01 PM.png   (U+202F)
typed    /mydrive/Public/Screenshot 2026-10-05 at 3.23.01 PM.png   (U+0020)
→ 404 {"err":null,"data":null}
```

Take paths from the `path` field the listing returns. If you must accept human input, fold
U+202F, U+00A0 and U+2007 to a space for *matching*, then use the server's own value for the
request. Percent-encode each path segment individually and leave `/` separators alone.

---

## 7. Download
```
GET /proxy/drive/api/v1/files/mydrive/<rel>
GET /proxy/drive/api/v1/files/shared/<driveName>/<rel>
```

- **File** → raw bytes, `Content-Disposition`, `Accept-Ranges`, `Range` honored.
- **Directory** → a ZIP of the subtree, streamed. There is no flag to disable it: `?list=`,
  `?depth=`, `?recursive=` and `Accept: application/json` all still return a zip. Use
  `/resources/` for listings.

**C9** — `Range` is **ignored** on the directory path. A ranged probe of a large share pulled
635 MB. Always bound discovery probes (`curl --max-filesize`).

The route is GET/HEAD only; POST/PUT/PATCH/DELETE on `/files/{type}/…` return `route not found`.

---

## 8. Upload

tus 1.0.0. Verified byte-exact through both shipped clients.

### 8.1 Required metadata

| Key | Required | Value |
|---|---|---|
| `filename` | **yes** | base64 of the basename |
| `checksum` | **yes** | base64 of 8 lowercase hex CRC32 of the body (C5) |
| `dir` | no | base64 of the personal-drive-relative directory; absent means the root (C15) |
| `task-id` | no | base64 of a client-generated id |
| `modify-time` | no | base64 of `YYYY-MM-DDTHH:mm:ss.SSSZ` |
| `shared-drive` | shared drives only | base64 of the drive name |
| `conflict-handling` | only to overwrite | literal `overwrite` |

All values are base64, joined as `key value` pairs separated by commas.

### 8.2 The contract

```
POST /proxy/drive/api/v1/files
  Cookie: TOKEN=<jwt>
  X-Csrf-Token: <csrf>
  X-Connection-Type: local
  Origin: https://<console>
  Tus-Resumable: 1.0.0
  Upload-Length: 1500000
  Upload-Metadata: filename <b64>,dir <b64>,task-id <b64>,checksum <b64>
→ 201 Created
  Location: /api/v1/files/08e0a12b-cf93-48db-8b91-09dd2088b075
```

```
PATCH /proxy/drive/api/v1/files/<uploadId>
  Tus-Resumable: 1.0.0
  Upload-Offset: 0
  Content-Type: application/offset+octet-stream
  <up to 524288 bytes>
→ 204 No Content
  Upload-Offset: 524288
```

Repeat until `Upload-Offset == Upload-Length`.

**C4** — the returned `Location` is relative to the **Drive service**, not the console.
PATCHing `https://<console>/api/v1/files/<id>` returns 404:

```python
upload_url = console + "/proxy/drive" + location
```

### 8.3 Both entry points share one session

`POST /api/v1/drives/{driveId}/files/{name}` with the same tus headers returns the same kind
of `Location` and is PATCHable in the same way. The flat `POST /files` form is the one the
clients use.

### 8.4 Checksum

**C5** — `checksum` is CRC32 of the file body, formatted as 8 lowercase hex characters, then
base64-encoded like every other metadata value:

```python
checksum = base64.b64encode(format(zlib.crc32(data) & 0xffffffff, "08x").encode())
```

Reference vectors: `""` → `00000000`, `"abc"` → `352441c2`,
`"The quick brown fox jumps over the lazy dog"` → `414fa339`.

**This is the failure mode of the whole API.** With a wrong checksum every PATCH answers 204
with a correct `Upload-Offset`, and only at finalize does the server discard the session. The
upload looks successful and the object never appears.

### 8.5 dir

**C15** — `dir` is relative to the personal-drive root, not a `/mydrive/…` path, and missing
parents are created by the upload itself. Uploading into `/Public` needs no `mkdir` and no
existence check.

Normalize the value before sending (`Public`, `Public/`, `/Public/` → `/Public`): the server
does not trim a trailing slash.

### 8.6 Finalize is asynchronous

**C6** — after the last 204 the object is not immediately queryable, and a share link created
in that window cannot be made. Poll `GET /resources/{path}` until it answers 200 before
sharing. The clients poll at 0.25 s, backing off to 2 s, for up to 60 s, and report
"finalizing" to the user because byte progress is already at 100%.

### 8.7 Chunking

**C16** — 524288 bytes, matching the Drive UI, which uploads a 5,608,957-byte file as 11
PATCHes.

### 8.8 Duplicate pre-flight

The UI checks before uploading:

```
POST /proxy/drive/api/v2/drives/{driveId}/files/%2F%2F/check-filenames
Content-Type: application/json
{"filenames": ["IMG_1039.jpg"]}
```

The `%2F%2F` is a literal `//`: the route is `/files/{parentPath}/check-filenames`, with an
empty parent for the drive root.

### 8.9 Verified round trip

```
upload "drop test ☂ éè.bin"  1,500,000 bytes  crc32=8e08c332
→ landed at /mydrive/drop test ☂ éè.bin
→ downloaded back, crc32=8e08c332, identical
```

Spaces and non-ASCII round-trip correctly when each segment is percent-encoded separately.

---

## 9. Share links
Registry, relative to `/proxy/drive/api/v1`:

```js
info:         "/file-sharing/info"
enable:       "/file-sharing/enable"        disable: "/file-sharing/disable"
links:        "/file-sharing/links"
linkById:     "/file-sharing/links/:linkId"
archives:     "/file-sharing/links/:linkId/archives"
downloadFile: "/file-sharing/links/:linkId/files/:resourcePath"
resourceLink: "/file-sharing/resource-links/:path"
```

### 9.1 Read

| Call | Result |
|---|---|
| `GET /file-sharing/info` | `{"enabled": true}` |
| `GET /file-sharing/links` | `{"type":"collection","data":[…]}` |
| `GET /file-sharing/links/{id}` | single link object |

**C25** — a link with no expiry reports `"expiresAt": ""`, an empty string, not `null` and
not absent. A strict RFC-3339 parser will throw or treat it as a valid date; treat empty as
"never".

Links may point at **directories** as well as files — `POST` with a directory path returns a
normal link and token.

### 9.2 Create

```json
POST /file-sharing/links
{
  "type": "public",
  "path": "/mydrive/Public/report.pdf",
  "expiresAt": "2026-10-16T11:28:20.000Z",
  "accessLimit": 0,
  "password": "optional"
}
```

`path` must be **drive-qualified** (`/mydrive/…` or `/shared/<name>/…`). `expiresAt` is
optional (omit for no expiry); `accessLimit` `0` means unlimited; `password` sets
`hasPassword: true`.

**C24** — `type` accepts **only** `public`. `internal`, `shared`, `user` and `private` all
return `400 {"err":{"msg":"invalid request: unknown type"}}`.

Response:

```json
{"err":null,"type":"single","data":{
  "id": "fdabd558-603f-47ee-943a-2aca755574b6",
  "token": "8c9b26a6-1414-45bd-9983-66515bc20018",
  "path": "/mydrive/Public/report.pdf",
  "type": "public",
  "expiresAt": "2026-10-16T11:28:20-04:00",
  "hasPassword": false, "accessLimit": 0, "accessedTimes": 0,
  "driveId": "0a527470-…", "driveLocked": false,
  "createdBy": {"id": "…", "username": "<REDACTED-USER>", "fullName": "Example User"},
  "sharedWith": [],
  "resource": {"name": "report.pdf", "size": 24580, "isDir": false, "type": "blob"}
}}
```

Take `id` and `token` from the response; never construct them.

**C19** — a second link on the same path is `403 {"err":{"msg":"duplicated file sharing
link"}}`. It does not return the existing link, so fetch the list and match on `path` if you
want idempotency.

### 9.3 Update and delete

| Call | Body / result |
|---|---|
| `PATCH /file-sharing/links/{id}` | updates `accessLimit`. **Ignores `expiresAt`** (C23) |
| `DELETE /file-sharing/links/{id}` | `{"data":"OK","type":"single"}` |
| `PUT /file-sharing/links/{id}` | `route not found` |

**C23 — expiration cannot be changed.** `PATCH` answers **200** and leaves the stored value
untouched. Verified against a link whose `expiresAt` was set, patching to a clearly different
date: unchanged for `"2027-06-01T00:00:00.000Z"`, for an offset form, for epoch seconds, for
epoch millis, for `null`, and for the misspellings `expireAt`/`expiredAt`/`expiration`. The
same route with `{"accessLimit":7}` **does** update, so the route works — the field simply is
not writable.

The only way to change an expiry is **delete and recreate**, and that generates a **new
`token`**:

```
old token  880c8ed3-a83…   →   new token  4680dcb6-787…
```

So "set expiration" is not an in-place edit; it invalidates every URL already handed out for
that file. A client that offers it must say so. A client that PATCHes and then updates its
local model — which the first version of this one did — shows the user a change the server
never accepted.

### 9.4 The visitor URL

**C12** — the URL a visitor uses is:

```
https://drop.ui.com/{link.token}
```

**`token`, not `id`.** Captured from a real link:

```
link.id    = 0538b549-4339-4828-bcf8-f1f82a612f34
link.token = 45612462-ce2d-47ca-bdfd-3d7020c0f007
share URL  = https://drop.ui.com/45612462-ce2d-47ca-bdfd-3d7020c0f007
```

`drop.ui.com` is a separate hosted SPA, not the console. It is brokered by Ubiquiti's cloud
(`cloudaccess.svc.ui.com`, `cloudaccess.svc.ubnt.com`, `api-gw.uid.df.ui.com`), so **remote
access must be enrolled for links to work for other people**. The console does not expose the
public share routes: `/proxy/drive/api/*` is gateway-blocked with 401, and
`/proxy/drive/public/api/v1/*` carries only boot and activation routes.

### 9.5 Owner-side direct link

```
GET /proxy/drive/api/v1/file-sharing/links/{linkId}/files/{resourcePath}
```

Returns the raw bytes, but **C13** — 401 without a session cookie. It is a "copy my own
direct link" affordance, not something to hand to another person.

**C21** — `{resourcePath}` is the resource **name**, not its drive-qualified path. For a file
at `/mydrive/Public/probe.txt`:

| `{resourcePath}` sent | Result |
|---|---|
| `probe.txt` | 200, correct bytes |
| `/mydrive/Public/probe.txt` | **403** `{"err":{"msg":"Forbidden","code":"ErrForbidden"}}` |
| `//mydrive/Public/probe.txt` | 301, then 403 |

This is easy to get wrong because the link object's own `path` field *is* qualified, and
reusing it looks obviously correct. Take the last path segment.

Two distinct actions:

| Menu item | Value | Works for |
|---|---|---|
| Copy share URL | `https://drop.ui.com/{token}` | anyone, if remote access is enrolled |
| Copy direct link | `/proxy/drive/api/v1/file-sharing/links/{id}/files/{path}` | you, while signed in |

---

## 10. Other route families
Present on the server, payloads not exercised. Relative to `/proxy/drive/api/v1`. Full list
and how it was extracted: [discovery.md](discovery.md).

| Family | Use |
|---|---|
| `/file-operation/{asyncId}`, `/file-batch-operation`, `/resources/batch-operation` | asynchronous and bulk moves |
| `/trash-resources/trash/{mydrive,shared/<name>}` | **Verified** — lists trashed objects with `deletedAt`, `deletedBy`, `deletedFrom` |
| `DELETE /trash-resources/trash/{path}` | **Verified** — purges permanently (irreversible) |
| restore from trash | not found; `POST /resources/batch-operation` accepts `srcDsts` but answers `invalid action permission: action not supported` for `move`, `copy`, `restore`, `rename`, `trash` |
| `/trash` | `route not found` — the registry entry is not a live route |
| `/snapshots/…`, `/snapshot-settings/…`, `/snapshot-deletion` | snapshots |
| `/encryption/passwords`, `/encryption/migration/…`, `/encryption/storage/pools/{poolId}/password` | at-rest encryption |
| `/systems/storage/…`, `/systems/info`, `/systems/performance/file-operations` | storage administration |
| `/m365-backup/…` | OneDrive backup |
| `/api/v1/search` | exists; see [§13](#13-open-questions) |

---

## 11. Console endpoints (not Drive)
```
POST /api/auth/login      POST /api/auth/logout      POST /api/auth/refresh
POST /api/auth/nca        {token, ssoId}
POST /api/sso/login       /api/sso/login/mfa/send    /api/sso/login/mfa/poll
GET  /api/ping            204, no auth
GET  /api/apps            controllers[] → Drive version and UI bundle URL
GET  /api/system          hardware, disks, raid, firmware, isSetup
GET  /api/integrations    API keys (session-auth)
```

`GET /api/apps` is how you discover the Drive controller version and the bundle to read.

---

## 12. Topology
| Port | Service | Unknown-path behavior |
|---|---|---|
| 443 | nginx: portal + `/proxy/*` | 1533-byte portal SPA fallback |
| 9443 | UniFi core gateway | `{"code":404,"msg":"The API was not found.","error":"you entered no-man zone"}` |
| 80 | redirect to 443 | |
| 22 | SSH | |

Nothing else is open.

---

## 13. Open questions

Ordered by how much they would change the product. "Test" is the smallest experiment that
answers it — each one creates its own fixture and deletes it, per the rule in §14.

### Worth doing

### Solved since the first pass

| # | Was | Now |
|---|---|---|
| U1 | Does overwrite work? | **Yes** — `conflict-handling: overwrite` replaces in place and the existing share link follows the bytes (C22) |
| U4a | Where did my deleted file go? | `GET /trash-resources/trash/{mydrive,shared/<name>}/` lists them with `deletedAt` / `deletedBy` |
| U4b | Can a trashed object be purged? | **Yes** — `DELETE /trash-resources/trash/{path}`, permanently and irreversibly |
| — | How does the direct-link route address the file? | By **name**, not by qualified path (C21). The old form 403'd; the shipped client was fixed |

### Still worth doing

| # | Question | Why it matters | Test |
|---|---|---|---|
| U2 | **Uploading into a shared drive** | Both clients can *read* `/shared/<name>/` but only upload to the personal drive. The biggest remaining functional gap | `POST /files` with `dir` + `shared-drive` metadata for a drive the account can write; verify under `/resources/shared/<name>/`. **Writes to a shared folder — confirm which drive is safe first** |
| U3 | **tus resume** | A 20 GB upload over Wi-Fi restarts from zero on any hiccup | Start an upload, kill it at ~40 %, `GET` the session Location for `Upload-Offset`, PATCH from there |
| U4c | **Restore from trash** | Purge works but nothing brings a file back, so "Delete" has no undo | `POST /resources/batch-operation` validates `srcDsts` yet rejects every action tried (`move`, `copy`, `restore`, `rename`, `trash`) with `action not supported`. Find the action enum in the bundle rather than guessing again |
| U4d | **Rename / move** | Same route family; would let the app rename without re-upload | As U4c — the validator reveals required fields one at a time, which is the fastest way to the schema |

### Worth knowing, cheap to find out

| # | Question | Why it matters | Test |
|---|---|---|---|
| U5 | **Search parameters** | A folder picker over 10k files wants server-side search; today the client lists one directory at a time | `GET /api/v1/search?query=` hangs past 25 s and `POST` is `route not found`. Try `?q=`, `?keyword=`, `?driveId=`, and the `/resources/batch-operation` family. Read the bundle for the call site rather than guessing |
| U6 | **`accessLimit` enforcement** | `PATCH {"accessLimit":7}` is confirmed writable, but nobody has confirmed the *Nth* visit is actually refused | Create a link with `accessLimit: 1`, fetch it twice, read `accessedTimes` |
| U7 | **Password-protected links, visitor side** | `password` is accepted on create and `hasPassword` comes back, but the unlock flow is untested, so the app cannot offer it honestly | Drive the visitor page against a link with a password and watch which route `drop.ui.com` calls |
| U8 | **Do links work with remote access off?** | The spec claims links depend on Ubiquiti cloud enrollment. That is asserted from the share page's hosts, never demonstrated | Toggle remote access on a test console and re-fetch a link. **Do not do this on a console you depend on** |

### Not worth pursuing

| Question | Why not |
|---|---|
| Snapshots, `/encryption/…`, `/m365-backup/…` | Administrative surfaces. A drag-and-drop uploader has no business mutating them, and getting it wrong destroys data |
| Parallel tus (`Upload-Concat: partial`) | The UI uses it for throughput. Sequential 512 KiB chunks already saturate a LAN; complexity is not paid for |
| Thumbnails, HLS `/streaming/…/m3u8` | Nice in a Drive client, out of scope here |
| `/api/v1/search` via brute force | See U5: read the bundle call site instead of guessing parameters |

### Known and accepted

| Limitation | Note |
|---|---|
| Duplicate names are auto-renamed (C10) | Until U1 lands |
| Directory download is always a ZIP and ignores `Range` (C9) | No flag disables it |
| API keys cannot touch Drive (C18) | Session login is the only way |
| Share links resolve through Ubiquiti's cloud | See U8 |
| Paths are byte-exact (C14) | Fold invisible spaces for matching only |

---

## 14. Re-deriving this document

```bash
# 1. authenticate. Send no cookies.
curl -k -c jar.txt -X POST https://<console>/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"<REDACTED-USER>","password":"***","rememberMe":true}'

# 2. the CSRF token is on the login response, not on proxied GETs
curl -k -c hdr.txt -o /dev/null -X POST https://<console>/api/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"<REDACTED-USER>","password":"***"}' \
  | grep -i x-csrf-token

# 3. Drive version and bundle URL
curl -k -b jar.txt https://<console>/api/apps \
  | jq '.controllers[] | select(.name=="drive")'

# 4. the authoritative route map
curl -k https://<console>/unifi-drive/index.<hash>.js -o drive_ui.js
grep -oE '\("(/[a-z0-9_/.:{},-]{3,110})"\)' drive_ui.js | sort -u
```

Step 4 is the one that matters: the bundle contains the complete endpoint registry.

Two safety rules when probing:

- always pass `--max-filesize` against `/files/…` (C9);
- never probe write methods against paths holding real data — create your own fixture and
  delete it, as `apps/windows/tests/live.rs` does.

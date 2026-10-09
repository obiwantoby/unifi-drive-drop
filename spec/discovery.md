# UniFi Drive API — discovery record

This is the investigation behind [api.md](api.md): how the endpoints were found, what was
tried and rejected, and which dead ends should not be re-attempted. **It is not a reference.**
If a fact here contradicts api.md, api.md is right.

Console: UNAS Pro, UniFi OS 4.0.4, Drive controller 4.4.9. Work done 2026-10-09.

---

## 1. Method

Four techniques did all the work.

**Read the bundle.** `GET /api/apps` gives the Drive controller version and its `uiCdn`
path; the minified `index.<hash>.js` contains a complete endpoint registry, the metadata key
constants, and the URL builders. Every successful guess in this project came from the bundle,
not from probing.

**Use the error oracle.** The Drive service answers a nonexistent route with
`{"err":{"msg":"route not found"}}` and an existing route with bad arguments with
`{"err":{"msg":"Not Found"}}` or a `metadata.error` string. That difference distinguishes
"no such route" from "the handler ran and rejected you", which turns path discovery into a
binary search.

**Fall back on response size.** Unknown paths outside `/unifi-drive/` return the 1533-byte
UniFi OS portal HTML. A 510-byte body means the Drive SPA shell. Size separates the two when
both are HTTP 200.

**Proxy and log.** `tools/capture_proxy.py` sat between the Drive web UI and the console and
recorded real requests. The upload contract, the chunk size and the `checksum` field all came
from a capture of the official UI doing the thing we could not make work.

`tools/discover.py` automates the oracle sweep.

---

## 2. The upload investigation

This took the longest and produced the most misleading feedback of anything in the API.

### What we tried first, and why it looked like it worked

`POST /proxy/drive/api/v1/files` with tus headers returned **201** and a `Location`. Every
`PATCH` returned **204** with a correct `Upload-Offset`. The upload reported complete. No
object ever appeared under `/resources`.

Two independent bugs were hiding behind that:

1. **PATCHing the wrong host.** `Location: /api/v1/files/<id>` is Drive-relative. We PATCHed
   `https://console/api/v1/files/<id>`, which 404s — but the earlier successful 201 made the
   session look healthy.
2. **No `checksum` metadata.** Once the prefix was fixed, chunks still returned 204. The
   server accepted the bytes and discarded the session at finalize. `GET` on the tus session
   reported `{"status":"failed"}` with no reason.

An early attempt also sent a `parentPath` key, which does not exist in the schema at all.

### Isolation test

4096-byte file, one metadata key varied per run, checking whether the object actually
appeared under `/resources` (the only reliable signal):

| metadata sent | PATCH | object landed |
|---|---|---|
| `filename` + `dir` + `task-id` + `modify-time` + valid `checksum` | 204 | yes |
| same, `checksum` = `deadbeef` | 204 | **no** |
| no `modify-time` | 204 | yes |
| no `dir` | 204 | yes |
| no `checksum` at all | 204 | no |

Conclusion: `filename` and `checksum` are mandatory; the rest are optional. The decisive
detail is that **every row returns 204** — the status code carries no information, and only
the re-read under `/resources` distinguishes success from silent discard.

### Ruled out

Do not re-try these; each returned `route not found`, a 405-equivalent, or a body that was
ignored:

- `POST /files/{drivepath}` with a body
- `PUT /resources/{path}`
- raw-bytes `POST /resources/{path}` — creates a 0-byte file, body discarded
- query parameters `?driveType=`, `?path=`, `?dir=`, `?parent=`, `?drive=`
- `POST /resources/{path}` with `{"isDir":true}` for a *file* upload (it makes a directory)

### Drive-scoped route family

The UI builds a second, drive-id-addressed path space:

```js
const v = `/drives/${driveId}/files/${filePath}`;
request(Y.p({path: [v, "children"], query: {…}}));    // directory listing
request(Y.p({path: [v, "content"]}));                 // file download
request(Y.p({path: [v, "thumbnail"]}));
request(Y.p({path: [v, "streaming", "<id>", "m3u8"]})); // HLS
```

Oracle results:

| Call | Result |
|---|---|
| `GET /api/v1/drives/{id}/files//children` | 301 → `/files/children` — route exists, the 301 is slash normalization |
| `GET /api/v1/drives/{id}/files/x/children` | 404 `msg:"Not Found"` — handler ran, path missed |
| `POST /api/v1/drives/{id}/files/{name}` + tus headers | 201 + `Location: /api/v1/files/<uuid>` — same session family as `POST /files` |

Both entry points hand back the same kind of tus session, so the flat form is sufficient.

### URL builders, verbatim from the bundle

```js
const _$ = p => `${apiUrlBase}${p}`;      // /api/v1…
const fO = p => `${apiUrlBaseV2}${p}`;    // /api/v2…
const UL = (e, {params, query}) => { /* :param substitution + query string */ };
```

### Metadata schema as the UI builds it

```js
const h = join(prefixPath, relativePath);          // "/mydrive/sub/file.txt"
const {driveId, driveName, relPath} = parseDrivePath(h);
endpoint = driveId ? pathScoped(h) : "/files";

metadata = {
  filename:        b64(basename(h)),
  dir:             b64(relPath),                     // directory INSIDE the drive
  "task-id":       taskId,
  "modify-time":   "YYYY-MM-DDTHH:mm:ss.SSSZ",       // from file.lastModified
  ...(driveName ? {"shared-drive": driveName} : {}),
  ...(override  ? {"conflict-handling": "overwrite"} : {}),
};
```

Key constants in the bundle: `"shared-drive"`, `"task-id"`, `"conflict-handling"`,
`"modify-time"`, `"overwrite"`. The UI uses **tus-js-client**, including
`Upload-Concat: partial` / `final;` for parallel multipart uploads — untested here.

---

## 3. Session and CSRF discoveries

**The 2-hour wall.** Sessions died after 2 h with no useful signal. Reading the JWT showed
`exp - iat == 7200` and `isRemembered: false`. Brute-forcing the login body:

| key tried | lifetime |
|---|---|
| `remember` | 7 200 s — ignored |
| `remember_user` | 7 200 s — ignored |
| `rememberMe` | **2 592 000 s** |

The wrong keys are accepted silently rather than rejected, which is why this took a sweep
rather than a read of an error message.

**Login 403 on a warm jar.** Every launch after the first returned
`403 {"error":{"code":403,"message":"Forbidden"}}`. URLSession's shared cookie jar persisted
the `TOKEN` across launches, and the gateway refuses login while one is attached. The message
is identical to a CSRF failure, so the first two debugging passes went to the CSRF code and
found nothing.

**CSRF is not a separate secret.** It is a claim inside the `TOKEN` JWT, so cookie and header
are fused. A stale CSRF with a fresh cookie fails the gate exactly like an expired session.

**Proxied GETs do not return it.** `X-Csrf-Token` appears reliably on the login response;
`/proxy/drive/...` GETs came back without it. Take it from login.

---

## 4. Listing and path discoveries

**`mydrive`, not `personal`.** The drives list reports `"type": "personal"`, which is the
obvious thing to put in the URL. It returns `invalid drive type`. The accepted segments are
`mydrive` and `shared`; `home`, `user`, `mine`, `self`, `private` were all tried.

**The trailing slash.** `GET /resources/mydrive` → `route not found`;
`GET /resources/mydrive/` → 200. Nothing in the error hints at this.

**`data.items`, not `children`.** And each child's `path` is fully qualified.

**Directories download as ZIP.** `GET /files/<dir>` streams a zip with no way to disable it,
and **ignores `Range`** — a ranged probe of one shared folder pulled 635 MB before we
understood what was happening. Always pass `--max-filesize` when probing.

**Auto-rename.** Uploads never overwrite; `report.txt` becomes `report (1).txt`. This was
mistaken for a duplicate-upload bug in the client.

**Invisible Unicode.** A delete of `Screenshot 2026-10-05 at 3.23.01 PM.png` returned 404
with a body of `null`, while the listing showed the file present. The stored name contains
**U+202F** (narrow no-break space) before "PM", which macOS uses for screenshot names and
Finder renders as an ordinary space. The typed path differed by one codepoint.

The fix is architectural rather than a Unicode hack: the listing's `path` field is the
identifier, and human input gets folded (U+202F, U+00A0, U+2007 → space) only for *matching*.

---

## 5. Share link discoveries

**`token`, not `id`.** Constructing `https://drop.ui.com/{id}` yields a page that loads and
then reports nothing. Capturing a link created in the official UI showed the URL uses
`link.token`.

**The visitor page is not served by the console.** `drop.ui.com` loads its own 3.3 MB bundle
and talks to `cloudaccess.svc.ui.com`, `cloudaccess.svc.ubnt.com`, `api-gw.uid.df.ui.com` and
`config.ubnt.com`. Share links are brokered by Ubiquiti's cloud, so they depend on remote
access being enrolled.

**The console's public root is nearly empty.** `/proxy/drive/api/*` is gateway-blocked with
401. `/proxy/drive/public/api/v1/*` exists but carries only boot and activation routes
(`/systems/info` answers `{"data":{"isSetup":true}}`).

**Duplicate links 403.** `{"err":{"msg":"duplicated file sharing link"}}` rather than
returning the existing link, so idempotency has to be built client-side by listing and
matching on `path`.

---

## 6. Full route registry extracted from the bundle

Relative to `/proxy/drive/api/v1` unless noted. Presence confirmed by the oracle; payloads
exercised only for what the clients use.

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

# file-sharing registry
/file-sharing/info      /file-sharing/enable     /file-sharing/disable
/file-sharing/links     /file-sharing/links/:linkId
/file-sharing/links/:linkId/archives
/file-sharing/links/:linkId/files/:resourcePath
/file-sharing/resource-links/:path
```

---

## 7. Artifacts created during discovery

All removed again: three 0-byte files in `mydrive` (deleted, in trash) and one share link on
`/mydrive/.DS_Store` (deleted, `{"data":"OK"}`). Abandoned tus sessions are garbage-collected
by the server.

The live test in `apps/windows/tests/live.rs` holds itself to the same rule and enforces it
with a `Drop` guard, so a panicking run still cleans up.

---

## 8. Corrections made along the way

Kept because the wrong version is plausible enough to be re-derived wrongly again.

| Believed | Actually |
|---|---|
| Upload is broken server-side | our `Location` was missing the `/proxy/drive` prefix |
| Upload works after the prefix fix | `checksum` metadata was absent |
| `POST /resources/{path}` ignores its body | `{"isDir":true}` creates a directory |
| Children are under `data.children` | `data.items` |
| Drive type segment is `personal` | `mydrive` |
| The storage body is wrapped in `data` | it is top-level `{"pools":[…]}` |
| A share URL uses `link.id` | `link.token` |
| `remember` extends the session | `rememberMe` |
| The 403 on relaunch was a CSRF problem | a `TOKEN` cookie was attached to login |
| The 404 on delete was a broken route | the filename contained U+202F |
| `GET /files/<dir>` can list JSON | it always streams a ZIP and ignores `Range` |

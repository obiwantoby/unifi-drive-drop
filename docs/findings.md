# How the Drive API was reverse-engineered

Narrative + method. **The endpoint reference lives in [`spec/api.md`](../spec/api.md).**
Raw captured responses are in [`spec/raw/`](../spec/raw/).

Target: `https://192.0.2.10` — UNAS Pro, UniFi OS 4.0.4, Drive controller 4.4.9.

---

## The oracle problem

The console returns three distinguishable 404s, which turned blind probing into a
reliable search:

| Response | Layer | Meaning |
|---|---|---|
| `404 page not found` (plain text, 19 b) | nginx/Go root | no upstream for that prefix |
| `{"err":{"msg":"route not found","code":"ErrNotFound"}}` | **Drive service** | reached the service, route does not exist |
| 1533-byte portal HTML, `200` | nginx SPA fallback | unknown path, *not* an API response |
| `{"error":{"code":401,...}}` | gateway | credential rejected |

Two different error envelopes (`err` vs `error`) cleanly separate the gateway from the
Drive service. Anything that was not `route not found` was a real route; anything whose
message *changed* (`invalid drive type` → `missing shared drive name` → `get drive path
failed`) revealed the path grammar one segment at a time.

## Step 1 — locate the service

`/proxy/drive/api/v2/files` returned JSON `route not found` while `/proxy/drive/v2/files`
returned plain-text `404 page not found`. That pinned the API root to `/proxy/drive/api/`.

## Step 2 — establish that the API key is not enough

```
no key   → 401 {"error":{"code":401,"message":"Unauthorized"}}     gateway
with key → 403 {"err":{"msg":"invalid auth user ID"}}               Drive service
```

The key passes the gateway (it reads `/api/v2/storage`, returning the real RAID-6 pool) but
carries no user identity, and share links are per-user. Confirmed independently by the
portal bundle, whose API-key documentation generator enumerates only three apps:

```js
case Network: return "/network/integration/v1/sites";
case Protect: return "/protect/integration/v1/meta/info";
case Access:  return "/access/integration/v1/developer/users";
```

No `Drive` case exists. **Session auth is mandatory.**

## Step 3 — login contract without credentials

`POST /api/auth/login` with `{}` returned a zod-shaped validation body naming the required
fields. One single request with a deliberately nonexistent username then revealed the
failure envelope (`403 AUTHENTICATION_FAILED_INVALID_CREDENTIALS`) without risking a
lockout. Contract fully pinned before any real credential was used.

## Step 4 — the drive-type oracle

With a session, `GET /api/v1/files/list?path=/` returned `invalid drive type`, and so did
`/files/root`. Both are the *same* error — proving the first path segment is the drive type,
not a verb. Following it:

```
/files/<anything>/      → invalid drive type
/files/shared/          → missing shared drive name     ← 'shared' is valid
/files/shared/Backups   → 200 (a ZIP)
/files/mydrive/         → 200                            ← 'mydrive' is the personal keyword
```

Note the trap: the drives list reports `"type": "personal"`, but the **URL keyword** is
`mydrive`. `personal`, `home`, `user`, `mine`, `self`, `private` all fail.

## Step 5 — GET returns ZIP, so listings are elsewhere

`GET /files/...` on a directory streams a ZIP of the whole subtree, and no query param or
`Accept` header disables it. A ranged probe was ignored and pulled **635 MB** — hence the
`--max-filesize` discipline in every later probe.

## Step 6 — the CSRF gate

`POST/PUT/PATCH/DELETE` all returned `403 Forbidden` from the *gateway*. The CORS preflight
header list named `X-Csrf-Token`; every response — including plain GETs — carries
`x-csrf-token`. Sending it moved every write past the gateway and into the service.

## Step 7 — read the frontend instead of guessing

The decisive move. `GET /api/apps` exposes:

```json
{"controllers":[{"name":"drive","version":"4.4.9",
  "uiCdn":"https://cdn.pkg.svc.ui.com/unifi-drive-ui/4.4.9-0d145a"}]}
```

`index.html` at that CDN path is world-readable and names the bundle, which the console
serves locally at `/unifi-drive/index.<hash>.js` (6.5 MB; the CDN itself 403s the JS).

Inside it: a complete endpoint registry, the config block (`apiUrlBase`,
`standaloneApiPrefix`, `publicApiPrefix`), the share-link request builder, and the
enumeration of every drive-type keyword. That replaced roughly every guess made so far:

```js
{ info:    "/file-sharing/info",
  enable:  "/file-sharing/enable",  disable: "/file-sharing/disable",
  links:   "/file-sharing/links",   linkById: "/file-sharing/links/:linkId",
  archives:"/file-sharing/links/:linkId/archives",
  downloadFile: "/file-sharing/links/:linkId/files/:resourcePath",
  resourceLink: "/file-sharing/resource-links/:path" }
```

Earlier blind wordlists against `/api/v1/` had missed every one of these, because none of
them are single words — they are hyphenated (`file-sharing`, `trash-resources`,
`snapshot-settings`, `batch-operation`, `user-activation`).

**Lesson:** when a JS frontend exists, extracting its endpoint registry beats fuzzing.

---

## What is confirmed working end-to-end

- session login + `TOKEN` cookie
- CSRF token acquisition and rotation
- drive/user/group/pool inventory
- **JSON directory listings** via `/resources/...`
- **file download** by path, and share-scoped direct download
- **share link create / read / list / delete** with expiry, password and access limit
- tus upload handshake (`201` + `Location`, `204` + `Upload-Offset`)

## What is still open

1. The tus metadata key that names the destination drive/path — the upload completes but the
   object does not land. 42 key/value candidates and 5 query params tested, all `failed`.
2. The visitor-facing share URL route (the public API root is live and unauthenticated; the
   page is a client-side route).
3. `/api/v1/search` parameters (GET hangs).

Details in `spec/api.md` §7, §8, §12.

## Cleanup

Test artefacts created during discovery: one share link on `/mydrive/.DS_Store`
(**deleted**, confirmed `{"data":"OK"}`) and ~44 abandoned tus upload sessions, which the
server GCs. No files were written to the drives.

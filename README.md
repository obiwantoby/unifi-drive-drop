# DriveDrop

Drag-and-drop file upload for **UniFi Drive** (UNAS Pro) that hands you a shareable URL.

Drop a file → it uploads → you get a link. Right-click (or two-finger click) a row to
copy the URL, open it, set an expiration, or delete it.

Two native clients, one behaviour:

| Platform | Stack | Look |
|---|---|---|
| macOS | Swift 6 + SwiftUI | liquid glass / `ultraThinMaterial`, borderless rounded panel |
| Windows | Rust + `eframe`/`egui` + `windows` crate | Fluent, real **Mica** backdrop via DWM |

```
unifi-drive-drop/
├── docs/
│   ├── findings.md         reverse-engineered, live-verified API facts
│   └── design.md           UI spec for both platforms
├── spec/
│   ├── api.md              the Drive endpoints each client implements
│   └── raw/                captured responses from discovery runs
├── tools/
│   └── discover.py         login + crawl the console, dump spec/raw/discovery.json
└── apps/
    ├── macos/              Swift package  -> DriveDrop.app
    └── windows/            cargo project  -> drivedrop.exe (Mica)
```

## Status

| Piece | State |
|---|---|
| Console identified | ✅ UNAS Pro, UniFi OS 4.0.4, Drive 4.4.9 |
| Session login | ✅ `POST /api/auth/login` → `TOKEN` cookie, exercised |
| CSRF gate | ✅ `X-Csrf-Token` from any response, rotation handled |
| Drive / user / pool inventory | ✅ |
| **JSON directory listing** | ✅ `GET /api/v1/resources/{mydrive\|shared/<name>}/{path}` |
| **File download** | ✅ `GET /api/v1/files/{path}` (dirs stream a ZIP) |
| **Create share link** | ✅ `POST /api/v1/file-sharing/links` + expiry, password, access limit |
| **List / read / delete share links** | ✅ all verified live |
| **Direct download URL** | ✅ `/file-sharing/links/{id}/files/{resourcePath}` |
| **Delete a file** | ✅ `DELETE /resources/{path}` → moves to trash |
| Upload handshake | ✅ tus `201`+`Location`, `204`+`Upload-Offset` |
| **Upload lands the object** | ✅ the whole thing was `checksum` = real CRC32, plus the `/proxy/drive` prefix on `Location` — see `spec/api.md` §7 |
| Session lifetime | ✅ `rememberMe: true` → 30-day token, transparent re-login on 401 |
| macOS app | ✅ complete: menu-bar resident, folder browsing, drag-and-drop with a stated policy for every input shape, drawn app icon |
| Windows client (library + CLI) | ✅ compiles clean, `cargo test` green, login/usage/browse/links verified live against a real console |
| Windows GUI (egui + Mica) | ❌ **not written.** The crate ships a library and a terminal client, nothing more |

The full loop — browse, upload, share, expire, delete — works on macOS against a real
console. On Windows the same API port works from a terminal; there is no window yet.

## Auth: why it uses a password, not the API key

The API key **is valid** — it authenticates past the console gateway and reads
`GET /proxy/drive/api/v2/storage` (your RAID-6 pool). But the Drive file API answers
`403 {"err":{"msg":"invalid auth user ID"}}`: the key authenticates the *connection* and
carries no *user identity*, and share links are per-user. UniFi's own portal bundle confirms
it — the API-key docs generator enumerates only Network, Protect and Access. **There is no
Drive scope.**

So DriveDrop signs in the way the Drive web UI does (`POST /api/auth/login`, keep the
`TOKEN` cookie, mirror `X-Csrf-Token`).

Recommended: create a dedicated local UniFi OS account with Drive access rather than
reusing an admin login. Re-run discovery any time with:

```bash
cd unifi-drive-drop
python3 tools/discover.py            # read-only crawl → spec/raw/discovery.json
```

Credentials come from `UNIFI_USER` / `UNIFI_PASS` or a prompt; only the session `TOKEN` is
written to disk (`.token`, chmod 600, gitignored).

## Security notes

- The console uses a self-signed cert; clients default to accepting it and warn. Use
  `--verify-tls` / the settings toggle once you have a real cert.
- macOS stores credentials in the Keychain (`com.drivedrop.session`). The Windows client
currently takes credentials from the environment; wiring it to Credential Manager is open
work, and until then do not put `DRIVEDROP_PASS` in a shared shell profile.
- Never commit `.token` — it is gitignored.

## Test artefacts

Discovery created and then removed: three 0-byte files in `mydrive` (deleted, now in trash)
and one share link on `/mydrive/.DS_Store` (deleted, `{"data":"OK"}`). The share-link count
is back to its original 6. Abandoned tus sessions are GC'd by the server.

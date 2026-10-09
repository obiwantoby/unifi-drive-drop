# DriveDrop — Windows

A Rust client for UniFi Drive. **The GUI does not exist yet.** What ships today is a
library and a terminal client, both verified against a real UNAS Pro console.

## What is real

| | |
|---|---|
| `src/models.rs` | domain types, mirrored from the macOS app |
| `src/api.rs` | HTTP client on the endpoints proven in [`spec/api.md`](../../spec/api.md) |
| `src/bin/drivedrop.rs` | CLI: `login`, `usage`, `ls`, `links`, `put`, `share`, `expire`, `rm`, `rm-link` |
| `cargo test` | 9 unit tests, no network: path normalization, CRC32, base64 metadata, chunk size |

Verified live: login (30-day `rememberMe` token), storage usage, folder listing, share
links. Upload and share-creation use the same code path as the macOS app, which is
end-to-end verified, but have not been run from Windows.

## Build and run

```bat
cargo build --release
set DRIVEDROP_HOST=192.168.1.10
set DRIVEDROP_USER=admin
set DRIVEDROP_PASS=secret
set DRIVEDROP_INSECURE=1        &rem the console uses a self-signed certificate

target\release\drivedrop.exe login
target\release\drivedrop.exe ls \Public
target\release\drivedrop.exe put .\invoice.pdf --dir \Public --share --expire 7d
```

## Not implemented

* **Window, Mica backdrop, drag-and-drop target, tray icon.** `Cargo.toml` no longer
  carries `eframe`/`egui`/`rfd`/`arboard`: they were declared for code that was never
  written, and a dependency you do not compile is a supply-chain surface you do not need.
  Add them back with the GUI.
* **Credential Manager.** Credentials come from the environment. Until this is done, keep
  `DRIVEDROP_PASS` out of anything shared or committed.

## The four traps this client encodes

All four are normative constraints in [`spec/api.md`](../../spec/api.md) (C1, C2,
C4, C5); the evidence is in [`spec/discovery.md`](../../spec/discovery.md):

1. `POST /api/auth/login` returns **403** if a `TOKEN` cookie is already attached, so login
   replaces the whole client to get an empty cookie jar.
2. `rememberMe: true` (that exact key) is what buys 30 days instead of 2 hours.
3. The tus `Location:` header is Drive-relative; PATCHing it without the `/proxy/drive`
   prefix 404s.
4. `Upload-Metadata: checksum` must be the file's real CRC32. A wrong value returns `204`
   for every chunk and then discards the upload at finalize, with no error anywhere.

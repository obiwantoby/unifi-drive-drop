# AGENTS.md

Working notes for anyone (human or agent) continuing this project cold. Read `spec/api.md`
before touching the API layer; read this before touching anything else.

## What this is

Drag-and-drop upload for **UniFi Drive** (UNAS Pro) that returns a share URL.

| Path | What | State |
|---|---|---|
| `apps/macos` | Swift + SwiftUI, menu-bar resident, Liquid Glass | shipped, v0.1.3 published |
| `apps/windows` | Rust: API library + `drivedrop` terminal client | library solid, CLI works |
| `apps/windows-ui` | Rust + Slint (Fluent 2 style) + Mica | builds and runs on macOS; **CI build on `windows-latest` currently fails** |
| `spec/api.md` | the normative contract, constraints **C1–C25** | authoritative |
| `spec/discovery.md` | how that was established, and what was ruled out | reference |
| `tools/` | capture proxy, endpoint discovery, PII scrubber | tooling |

## Where the Windows agent starts (state as of the handoff)

**One open failure.** `.github/workflows/windows.yml` fails at the step *Build the Fluent UI*.
Steps before it pass: the `drivedrop` library tests and the terminal client both build on
`windows-latest`. So the break is specific to `apps/windows-ui` — its dependencies, or the
`#[cfg(windows)]` block in its `build.rs`.

Reproduce it natively, which is faster than fighting CI:

```powershell
cd apps\windows-ui
cargo build --release          # same command CI runs
```

Things already ruled out, so don't re-check them:

- `winresource`'s API is as used — `new()`, `set_manifest(&str)`, `compile() -> io::Result<()>`
  (verified against the 0.1.31 source).
- The code compiles and runs on macOS, including the vibrancy call, which reports
  `NoWindowHandle(NotSupported)` there as intended.
- `cargo check --target x86_64-pc-windows-msvc` is **not** a shortcut: `ring` (via rustls) needs a
  real MSVC toolchain and fails under a macOS cross-compile.
- Clippy is clean locally (`cargo clippy --all-targets`), so `-D warnings` in CI is not the cause.

If native build succeeds where CI fails, the difference is the runner environment — check the
`rust-cache` step and the toolchain version before suspecting the code.

**Then, in order:**

1. Get `drivedrop-ui.exe` running and confirm what Mica actually does. **Expect title-bar tint at
   best, and report it honestly rather than claiming an effect that isn't there.** The call is
   wired and type-checked (it is deliberately compiled on macOS, where it returns `Unsupported`),
   but `ui/main.slint` paints an opaque `background: root.surface`, and Slint 1.18 exposes **no
   window-transparency API** — `set_transparent` exists only inside the winit backend's renderer
   internals, nothing in `i-slint-core` or the `slint` facade. So the backdrop is probably hidden
   by our own fill. Decide between (a) accepting the painted Fluent surface, which is what plenty
   of real Fluent apps ship, or (b) a raw winit window with a transparent surface feeding Slint,
   which is substantially more work. Don't do (b) on a guess; do it if the screenshot justifies it.
2. Compare `cargo build --release` against `--features skia` on the real display and keep the
   clearer one. Text clarity here is a renderer choice; ClearType and DirectWrite are not in the
   path because Slint rasterises glyphs itself. DPI is already handled — the exe embeds a
   `PerMonitorV2` manifest and CI asserts the string is present in the built binary rather than
   trusting that `build.rs` ran.
3. Add credential storage on Windows. macOS already persists through the **Keychain**; the Windows
   UI holds the password in memory only, so every launch needs a retype. Use the `keyring` crate
   (Windows Credential Manager, macOS Keychain, Linux Secret Service) under service `DriveDrop`,
   account = host + user. Do not write a plaintext config file — and if `keyring` is adopted on
   both sides, retire the macOS-specific Keychain code rather than keeping two paths.
4. Feature parity gaps, listed below.

## Rules that are not negotiable

- **Never write to a real console without asking.** Read-only `GET`s are fine. This has gone
  wrong twice: a share link created on someone's real file to see what an error said, and ten
  probe entries left in their trash. Both were avoidable.
- **No credentials, console addresses, or operator PII in the repo.** The public repo ships the
  scrubbing mechanism (`tools/redact_capture.py`), never the identity. `tools/pii.json` is
  gitignored for a reason.
- **Mock data uses `demo.invalid`**, never a real address.
- Verify against the live console only when needed, and clean up after yourself: delete created
  links, remove created files, then **purge them from the trash too** (`DELETE
  /trash-resources/trash/{path}`), because trashed entries linger and accumulate.

## Build and verify

macOS (needs full Xcode, not just CLT, for the SwiftUI macros):

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/macos && ./scripts/build-app.sh debug      # -> build/DriveDrop.app
./scripts/test-races.sh                            # 45 assertions
./scripts/make_release.sh                          # -> dist/DriveDrop-<VERSION>.{dmg,zip}
```

Rust (library + CLI + UI):

```
export PATH="$HOME/.cargo/bin:$PATH"
cd apps/windows    && cargo test                   # 11 unit tests
cd apps/windows-ui && cargo build                  # runs on macOS too, for style iteration
DRIVEDROP_LIVE=1 cargo test --test live -- --ignored --nocapture   # live, self-cleaning
```

Windows CI: `.github/workflows/windows.yml` builds both crates on `windows-latest`. **That is
the verification gate for the UI** — Slint compiles cross-platform but Mica, the tray, and
native dialogs can only be confirmed on Windows.

Release version lives in **one place**: `apps/macos/VERSION`. Both build scripts read it. Do not
hardcode a version anywhere else; an earlier setup read it from a previously built bundle, which
would have shipped new code under an old version string.

## The API in one paragraph

The API key cannot authorize Drive file operations — only a UniFi OS **session login** can
(§Auth). CSRF token is fused to the JWT and must be replayed on writes. Uploads use **tus** with
a **CRC32** checksum in `Upload-Metadata`, 512 KiB chunks, and the returned `Location` must be
prefixed `/proxy/drive`. Finalization is **asynchronous**: the last chunk answers 204 and the
object is not queryable yet, so poll. `expiresAt` is **create-only** — `PATCH` returns 200 and
ignores it — so changing an expiry means delete + recreate, which **rotates the token** and kills
every URL already shared. The direct-download route takes the file **name**, not the qualified
path. All of this is C1–C25 in `spec/api.md`, with the evidence.

## Traps that already cost time

Write these down; every one was discovered the hard way.

- `PATCH` returning 200 does **not** mean the field changed. Two shipped bugs came from trusting
  a status code. Read the object back.
- A green test that measures nothing looks identical to a green test. Before trusting an
  assertion, ask what value would make it fail. One test compared a PATCH against a baseline
  that already held the target value; another asserted a store size while the fixture seeded two
  extra rows.
- `swift build --arch arm64 --arch x86_64` is the only way to get a universal binary;
  `-Xswiftc -target` silently leaves arm64 objects in the fat file.
- `URL.resolvingSymlinksInPath()` **crashes** on a dangling symlink. Walk links with `readlink`
  and a hop limit.
- Storage usage is a **top-level** `{"pools":[…]}` body, not wrapped in `data`.
- Repeated logins trip `AUTHENTICATION_FAILED_LIMIT_REACHED`, which looks exactly like a wrong
  password. The CLI caches a session for this reason.
- Server paths are identifiers. Rebuilding one from a display name breaks on Unicode whitespace
  (U+2009/U+202F in macOS screenshot names). Resolve from the listing's own `path` field.
- Slint: struct fields are comma-separated; `fluent` is **not** a crate feature (the style is
  chosen in `build.rs`); `LineEdit` has no `echo-mode` — use `input-type: InputType.password`;
  buttons have no `tooltip`; `ModelRc` is built from `Rc<VecModel<_>>`.
- Slint components are **not `Send`**. Workers post through a channel and the UI thread drains
  it. Never touch the UI from a thread. Consequently shared state must be
  `Arc<Mutex<…>>`, not `Rc<RefCell<…>>`.
- Slint: `raw-window-handle-06` is **off by default**, and without it there is no route to the
  HWND — `slint::Window` does not implement `HasWindowHandle`. Reach it with
  `window().window_handle()`, which returns the handle directly, not a `Result`.
- Slint: `ModelRc` is built from `Rc<VecModel<_>>`; `From<VecModel<_>>` is not implemented, so
  `ModelRc::from(Rc::new(VecModel::from(v)))`.
- Slint: a callback registered as `FnMut` cannot move its captured state into a spawned thread —
  the first click consumes it. Clone the `Arc` inside the closure body, per invocation.
- Slint: `Text` has no `top-margin`. Spacing comes from the enclosing layout.
- **CI log colour lies to grep.** With `CARGO_TERM_COLOR=always` every line starts with an ANSI
  escape, so an anchored `^error` matches nothing. A diagnostic block full of `grep "^error"`
  reported success while the build was failing. Strip escapes before matching.
- A fine-grained PAT may read check-run **annotations** but not job **logs**, so a CI failure can
  be invisible from the dev machine. Workaround in the workflow: echo the error tail through
  `::error::` so it lands in annotations.
- The unified log can filter or drop a subsystem. When debugging "did this code run?", an
  append-to-file channel does not lie. `log show` told me nothing while the code was running
  fine.

## Feature parity checklist (Windows vs macOS)

Implemented on both: sign in, folder browse, upload with progress, auto-share with default
expiry, click-to-copy, expired rows offer "new link" instead of copying a dead URL, delete link,
usage display, session lifetime, demo mode.

macOS only so far: drag-and-drop onto the window, zip-on-drop for directories, right-click
context menu, default-expiration picker in settings, copy-on-upload preference, menu-bar resident
list. Windows has no tray icon yet, which is the biggest gap — the macOS tool is mostly used from
the menu bar.

Password persistence: macOS yes (Keychain), **Windows no** — see step 3.

Windows only so far: nothing. It is the lagging platform; do not let the API layer diverge —
`apps/windows` is the single implementation both the CLI and the UI consume.

## Known unknowns

Tracked at the bottom of `spec/api.md`: shared-drive upload (U2), tus resume (U3), trash restore
and rename (U4c/d), password-protected links (U5), `accessLimit` enforcement (U6). U2 needs a
drive that is safe to write into — ask before testing it.

## Security state of the credentials

The operator pasted a GitHub PAT, the console password, and the Drive API key into chat. Treat all
three as **compromised**: revoke the PAT, rotate the console password, and regenerate the API key.
None of them are in this repo, and none belong in it — not in docs, not in examples, not in
fixtures. The console's LAN address is operator PII too; UI placeholders use
`https://console.local` for that reason (one had crept in as an example and was removed).

## Release hygiene

Releases are ad-hoc signed and **not notarized** (no Apple Developer ID), so Gatekeeper blocks
first launch. Say so in the release notes rather than letting people hit a mystery wall; include
the `xattr -dr com.apple.quarantine` line. Mark superseded releases with a banner pointing at the
new one — both 0.1.0 and 0.1.1 shipped real bugs and people were still downloading them.

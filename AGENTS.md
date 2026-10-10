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

Windows CI: `.github/workflows/windows.yml` builds both crates on `windows-latest`. It is the gate
for anything that has to compile, but the UI is now also run on real Windows, because four of the
bugs below were only visible with the window on screen:

```
rustup default stable-x86_64-pc-windows-msvc    # the GNU toolchain needs a binutils dlltool
./tools/shot-pw.ps1  -Out shot.png              # capture the window (see the GL caveat below)
./tools/click.ps1 -Name Connect                 # press a control by name via UI Automation
./tools/where.ps1                               # rect / DPI / monitor, when a capture looks wrong

SLINT_BACKEND=software ./target/debug/drivedrop-ui.exe   # the capturable renderer
DRIVEDROP_NO_ACRYLIC=1 ./target/debug/drivedrop-ui.exe   # rule the backdrop out in one run
```

`shot-pw.ps1` uses `PrintWindow`, which **does not capture the femtovg/GL surface** — it returns a
blank client area for a window that is rendering perfectly, which is how one debugging session
went looking for a rendering bug that did not exist. Use `SLINT_BACKEND=software` for captures.
A plain `CopyFromScreen` grab is worse on this machine: it returns only the wallpaper, for every
window (`shot_notepad.png` proves it), so it can never be evidence that an app draws nothing.
Judge the acrylic itself only from a real screen capture (Win+Shift+S).

The icon set is generated, not hand-saved:

```
cargo run --manifest-path tools/icon-gen/Cargo.toml -- \
    apps/windows-ui/icons/app-1024.png apps/windows-ui/icons/drivedrop.ico
```

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
- `windows_subsystem` accepts only `"windows"` or `"console"`. `= "main"` is E0539 and it killed
  the release build of the UI on Windows while debug kept building, because `cfg_attr` excluded it
  there — a broken release config is invisible to the person working in debug.
- `window_handle()` only answers once winit has created the window, and `App::new()` does not do
  that. Called early it returns `HandleError::NotSupported`, the error is swallowed, and the window
  keeps its painted surface forever. Hook `RenderingState::RenderingSetup` instead — and note the
  **software renderer reports `Unsupported` for the notifier**, so it needs a timer retry or
  `SLINT_BACKEND=software` silently loses the backdrop.
- Acrylic and Mica need the window to not paint opaque over the backdrop. Slint's winit backend
  only *requests* a transparent surface on macOS (`wants_transparent` is `cfg(target_os = "macos")`)
  — on Windows the backdrop still composites, but nothing about that is guaranteed by the API, so
  the UI paints its translucent palette only after `apply_backdrop` reports success.
- The Fluent controls follow the OS light/dark by themselves and there is **no supported override**
  in 1.18: `Palette` is a read-only global (instantiating it is "Cannot create an instance of a
  global", assigning to it is a parse error). Hand-painted text has to follow the OS too —
  `AppsUseLightTheme` from the registry, polled, or the first Windows run is white-on-white.
- `if cond: SomeLayout {}` inside a layout is a **Rectangle wrapper that takes a share of the
  leftover space**. With both children at stretch 0 that space was split between a caption and a
  4 px bar, so the bar drifted 150 px below its label. Pin the wrapper's height.
- Glyph coverage in the UI font is smaller than the Unicode chart: `↗` (U+2197) renders, `↻`
  (U+21BB) and `⤘` (U+2398) come out blank, which is how a toolbar ends up with an unlabelled
  button. Words, or Segoe MDL2 — and MDL2's private-use codepoints are tofu on macOS.
- Tray: needs the `system-tray` feature on `slint`. Menu items fire **`activated`**, not `clicked`;
  the tray icon's own `clicked` is a different callback and is **not exposed** on a
  SystemTrayIcon-rooted component, nor is `tooltip` — forward both through properties on the
  component. A tray and a window share no globals.
- `visible: false` **still occupies its slot in a layout**. A context menu with one hidden row was
  sized for three and painted the last item outside its own card. Use `if cond: Row {}`.
- `REG_SZ` is **UTF-16LE with a NUL**. Writing `str::as_bytes()` stores UTF-8: the write returns
  success, the checkbox stays ticked, and the loader gets garbage — autostart silently never
  happens. Only reading the value back shows it (`tools/check-autostart.ps1`).
- Slint's `PopupWindow` renders into the main window here, so `PrintWindow` on `MainWindowHandle`
  captures it and `EnumWindows` shows no extra window. A missing popup in a capture is not proof it
  did not open — the menu was written off as broken on exactly that evidence.
- UI Automation cannot drive a Slint `CheckBox`: `InvokePattern.Invoke()` reports success and does
  nothing, and `TogglePattern` is present but `Toggle()` is a no-op with an empty state. Send a real
  press/release at the element's own `BoundingRectangle` (`tools/toggle.ps1`), and give rows
  `accessible-label` so they can be addressed at all (`tools/row-click.ps1`).
- `FocusScope.focus` is not bindable; a Window chooses initial focus with `forward-focus`. Callback
  handlers are written `(event) => { … }` even when the callback returns a value, and the values are
  bare `accept` / `reject`. Slint 1.18 has no `String::to-lower-case`, so a Ctrl+letter shortcut must
  compare both cases or it dies under Caps Lock.
- There is no change handler for a plain property (`on_copy_on_upload_changed` does not exist), so
  persistence needs an explicit `settings-changed()` callback fired by every control in the panel.
- **Even font sizes.** At 150 % scaling an 11 px size is 16.5 physical pixels, and a glyph
  rasterised across a half pixel looks blurry whichever rasteriser you ask. The Slint stack has no
  ClearType and no hinting knob to turn — grepping `i-slint-core` for smoothing/hinting finds
  nothing — so grid alignment is the lever that exists: 10/12/14/18 land on whole pixels at
  100/150/200 %.
- `perl -pi -e 's/…/$foo/'` **interpolates `$foo` as a perl variable** and silently blanks the line.
  It ate two lines of PowerShell here. Use the edit tool, or escape the dollars.
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

Implemented on both: sign in, folder browse (Windows: Enter in the path field, `Up`, and clicking
a directory), upload with progress **to the folder being shown**, auto-share with default expiry,
click-to-copy, expired rows offer "new link" instead of copying a dead URL, delete link, usage
display, session lifetime, demo mode, links scoped to the current folder with the count left
outside it reported, and a resident presence (menu-bar item / system tray) whose tooltip carries
folder, usage and session.

Windows-only: acrylic backdrop (`window-vibrancy`, with Mica as the fallback and a painted surface
after that), close-hides-to-tray, and a generated `.ico` in the exe plus the window/tray icons.
Presence is no longer the gap it was; the API layer still is the thing to watch — `apps/windows`
is the single implementation both the CLI and the UI consume, and a second implementation of the
same contract drifts into a corrupt upload rather than a wrong pixel.

macOS only so far: drag-and-drop onto the window, zip-on-drop for directories, right-click
context menu, default-expiration picker in settings, copy-on-upload preference.

Password persistence: macOS yes (Keychain), **Windows no** — the session password lives in memory
only. Credential Manager is the fix, and the `keyring` crate covers both platforms — see step 3.

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

# DriveDrop — UI / design spec

One behaviour, two native expressions. Nothing here is a webview pretending to be native.

## Core interaction

The whole window is the drop target — not a boxed "drop zone" you have to aim at.

```
┌──────────────────────────────────────────────┐
│  DriveDrop                    192.0.2.10  ⚙ │   header, 44pt
├──────────────────────────────────────────────┤
│                                              │
│         ⬆  Drop files to get a link          │   empty state /
│            or click to browse                │   drop affordance
│                                              │
├──────────────────────────────────────────────┤
│  report.pdf          2.4 MB   ✓  ⧉  ⋯       │   row
│  clip.mov            88 MB    ▓▓▓░ 62%       │   uploading
│  keys.txt            12 KB    ✓  ⧉  ⋯       │   row
├──────────────────────────────────────────────┤
│  3 items · 90 MB used          ⟳  ⌫ expired  │   footer
└──────────────────────────────────────────────┘
```

- **Drop** anywhere → upload starts immediately, row appears with a progress bar.
- **Single click** a row → selects. **Double click** → opens the share URL in the browser.
- **Right-click / two-finger click** → context menu:

| Item | Shortcut | Behaviour |
|---|---|---|
| Copy share URL | ⌘C / Ctrl+C | link to clipboard, toast "Copied" |
| Copy direct download URL | ⇧⌘C / Ctrl+Shift+C | raw file URL, bypasses the share page |
| Open in browser | ⌘↵ / Ctrl+↵ | |
| Copy password | | only if the share has one |
| Set expiration ▸ | | 1 hour · 1 day · 7 days · 30 days · Never · Custom… |
| ────── | | |
| Delete | ⌘⌫ / Del | confirm if the link has been opened |

- Rows with an expiry show a countdown (`expires in 6d 4h`), turning amber < 24h,
  red when expired.
- Failed uploads stay in the list with a retry affordance — never silently vanish.
- Dragging *out* of a row copies the file path (macOS) so you can drop into Mail etc.

## macOS — glass

Target macOS 26+. Use the real glass APIs, fall back to materials on older systems.

- Window: `NSWindow` with `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`,
  `styleMask` including `.fullSizeContentView`, `isMovableByWindowBackground = true`.
  Corner radius comes free from the system.
- Backdrop: `NSVisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow,
  state: .active)` behind everything.
- Surfaces: `.glassEffect(.regular.tint(accent).interactive(), in: .rect(cornerRadius: 16))`
  on macOS 26; `.background(.ultraThinMaterial, in: .rect(cornerRadius: 16))` below.
- Drop feedback: the glass *lifts* — `GlassEffectInteraction` scale + a 1pt accent ring,
  animated with `.spring(duration: 0.3, bounce: 0.25)`.
- Typography: `.system(.body, design: .rounded)` for the drop headline, default SF elsewhere.
- Accent: read the user's accent colour, don't hardcode.
- `ControlGroup` + `.menuStyle(.borderlessButton)` for the context menu so it matches.
- Menu bar extra (`MenuBarExtra`) with the same list, so it lives in the menu bar permanently.

## Windows — Fluent + Mica

- Real Mica, not a blur screenshot: `DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE(33),
  DWM_SYSTEMBACKDROP_TYPE::DWMSBT_MAINWINDOW(2))`. Requires Windows 11 build 22000+;
  fall back to `DWMSBT_TRANSIENTWINDOW` (Acrylic) on 21H2, plain solid on Win10.
- Window must be extended into the title bar: `DwmExtendFrameIntoClientArea` with
  `{0,0,0,0}` + `DWMWA_USE_IMMERSIVE_DARK_MODE(20)` to match the theme.
- Typography: **Segoe UI Variable** — Display 28 for the headline, Body 14 for rows,
  Caption 12 for metadata.
- Metrics: 4px grid. Row height 40. Corner radius 8 on cards, 4 on buttons.
  List padding 16, window padding 12.
- Colour: pull the user's accent colour from the registry
  (`HKCU\Software\Microsoft\Windows\DWM\AccentColor`) and build the light/dark
  surface ramp from it, so it matches the OS theme rather than a hardcoded palette.
- Rounded window corners are default on Win11; add `DWMWA_WINDOW_CORNER_PREFERENCE`
  for explicitness.
- Context menu: `egui` `ContextMenu` styled to Fluent — 32px items, 8px radius,
  subtle 1px border at 12% foreground, accent checkmark on the active expiry.

Both platforms: respect reduce-transparency / increase-contrast and degrade to opaque surfaces.

## State machine (identical in both)

```
queued ──▶ uploading(progress) ──▶ uploaded ──▶ sharing ──▶ ready(url, expiresAt)
   │              │                                  │
   │              ▼                                  ▼
   └────────── failed(retry)                     expired
```

Persistence: local record of `{fileId, name, size, shareUrl, expiresAt, createdAt}` so the
list survives restarts and can re-validate against the console.

## Settings

| Key | Default |
|---|---|
| Console host | `192.0.2.10` |
| Port | `443` |
| Username | — |
| Password | keychain / credential manager |
| Upload destination | `/Public` on the personal drive (created on first upload) |
| Default expiration | 7 days |
| Copy URL automatically after upload | on |
| Accept self-signed certificates | on (warn once) |
| Launch at login | off |

## The current folder is also the drop target

One value, `currentDir`, drives both what you see and what you upload into. Keeping them
separate is how a tool ends up showing `/Public` while quietly dropping files into `/`.

- Stored personal-drive-relative: leading `/`, no trailing `/`, `.` and `..` **resolved**
  with `..` clamped at the root so nothing escapes upward.
- Entries come from `GET /resources/mydrive{dir}/`; share links from `/file-sharing/links`.
  Both use the same absolute form (`/mydrive/Public/x.zip`), so they **join on `path`** with
  no translation.
- Entries and links are kept as separate state and joined at render time. A merged row type
  goes stale whenever whichever fetch loses the race.
- Two scopes: **This folder** (real directory contents, folders navigable) and **All links**
  (every share link on the drive). No breadcrumb stack, no tree — shared drives are not
  browsable because uploads cannot target them.
- The upload captures `currentDir` at drop time, so navigating mid-upload cannot retarget a
  transfer already in flight.

## Never block launch on the credential store

`SecItemCopyMatching` on the main thread during launch **deadlocks**. If securityd wants to
raise the "app wants to use your confidential information" dialog, the dialog cannot appear
because the app has not finished launching, and the read cannot complete because the dialog
has not been answered. Result: a running process with no window and no prompt.

Rules the macOS client follows:

- the read happens in `Task.detached`, never in `AppModel.init` or a view body;
- `ready` gates the UI, and a 1.5 s watchdog changes the status line to
  *"Waiting for macOS Keychain approval…"* so a pending prompt reads as what it is;
- writes (`setPassword`, clear) are off-main for the same reason.

This was triggered in practice by seeding the item with the `security` CLI: its ACL names
that tool, not the app, so every read prompts — and because the app is ad-hoc signed, the
code requirement changes on every rebuild, so it prompts again after each build. Let the app
write its own item; do not seed it from a shell.

//! Fluent front-end for DriveDrop.
//!
//! Threading model, because it is the one thing that will bite whoever extends this: Slint
//! components are **not** `Send`, so a worker thread must never touch the UI. Every blocking
//! console call runs on a spawned thread that posts a `Msg` through a channel, and a timer on
//! the UI thread drains it. That avoids reasoning about whether Slint handles are thread-safe,
//! and it means a slow console can never freeze the window.

// No console window beside the GUI in release builds. Debug keeps it, because that is where the
// mica and DPI diagnostics go.
#![cfg_attr(all(target_os = "windows", not(debug_assertions)), windows_subsystem = "windows")]

slint::include_modules!();

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use slint::{Model, ModelRc, VecModel};
use drivedrop::api::MockClient;
use drivedrop::{DriveClient, LiveClient, ShareItem};

type Client = Arc<dyn DriveClient + Send + Sync>;

/// Drive paths, mirroring `DrivePath` in the macOS app so both clients mean the same thing by
/// `/Public`.
mod dnd;

mod drive {
    /// Collapse a user-typed path. Strips the qualified prefix if one was pasted in, resolves
    /// `.`/`..`, and always returns something starting with `/` — a bare `Public` would otherwise
    /// be sent as a relative listing path and quietly upload to somewhere nobody asked for.
    pub fn canonical(raw: &str) -> String {
        let mut s = raw.trim().to_string();
        for strip in ["/mydrive", "/shared"] {
            if let Some(rest) = s.strip_prefix(strip) {
                s = rest.to_string();
            }
        }
        let mut out: Vec<&str> = Vec::new();
        for part in s.split('/') {
            match part {
                "" | "." => {}
                ".." => {
                    out.pop();
                }
                p => out.push(p),
            }
        }
        if out.is_empty() {
            "/".to_string()
        } else {
            format!("/{}", out.join("/"))
        }
    }

    /// Absolute prefix a link's `file_id` must sit under to belong to this folder.
    pub fn absolute_prefix(raw: &str) -> String {
        let d = canonical(raw);
        if d == "/" {
            "/mydrive".to_string()
        } else {
            format!("/mydrive{d}")
        }
    }

    /// Parent, clamped at the personal-drive root.
    pub fn parent(raw: &str) -> String {
        let d = canonical(raw);
        if d == "/" {
            return "/".to_string();
        }
        canonical(&d[..d.rfind('/').unwrap_or(0)])
    }
}

#[cfg(test)]
mod path_tests {
    use super::drive::*;

    #[test]
    fn canonical_collapses_the_forms_a_user_can_type() {
        assert_eq!(canonical("Public"), "/Public");
        assert_eq!(canonical("/mydrive/Public/"), "/Public");
        assert_eq!(canonical("/Public/../Private"), "/Private");
        assert_eq!(canonical("  /  "), "/");
        assert_eq!(canonical("/a/./b//c"), "/a/b/c");
    }

    #[test]
    fn prefix_is_the_personal_drive_root_at_slash() {
        assert_eq!(absolute_prefix("/"), "/mydrive");
        assert_eq!(absolute_prefix("/Public"), "/mydrive/Public");
        // Not /mydrive/Public2 — the trailing separator in the match is what keeps these apart.
        assert_eq!(absolute_prefix("/Public") + "/", "/mydrive/Public/");
    }

    #[test]
    fn parent_clamps_instead_of_going_relative() {
        assert_eq!(parent("/Public/Documents"), "/Public");
        assert_eq!(parent("/Public"), "/");
        assert_eq!(parent("/"), "/");
    }
}

/// What the console calls are allowed to tell the UI thread.
enum Msg {
    Busy(bool),
    Status(String),
    Toast(String),
    Failed(String),
    Session(String),
    Usage { text: String, fraction: f32 },
    Links(Vec<Link>),
    /// Links that exist but are not in the folder being shown — reported, never hidden.
    Elsewhere(i32),
    Entries(Vec<Entry>),
    UploadProgress(f32),
    Uploaded,
    SignedIn { demo: bool },
    /// A drag from Explorer is over/leaving the window. Drives the "drop to upload" overlay; the
    /// drop target itself cannot reach the UI, only this channel.
    DropHover(bool),
    /// Files released onto the window. Same path the picker uses.
    Dropped(Vec<PathBuf>),
}

/// Shared with worker threads, so everything in here is `Arc<Mutex<…>>` rather than
/// `Rc<RefCell<…>>`. The UI itself is never reachable from a thread — only this.
struct State {
    client: Mutex<Option<Client>>,
    /// id → the item behind it. Re-share needs the drive path, and the UI only carries ids.
    by_id: Mutex<HashMap<String, ShareItem>>,
    /// Files dropped while nobody was signed in. Releasing a file is a promise to upload it, and
    /// bouncing it back at someone who has just let go of the mouse is not an answer they can act
    /// on — so the drop lands, the files wait, and signing in collects them.
    pending: Mutex<Vec<PathBuf>>,
    tx: Sender<Msg>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ui = App::new().expect("failed to create the window");
    ui.set_dark(system_prefers_dark());
    install_backdrop(&ui);

    let tray = Tray::new().expect("failed to create the tray");
    wire_tray(&ui, &tray);

    apply_settings(&ui);
    wire_settings(&ui);

    // Closing the window hides it to the tray, like the macOS menu-bar app, with Quit in the tray
    // menu — unless "Close button hides to tray" is off, in which case close means quit. Slint's
    // default is HideWindow either way, so the setting is what the handler reads at click time
    // rather than something wired once at start-up.
    let close_sink = ui.as_weak();
    // On the *window*, not on the component: `App` has no close handler of its own.
    ui.window().on_close_requested(move || match close_sink.upgrade() {
        Some(ui) if ui.get_close_to_tray() => slint::CloseRequestResponse::HideWindow,
        _ => {
            let _ = slint::quit_event_loop();
            slint::CloseRequestResponse::HideWindow
        }
    });

    // Started from the Run key: arrive in the tray instead of dropping a window on the desktop.
    if std::env::args().any(|a| a == autostart::HIDDEN_ARG) {
        let _ = ui.window().hide();
    }

    // `--demo`: open straight into the sample console. Nobody with a real console needs it — the
    // same state is one blank press of Connect away. It exists because a window that only shows
    // its list after a mouse click at coordinates is a window nothing else can look at: no
    // screenshot script, no reviewer without the app built, no one checking whether a row's
    // delete button is where it should be.
    let demo_at_start = std::env::args().any(|a| a == "--demo");

    let (tx, rx) = channel::<Msg>();
    let st = Arc::new(State { client: Mutex::new(None), by_id: Mutex::new(HashMap::new()), pending: Mutex::new(Vec::new()), tx });

    wire(&ui, &st);

    if demo_at_start {
        // The same callback the Connect button fires, not a parallel demo path — the two would
        // disagree about what "demo" means, which is the bug the sign-out card already had.
        ui.invoke_sign_in("".into(), "".into(), "".into(), ui.get_insecure());
    }

    // Drag-and-drop from Explorer, registered from a one-shot timer rather than inline: the HWND
    // does not exist until the event loop has created the window, and a window that silently never
    // accepts drops is indistinguishable from one with this code removed.
    {
        let dnd_ui = ui.as_weak();
        let dnd_tx = st.tx.clone();
        let dnd_timer = slint::Timer::default();
        dnd_timer.start(
            slint::TimerMode::SingleShot,
            Duration::from_millis(200),
            move || {
                let Some(ui) = dnd_ui.upgrade() else { return };
                // Cloned per call: the timer closure is FnMut, so moving the Sender in would break
                // any later firing.
                enable_drop_target(&ui, dnd_tx.clone());
            },
        );
        BACKUP_TIMERS.with(|v| v.borrow_mut().push(dnd_timer));
    }

    // Drain console results on the UI thread. 40 ms is below the threshold where a progress bar
    // looks steppy and far below anything that costs noticeable power when idle.
    let sink = ui.as_weak();
    let drain = rx;
    // `Dropped` needs the shared state to start an upload, and `apply` deliberately only knows how
    // to paint, so that one variant is handled here and everything else goes to `apply`.
    let st_drops = Arc::clone(&st);
    let clock = std::rc::Rc::new(std::cell::RefCell::<ToastClock>::default());
    let timer = slint::Timer::default();
    timer.start(
        slint::TimerMode::Repeated,
        Duration::from_millis(40),
        move || {
            let Some(ui) = sink.upgrade() else { return };
            while let Ok(m) = drain.try_recv() {
                match m {
                    Msg::Dropped(paths) => start_upload(&ui, &st_drops, paths),
                    other => {
                        // Asked before `apply` moves it. Sign-in is the moment a queued drop can
                        // finally go out, and the moment has to be caught here rather than inside
                        // `apply`, which is only allowed to paint.
                        let signed_in_now = matches!(other, Msg::SignedIn { .. });
                        apply(&ui, other, &clock);
                        if signed_in_now {
                            flush_pending(&ui, &st_drops);
                        }
                    }
                }
            }
            // Two deadlines rather than one: hide starts the 200 ms fade, and the text is only
            // cleared once that fade is over — clearing it immediately drains the card mid-fade
            // and the message visibly blanks out on its way off screen.
            {
                let mut c = clock.borrow_mut();
                let now = Instant::now();
                if c.hide_at.is_some_and(|t| now >= t) {
                    ui.set_toast_visible(false);
                    c.hide_at = None;
                    c.clear_at = Some(now + Duration::from_millis(220));
                }
                if c.clear_at.is_some_and(|t| now >= t) {
                    ui.set_toast("".into());
                    c.clear_at = None;
                }
            }
            // The tray reports the same numbers as the window, so it is refreshed from the place
            // that applies console results. The two cannot disagree if there is one writer.
            sync_tray(&ui, &tray);
        },
    );

    // Follow a live light↔dark flip. The registry key is a cheap read, and 2 s is well below the
    // point where a theme switch feels laggy while still not polling every frame.
    let theme = slint::Timer::default();
    let sink = ui.as_weak();
    theme.start(
        slint::TimerMode::Repeated,
        Duration::from_secs(2),
        move || {
            let Some(ui) = sink.upgrade() else { return };
            let dark = system_prefers_dark();
            if ui.get_dark() != dark {
                ui.set_dark(dark);
                // The acrylic tint is part of the scheme: dark text needs the light tint.
                ui.set_backdrop(apply_backdrop(&ui));
            }
        },
    );

    // `tray` lives inside the timer closure above, so it outlives the run loop and its Drop —
    // which is what unregisters the icon from the notification area — runs on the way out of main.
    Ok(ui.run()?)
}

/// Wire the tray to the window.
///
/// A `SystemTrayIcon` is a separate top level: Slint gives it no shared state with the `Window`
/// (globals are per top level), so the window is the source of truth and the tray is driven from
/// here. That is also why its menu items bind to `signed-in`/`can-copy` rather than reaching into
/// the window's own properties.
fn wire_tray(ui: &App, tray: &Tray) {
    fn show(w: &slint::Weak<App>) {
        if let Some(ui) = w.upgrade() {
            ui.window().set_minimized(false);
            ui.window().show().ok();
        }
    }

    // Left-click the icon brings the window back; right-click is the menu. Windows splits these,
    // so unlike macOS there is no need to hide the menu to make the click useful. The tray's own
    // `clicked` is forwarded to `open-window` inside main.slint, because a SystemTrayIcon-rooted
    // component gets no `on_clicked` in the generated API.
    let w = ui.as_weak();
    tray.on_open_window(move || show(&w));

    let w = ui.as_weak();
    tray.on_upload(move || {
        if let Some(ui) = w.upgrade() {
            ui.invoke_choose_files();
        }
    });

    let w = ui.as_weak();
    tray.on_refresh(move || {
        if let Some(ui) = w.upgrade() {
            ui.invoke_refresh();
        }
    });

    let w = ui.as_weak();
    tray.on_sign_out(move || {
        if let Some(ui) = w.upgrade() {
            ui.invoke_sign_out();
        }
    });

    // The top row, decided live-vs-expired exactly as the row itself does — copying a dead URL and
    // reporting success is the failure this app has already shipped once.
    let w = ui.as_weak();
    tray.on_copy_newest(move || {
        let Some(ui) = w.upgrade() else { return };
        let Some(row) = ui.get_links().row_data(0) else {
            ui.set_toast("No share links to copy".into());
            return;
        };
        if row.live {
            ui.invoke_copy_link(row.id);
        } else {
            ui.invoke_re_share(row.id);
        }
    });

    tray.on_quit(|| {
        slint::quit_event_loop().ok();
    });

    sync_tray(ui, tray);
}

/// Windows clamps a tooltip at 127 characters and truncates without warning, so a long folder
/// name can silently eat the usage line.
const TOOLTIP_MAX: usize = 127;

/// Push window state into the tray: folder, usage, session, DEMO — the macOS popover's header,
/// in the one place a Windows tray can show it.
fn sync_tray(ui: &App, tray: &Tray) {
    let signed_in = ui.get_signed_in();
    tray.set_signed_in(signed_in);
    tray.set_can_copy(signed_in && ui.get_links().row_count() > 0);

    let mut tip = String::from("DriveDrop");
    if !signed_in {
        tip.push_str(" — not connected");
    } else {
        tip.push_str(" — ");
        tip.push_str(&ui.get_folder());
        if ui.get_demo() {
            tip.push_str(" (demo)");
        }
        for line in [ui.get_usage_text(), ui.get_session()] {
            if !line.is_empty() {
                tip.push('\n');
                tip.push_str(&line);
            }
        }
    }
    if tray.get_tip() != tip {
        // Cut on a char boundary: slicing UTF-8 at an arbitrary byte panics, and a non-ASCII
        // folder name is entirely ordinary here.
        let cut = tip
            .char_indices()
            .take_while(|&(i, _)| i < TOOLTIP_MAX)
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(tip.len());
        tray.set_tip(tip[..cut].to_string().into());
    }
}

/// The OS theme, read from the same registry key the Fluent widgets read.
///
/// There is no Slint API that tells the host which way the style went, and getting this wrong is
/// not a subtle bug — it is white text on a light backdrop, which is what the first Windows run
/// shipped with. On failure (no key, pre-1607 Windows) this returns light: the failure that must
/// not happen is dark text over a dark wallpaper.
fn system_prefers_dark() -> bool {
    #[cfg(windows)]
    {
        windows_theme().map(|light_theme| !light_theme).unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        // Dev host is macOS and the widgets there use cupertino; dark is what this UI was drawn in.
        true
    }
}

/// `AppsUseLightTheme`: 1 = light, 0 = dark.
#[cfg(windows)]
fn windows_theme() -> Option<bool> {
    use std::mem::size_of;
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::{
        RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }
    let key = wide("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    let name = wide("AppsUseLightTheme");

    let mut value: u32 = 1;
    let mut len: u32 = size_of::<u32>() as u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut u32 as *mut _),
            Some(&mut len),
        )
    };
    if r.is_ok() {
        Some(value != 0)
    } else {
        None
    }
}

/// The DWM backdrop, installed once the HWND exists.
///
/// Timing is the whole problem: `window_handle()` only answers once winit has actually created
/// the window, and `App::new()` does not do that. Called from `App::new()` the call returns
/// `HandleError::NotSupported`, the error is swallowed, and the window quietly keeps its painted
/// surface forever — which is exactly what this did on the first run on real Windows. The
/// rendering notifier's `RenderingSetup` state is the first point at which the window exists and
/// we are still on the UI thread.
fn install_backdrop(ui: &App) {
    let weak = ui.as_weak();
    let retry = weak.clone();
    let tried = std::rc::Rc::new(std::cell::Cell::new(false));
    if let Err(e) = ui.window().set_rendering_notifier(move |state, _api| {
        if !matches!(state, slint::RenderingState::RenderingSetup) || tried.get() {
            return;
        }
        tried.set(true);
        let Some(ui) = weak.upgrade() else { return };
        ui.set_backdrop(apply_backdrop(&ui));
    }) {
        // The software renderer reports Unsupported here. It has no GL context to hand back, but
        // the window still exists once the loop is running, so a one-shot timer is a good enough
        // second chance — without it, `SLINT_BACKEND=software` silently loses the backdrop.
        eprintln!("no rendering notifier ({e:?}); retrying from a timer");
        let t = slint::Timer::default();
        t.start(
            slint::TimerMode::SingleShot,
            Duration::from_millis(150),
            move || {
                let Some(ui) = retry.upgrade() else { return };
                ui.set_backdrop(apply_backdrop(&ui));
            },
        );
        // The timer must outlive this function or the pending callback dies with it.
        BACKUP_TIMERS.with(|v| v.borrow_mut().push(t));
    }
}

/// Register the OLE drop target so a drag out of Explorer lands here. See `dnd`.
///
/// The returned COM interface is parked in a thread-local: OLE keeps a raw pointer to the
/// implementation, so letting it drop would leave the window calling into freed memory on the next
/// drag over it.
fn enable_drop_target(ui: &App, tx: Sender<Msg>) {
    #[cfg(windows)]
    {
        // Two `window_handle()` calls, not a mistake: Slint's returns its own handle type, and
        // `HasWindowHandle` on that is what yields the raw one. The HWND is a `NonNull<c_void>`
        // reaching us as an integer, and `HWND` wants the pointer back.
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        let raw = match ui.window().window_handle().window_handle() {
            Ok(h) => h.as_raw(),
            Err(e) => {
                eprintln!("drop target: no window handle yet ({e:?})");
                return;
            }
        };
        let hwnd = match raw {
            RawWindowHandle::Win32(w) => {
                windows::Win32::Foundation::HWND(w.hwnd.get() as *mut core::ffi::c_void)
            }
            _ => {
                eprintln!("drop target: not a Win32 window, ignoring");
                return;
            }
        };
        match dnd::register(hwnd, tx) {
            Ok(target) => {
                DROP_TARGETS.with(|v| v.borrow_mut().push((hwnd, target)));
                println!("drag-and-drop enabled");
            }
            Err(e) => eprintln!("drag-and-drop unavailable ({e:?})"),
        }
    }
    #[cfg(not(windows))]
    {
        // No OLE here. The overlay property stays false and the picker stays the only route.
        let _ = (ui, tx);
    }
}

#[cfg(windows)]
thread_local! {
    static DROP_TARGETS:
        std::cell::RefCell<Vec<(windows::Win32::Foundation::HWND,
                                windows::Win32::System::Ole::IDropTarget)>> = Default::default();
}

/// The one route from "here are files" to "they are on the Drive and shared".
///
/// The picker and an Explorer drag both end up here, so folder, expiry, copy-after-upload and the
/// refresh after the last file cannot drift apart between the two entry points.
fn start_upload(ui: &App, st: &Arc<State>, paths: Vec<PathBuf>) {
    ui.set_drop_hover(false);
    if paths.is_empty() {
        return;
    }
    if !ui.get_signed_in() {
        // Not a refusal. The files are kept, the count is put on screen where the sign-in form is,
        // and signing in uploads them without a second drag.
        let n = paths.len();
        if let Ok(mut q) = st.pending.lock() {
            *q = paths;
        }
        ui.set_waiting(n as i32);
        let _ = st.tx.send(Msg::Toast(waiting_toast(n)));
        return;
    }
    let folder = drive::canonical(&ui.get_folder());
    let copy = ui.get_copy_on_upload();
    let expiry = drivedrop::models::Expiration::MENU
        [usize::try_from(ui.get_expiry_choice().clamp(0, 4)).unwrap_or(2)];
    upload_all(Arc::clone(st), paths, folder, expiry, copy);
}

// Keeps the retry timer alive: a Timer that is dropped cancels its pending callback.
thread_local! {
    static BACKUP_TIMERS: std::cell::RefCell<Vec<slint::Timer>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// "3 files waiting — sign in to upload them", in the app's own voice rather than an error's.
fn waiting_toast(n: usize) -> String {
    format!(
        "{n} {} waiting — sign in to upload {}",
        if n == 1 { "file" } else { "files" },
        if n == 1 { "it" } else { "them" }
    )
}

/// Sign-in worked; anything left behind by a drop that got there first goes out now.
fn flush_pending(ui: &App, st: &Arc<State>) {
    let queued = match st.pending.lock() {
        Ok(mut q) => std::mem::take(&mut *q),
        Err(_) => return,
    };
    if queued.is_empty() {
        return;
    }
    ui.set_waiting(0);
    start_upload(ui, st, queued);
}

/// Acrylic, then Mica, then nothing — and the answer is reported to the UI, which paints its
/// translucent palette only when a real backdrop is live. Guessing would leave an alpha-on-alpha
/// ghost on any machine where the call failed.
///
/// Called unconditionally rather than behind `cfg(windows)`: `window-vibrancy` compiles on every
/// platform and returns `Unsupported` where it cannot work, so keeping the call live here means
/// macOS type-checks the exact expression that runs on Windows.
fn apply_backdrop(ui: &App) -> bool {
    // Escape hatch: `DRIVEDROP_NO_ACRYLIC=1` runs the whole UI on the painted surface. The accent
    // API this uses is undocumented and has a habit of changing shape between Windows releases,
    // so being able to rule it out in one run is worth the environment variable.
    if std::env::var_os("DRIVEDROP_NO_ACRYLIC").is_some() {
        println!("acrylic disabled by DRIVEDROP_NO_ACRYLIC");
        return false;
    }

    // window_handle() is the only route to the HWND, and it needs slint's
    // raw-window-handle-06 feature — which is not enabled by default.
    let handle = ui.window().window_handle();

    // The tint alpha is the amount of blur that survives, not a dimmer - and it is the reason the
    // effect was invisible here. DWM composites the tint *under* the surface Slint paints, so the
    // two multiply: tint 0xB4 (71%) under a surface at 0xC4 (77%) leaves the window 93% opaque and
    // the wallpaper contributes 7%, which is not an effect anyone can see. Both are now held to
    // roughly 40-60%, for a combined ~76% - enough colour and movement to read as frosted glass,
    // enough opacity that the text on the cards stays crisp.
    //
    // Light gets a light tint. A dark tint under a light surface is how you get grey mud over a
    // bright wallpaper and washed-out text over a dark one.
    let dark = ui.get_dark();
    let tint = if dark { (0x1b, 0x1b, 0x1b, 0x80) } else { (0xf3, 0xf3, 0xf3, 0x66) };
    match window_vibrancy::apply_acrylic(handle, Some(tint)) {
        Ok(()) => {
            println!("acrylic applied");
            return true;
        }
        Err(e) => eprintln!("acrylic unavailable ({e:?})"),
    }
    // Re-acquired: WindowHandle is not Copy, and apply_acrylic took it.
    match window_vibrancy::apply_mica(ui.window().window_handle(), Some(true)) {
        Ok(()) => {
            println!("mica applied");
            return true;
        }
        Err(e) => eprintln!("mica unavailable ({e:?}) — using the painted surface"),
    }
    false
}

// MARK: - callbacks

/// User settings.
///
/// Four values, so a line-oriented file rather than a serde dependency: `key=value`, one per line,
/// unknown keys ignored, unreadable file means defaults. That last part matters — a settings file
/// must never be able to stop the app starting, and a half-written one must not silently reset
/// people's choices to defaults either, so `save` writes a temp file and renames.
///
/// Nothing here is secret: no host, no username, no token. Same rule as the repo — a file that
/// syncs through OneDrive must not be a credential store.
mod settings {
    use std::path::PathBuf;

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Settings {
        pub expiry_choice: i32,
        pub copy_on_upload: bool,
        pub close_to_tray: bool,
        pub accept_self_signed: bool,
    }

    impl Default for Settings {
        fn default() -> Self {
            Self { expiry_choice: 2, copy_on_upload: true, close_to_tray: true,
                   accept_self_signed: true }
        }
    }

    pub fn path() -> PathBuf {
        let root = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("."));
        root.join("DriveDrop").join("settings.cfg")
    }

    /// Tolerant by design. A corrupt line is skipped, not fatal, and the rest still applies.
    pub fn parse(text: &str) -> Settings {
        let mut s = Settings::default();
        for line in text.lines() {
            let Some((k, v)) = line.split_once('=') else { continue };
            match k.trim() {
                "expiry-choice" => {
                    if let Ok(n) = v.trim().parse::<i32>() {
                        // Clamp rather than reject: an out-of-range index would panic at use.
                        s.expiry_choice = n.clamp(0, 4);
                    }
                }
                "copy-on-upload" => s.copy_on_upload = v.trim() == "true",
                "close-to-tray" => s.close_to_tray = v.trim() == "true",
                "accept-self-signed" => s.accept_self_signed = v.trim() == "true",
                _ => {}
            }
        }
        s
    }

    pub fn render(s: &Settings) -> String {
        format!("expiry-choice={}\ncopy-on-upload={}\nclose-to-tray={}\naccept-self-signed={}\n",
                s.expiry_choice, s.copy_on_upload, s.close_to_tray, s.accept_self_signed)
    }

    pub fn load() -> Settings {
        parse(&std::fs::read_to_string(path()).unwrap_or_default())
    }

    pub fn save(s: &Settings) -> std::io::Result<()> {
        let p = path();
        if let Some(dir) = p.parent() { std::fs::create_dir_all(dir)?; }
        let tmp = p.with_extension("cfg.tmp");
        std::fs::write(&tmp, render(s))?;
        // rename over the target: either the old file or the new one, never a truncated middle.
        std::fs::rename(&tmp, &p)
    }
}

/// Launch at sign-in.
///
/// Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, the per-user key that needs no
/// elevation and that Task Manager's Startup tab manages. macOS login items are a different
/// mechanism entirely, so this reports "unsupported" there and the checkbox hides itself rather
/// than sitting there promising something nothing implements.
///
/// The command line carries `--hidden`: an app that lives in the tray should arrive in the tray,
/// not drop a window on the desktop every time you log in.
mod autostart {
    pub const HIDDEN_ARG: &str = "--hidden";

    pub fn supported() -> bool {
        cfg!(windows)
    }

    #[cfg(windows)]
    mod imp {
        use windows::core::{HSTRING, PCWSTR};
        use windows::Win32::System::Registry::{
            RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
            HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SAM_FLAGS, REG_SZ,
        };

        const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        const VALUE_NAME: &str = "DriveDrop";

        // These entry points return WIN32_ERROR rather than Result, so `.ok()` is what turns a
        // zero into Ok(()).
        fn key(sam: REG_SAM_FLAGS) -> Result<HKEY, String> {
            unsafe {
                let sub = HSTRING::from(RUN_KEY);
                let mut h = HKEY::default();
                RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(sub.as_ptr()), 0, sam, &mut h)
                    .ok()
                    .map_err(|e| format!("open Run key: {e}"))?;
                Ok(h)
            }
        }

        /// Closing is best-effort: the handle is ours, we are finished with it, and a failure here
        /// must not swallow the result of the call that actually mattered.
        fn close(h: HKEY) { let _ = unsafe { RegCloseKey(h) }; }

        /// What we would write. Quoted, because the install path can contain a space and the Run key
        /// is parsed like a command line rather than an argument list. (Written without an example
        /// path: `tools/check-pii.sh` fails the build on a personal-path shape, and a placeholder
        /// that looks like one is indistinguishable from the real thing to a regex.)
        fn command() -> String {
            let exe = std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            format!("\"{exe}\" {}", super::HIDDEN_ARG)
        }

        pub fn is_enabled() -> bool {
            let Ok(h) = key(KEY_QUERY_VALUE) else { return false };
            let name = HSTRING::from(VALUE_NAME);
            let mut len: u32 = 0;
            let mut kind = REG_SZ;
            unsafe {
                let r = RegQueryValueExW(h, PCWSTR(name.as_ptr()), None, Some(&mut kind), None, Some(&mut len));
                close(h);
                r.is_ok()
            }
        }

        pub fn set(enabled: bool) -> Result<(), String> {
            let name = HSTRING::from(VALUE_NAME);
            if enabled {
                let h = key(KEY_SET_VALUE)?;
                // REG_SZ is UTF-16LE with a terminating NUL. `str::as_bytes()` stores UTF-8 and
                // Windows reads it back as code units: the value looks plausible in an editor and
                // is garbage to the loader, so autostart silently never happens. Only reading the
                // value back shows this — hence tools/check-autostart.ps1.
                let data = command();
                let utf16: Vec<u16> = data.encode_utf16().chain(std::iter::once(0)).collect();
                let bytes: &[u8] = unsafe {
                    std::slice::from_raw_parts(utf16.as_ptr() as *const u8, utf16.len() * 2)
                };
                let r = unsafe {
                    // The slice carries the length; there is no separate cbdata argument.
                    let r = RegSetValueExW(h, PCWSTR(name.as_ptr()), 0, REG_SZ, Some(bytes));
                    close(h);
                    r
                };
                r.ok().map_err(|e| format!("write Run key: {e}"))?;
                Ok(())
            } else {
                let h = key(KEY_SET_VALUE)?;
                let r = unsafe {
                    let r = RegDeleteValueW(h, PCWSTR(name.as_ptr()));
                    close(h);
                    r
                };
                // Already absent is the state that was asked for, not an error.
                const ERROR_FILE_NOT_FOUND: u32 = 2;
                if r.0 == ERROR_FILE_NOT_FOUND { return Ok(()); }
                // WIN32_ERROR has no Display; `.ok()` converts it to the error type that does.
                r.ok().map_err(|e| format!("delete Run key: {e}"))?;
                Ok(())
            }
        }
    }

    #[cfg(windows)]
    pub fn is_enabled() -> bool { imp::is_enabled() }
    #[cfg(windows)]
    pub fn set(enabled: bool) -> Result<(), String> { imp::set(enabled) }

    #[cfg(not(windows))]
    pub fn is_enabled() -> bool { false }
    #[cfg(not(windows))]
    pub fn set(_enabled: bool) -> Result<(), String> {
        Err("login items are not implemented on this platform".into())
    }
}

/// Set while the settings are being pushed *into* the UI at start-up, so the change handlers do
/// not write the file back (and, for demo-on, do not sign in on the first frame).
static APPLYING_SETTINGS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn current_settings(ui: &App) -> settings::Settings {
    settings::Settings {
        expiry_choice: ui.get_expiry_choice().clamp(0, 4),
        copy_on_upload: ui.get_copy_on_upload(),
        close_to_tray: ui.get_close_to_tray(),
        accept_self_signed: ui.get_insecure(),
    }
}

fn open_in_browser(url: &str) -> Result<(), String> {
    // `explorer <url>` rather than `cmd /C start`: no shell quoting to get wrong, and no window
    // flashing. Only spawn — waiting on explorer is documented to hang or return odd statuses.
    #[cfg(windows)]
    let mut cmd = { let mut c = std::process::Command::new("explorer"); c.arg(url); c };
    #[cfg(target_os = "macos")]
    let mut cmd = { let mut c = std::process::Command::new("open"); c.arg(url); c };
    #[cfg(not(any(windows, target_os = "macos")))]
    let mut cmd = { let mut c = std::process::Command::new("xdg-open"); c.arg(url); c };
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Push the stored values into the UI without triggering the save handlers.
fn apply_settings(ui: &App) {
    use std::sync::atomic::Ordering::Relaxed;
    let cfg = settings::load();
    APPLYING_SETTINGS.store(true, Relaxed);
    ui.set_expiry_choice(cfg.expiry_choice);
    ui.set_copy_on_upload(cfg.copy_on_upload);
    ui.set_close_to_tray(cfg.close_to_tray);
    ui.set_insecure(cfg.accept_self_signed);
    // Show %APPDATA%\DriveDrop\settings.cfg rather than the expanded path. It is shorter, it is
    // what you would type, and it keeps the operator's Windows username out of every screenshot
    // of this panel — the same reason the repo forbids personal paths.
    let full = settings::path().display().to_string();
    let shown = match std::env::var("APPDATA") {
        Ok(a) if full.starts_with(&a) => format!("%APPDATA%{}", &full[a.len()..]),
        _ => full,
    };
    ui.set_settings_path(shown.into());
    // Read from the registry, not from the file: the Run key is the truth about autostart, and it
    // can be changed outside this app (Task Manager's Startup tab) at any time.
    ui.set_can_autostart(autostart::supported());
    ui.set_autostart(autostart::is_enabled());
    APPLYING_SETTINGS.store(false, Relaxed);
}

/// Every settings control writes through here. One place, so "why did my choice not stick?" has
/// one answer.
fn wire_settings(ui: &App) {
    let persist = |ui: &App| {
        if APPLYING_SETTINGS.load(std::sync::atomic::Ordering::Relaxed) { return; }
        let _ = settings::save(&current_settings(ui));
    };

    let w = ui.as_weak();
    ui.on_settings_changed(move || {
        if let Some(ui) = w.upgrade() { persist(&ui); }
    });

    // Demo is not persisted (it is a viewing mode, not a preference), but the box has to drive the
    // same code paths the sign-in card does, or the two disagree about what "demo" means.
    let w = ui.as_weak();
    ui.on_set_demo_mode(move |on| {
        let Some(ui) = w.upgrade() else { return };
        if on && !ui.get_demo() {
            ui.invoke_sign_in("".into(), "".into(), "".into(), ui.get_insecure());
        } else if !on && ui.get_signed_in() {
            ui.invoke_sign_out();
        }
    });

    // Autostart is not in settings.cfg on purpose: the Run key *is* the store, and a second copy
    // here would be a second truth that Task Manager's Startup tab does not know about.
    let w = ui.as_weak();
    ui.on_set_autostart(move |on| {
        let Some(ui) = w.upgrade() else { return };
        match autostart::set(on) {
            Ok(()) => {
                ui.set_toast(if on {
                    "Will start with Windows, in the tray".into()
                } else {
                    "Won't start with Windows".into()
                });
                ui.set_toast_visible(true);
            }
            // Put the box back: a checkbox that stays ticked after the registry write failed is a
            // lie about the state of the machine.
            Err(e) => {
                ui.set_autostart(!on);
                ui.set_status(format!("could not change autostart: {e}").into());
            }
        }
    });
}

fn wire(ui: &App, st: &Arc<State>) {
    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_sign_in(move |host, user, pass, insecure| {
        let s = Arc::clone(&s);
        // Read the folder on the UI thread before the worker starts; the worker has no UI access.
        let folder = w.upgrade().map(|ui| drive::canonical(&ui.get_folder())).unwrap_or_else(|| "/".into());
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || {
            if host.trim().is_empty() {
                // No address means demo data: the UI is reviewable without a console, and the
                // mock's links are marked so nothing here can be mistaken for a real share.
                let c: Client = Arc::new(MockClient::new());
                let _ = s.tx.send(Msg::SignedIn { demo: true });
                load(&s, c, folder);
                return;
            }
            let live = Arc::new(LiveClient::new(host.as_str(), user.as_str(),
                                                pass.as_str(), insecure));
            match live.login() {
                Ok(()) => {
                    report_session(&s, &live);
                    let c: Client = live;
                    let _ = s.tx.send(Msg::SignedIn { demo: false });
                    load(&s, c, folder);
                }
                Err(e) => {
                    let _ = s.tx.send(Msg::Failed(format!("{e}")));
                    let _ = s.tx.send(Msg::Busy(false));
                }
            }
        });
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_refresh(move || {
        let (Some(ui), Some(c)) = (w.upgrade(), s.client.lock().unwrap().clone()) else { return };
        let folder = drive::canonical(&ui.get_folder());
        let s2 = Arc::clone(&s);
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || load(&s2, c, folder));
    });

    // One helper for every way the folder can change (up, double-click a directory, type a path):
    // write it back to the field so the header, the field and the listing cannot drift apart.
    let enter = |ui: &App, s: &Arc<State>, raw: slint::SharedString| {
        let dir = drive::canonical(&raw);
        ui.set_folder(dir.clone().into());
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let s2 = Arc::clone(s);
        std::thread::spawn(move || load(&s2, c, dir));
    };

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_go_up(move || {
        let Some(ui) = w.upgrade() else { return };
        let up = drive::parent(&ui.get_folder());
        enter(&ui, &s, up.into());
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_browse_folder(move |path| {
        let Some(ui) = w.upgrade() else { return };
        enter(&ui, &s, path);
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_open_entry(move |path| {
        let Some(ui) = w.upgrade() else { return };
        // Entries carry their qualified path (`/mydrive/Public/…`); canonical turns that back
        // into the folder form the rest of the app uses.
        enter(&ui, &s, path);
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_choose_files(move || {
        let Some(ui) = w.upgrade() else { return };
        // Native dialog, on the UI thread — rfd drives the platform picker itself. Multi-select:
        // the whole batch then goes through one worker, because one worker per file used to mean N
        // concurrent tus sessions against one console and N refreshes racing for the same list.
        let folder = drive::canonical(&ui.get_folder());
        let Some(paths) = rfd::FileDialog::new()
            .set_title(format!("Upload to {folder}"))
            .pick_files()
        else { return };
        // The same entry point an Explorer drag uses, so the two cannot disagree about folder,
        // expiry, copy-after-upload or when the listing gets refreshed.
        start_upload(&ui, &s, paths);
    });

    let s = Arc::clone(st);
    ui.on_copy_link(move |id| {
        let item = s.by_id.lock().unwrap().get(id.as_str()).cloned();
        match item.and_then(|i| i.share_url) {
            Some(u) => match copy_to_clipboard(u.as_str()) {
                Ok(()) => { let _ = s.tx.send(Msg::Toast("Link copied".into())); }
                Err(e) => { let _ = s.tx.send(Msg::Failed(format!("clipboard: {e}"))); }
            },
            // A link with no URL must not put an empty string on the clipboard with a success
            // message — that is the failure mode the macOS app shipped with.
            None => { let _ = s.tx.send(Msg::Status("That row has no share URL".into())); }
        }
    });

    let s = Arc::clone(st);
    let w2 = ui.as_weak();
    ui.on_open_link(move |id| {
        let item = s.by_id.lock().unwrap().get(id.as_str()).cloned();
        match item.and_then(|i| i.share_url) {
            Some(u) => {
                let _ = match open_in_browser(u.as_str()) {
                    Ok(()) => s.tx.send(Msg::Toast("Opened in the browser".into())),
                    Err(e) => s.tx.send(Msg::Failed(format!("could not open the browser: {e}"))),
                };
            }
            None => { let _ = s.tx.send(Msg::Status("That row has no share URL".into())); }
        }
    });

    let s = Arc::clone(st);
    ui.on_re_share(move |id| {
        // Cloned per invocation: the outer callback is FnMut, so moving `s` into the thread
        // would consume it on the first click and break every later one.
        let s = Arc::clone(&s);
        // Read the chosen expiry on the UI thread: the worker below has no UI access.
        let choice = w2.upgrade().map(|u| u.get_expiry_choice()).unwrap_or(2);
        let expiry = drivedrop::models::Expiration::MENU
            [usize::try_from(choice.clamp(0, 4)).unwrap_or(2)];
        let (Some(c), Some(item)) = (s.client.lock().unwrap().clone(),
                                     s.by_id.lock().unwrap().get(id.as_str()).cloned())
        else { return };
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || {
            // Expiry is create-only (spec C23), so changing it replaces the link and rotates the
            // token. Offered only for expired or unshared rows, where the old URL is already
            // dead or does not exist.
            let _ = c.delete_link(&item.id);
            match c.create_share(&item.file_id, expiry, None) {
                Ok(n) => {
                    let _ = s.tx.send(Msg::Toast("New link created — the old URL no longer works".into()));
                    let _ = s.tx.send(Msg::Status(String::new()));
                    let _ = s.tx.send(Msg::Busy(false));
                    let mut m = s.by_id.lock().unwrap();
                    m.insert(n.id.clone(), n);
                }
                Err(e) => {
                    let _ = s.tx.send(Msg::Failed(format!("{e}")));
                    let _ = s.tx.send(Msg::Busy(false));
                }
            }
        });
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_delete_link(move |id| {
        let s = Arc::clone(&s);
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let id = id.to_string();
        // Read the folder before leaving the UI thread, so the refresh afterwards lands on the
        // directory the user is looking at rather than whatever it became in the meantime.
        let folder = w.upgrade().map(|u| drive::canonical(&u.get_folder()))
            .unwrap_or_else(|| "/".into());
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || {
            match c.delete_link(&id) {
                Ok(()) => {
                    s.by_id.lock().unwrap().remove(&id);
                    let _ = s.tx.send(Msg::Toast("Link deleted".into()));
                }
                Err(e) => { let _ = s.tx.send(Msg::Failed(format!("{e}"))); }
            }
            let _ = s.tx.send(Msg::Busy(false));
            // Without this the deleted row stays on screen until the next Refresh, which is the
            // same class of bug as an upload that never lists its file: the mutation happened, the
            // picture says otherwise.
            load(&s, c, folder);
        });
    });

    // Copy an arbitrary string. Used by "copy direct link", which is a different URL from the
    // share page and the reason the row carries it.
    let s = Arc::clone(st);
    ui.on_copy_text(move |text| {
        let text = text.to_string();
        let _ = s.tx.send(Msg::Toast(match copy_to_clipboard(&text) {
            Ok(()) => "Copied".into(),
            Err(e) => format!("The copy failed: {e}"),
        }));
    });

    // Expiry is create-only, so this deletes and recreates: the URL changes, which is worth saying
    // out loud rather than leaving the user to discover by sharing the old one.
    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_set_expiry(move |id, choice| {
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let id = id.to_string();
        let Some(ui) = w.upgrade() else { return };
        let folder = drive::canonical(&ui.get_folder());
        let idx = usize::try_from(choice.clamp(0, 4)).unwrap_or(2);
        let exp = drivedrop::models::Expiration::MENU[idx];
        let label = ["1 hour", "24 hours", "7 days", "30 days", "Never"][idx];
        s.tx.send(Msg::Busy(true)).ok();
        let s = Arc::clone(&s);
        std::thread::spawn(move || {
            match c.set_expiration(&id, exp) {
                Ok(n) => {
                    // The old id no longer resolves. Keeping it in the map would let a row that is
                    // still on screen copy a dead URL.
                    {
                        let mut m = s.by_id.lock().unwrap();
                        m.remove(&id);
                        m.insert(n.id.clone(), n);
                    }
                    let _ = s.tx.send(Msg::Toast(format!(
                        "Expires {label} - new link, the old URL is dead")));
                }
                Err(e) => { let _ = s.tx.send(Msg::Failed(format!("{e}"))); }
            }
            let _ = s.tx.send(Msg::Busy(false));
            load(&s, c, folder);
        });
    });

    // Share a file that has no link yet - the right-click item, and what a left click on an
    // unshared file does. The copy is deliberate: asking for a link means wanting to paste it.
    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_create_link(move |path| {
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let path = path.to_string();
        let name = path.rsplit('/').next().unwrap_or("").to_string();
        let Some(ui) = w.upgrade() else { return };
        let folder = drive::canonical(&ui.get_folder());
        let expiry = drivedrop::models::Expiration::MENU
            [usize::try_from(ui.get_expiry_choice().clamp(0, 4)).unwrap_or(2)];
        s.tx.send(Msg::Busy(true)).ok();
        // The handler is FnMut, so the Arc has to be cloned for the thread rather than moved.
        let s = Arc::clone(&s);
        std::thread::spawn(move || {
            match c.create_share(&path, expiry, None) {
                Ok(link) => {
                    let copied = link.share_url.as_deref().map(copy_to_clipboard).transpose();
                    s.by_id.lock().unwrap().insert(link.id.clone(), link.clone());
                    // `transpose` gives Result<Option<()>, _>: the outer error is the clipboard
                    // failing, the inner None is the console handing back a link with no URL.
                    let _ = s.tx.send(Msg::Toast(match copied {
                        Ok(Some(())) => format!("Linked {name} - link copied"),
                        Ok(None) => format!("Linked {name} - but the link has no URL to copy"),
                        Err(e) => format!("Linked {name} - the copy failed: {e}"),
                    }));
                }
                Err(e) => { let _ = s.tx.send(Msg::Failed(format!("{name}: {e}"))); }
            }
            let _ = s.tx.send(Msg::Busy(false));
            load(&s, c, folder);
        });
    });

    // Soft delete. The console moves the object to /trash, and the toast says so rather than
    // saying "deleted", which is a different and unrecoverable thing.
    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_delete_file(move |path| {
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let path = path.to_string();
        let name = path.rsplit('/').next().unwrap_or("").to_string();
        let Some(ui) = w.upgrade() else { return };
        let folder = drive::canonical(&ui.get_folder());
        s.tx.send(Msg::Busy(true)).ok();
        let s = Arc::clone(&s);
        std::thread::spawn(move || {
            match c.delete_file(&path) {
                Ok(()) => { let _ = s.tx.send(Msg::Toast(format!("{name} moved to trash"))); }
                Err(e) => { let _ = s.tx.send(Msg::Failed(format!("{name}: {e}"))); }
            }
            let _ = s.tx.send(Msg::Busy(false));
            load(&s, c, folder);
        });
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_sign_out(move || {
        *s.client.lock().unwrap() = None;
        s.by_id.lock().unwrap().clear();
        // A drop left waiting for a sign-in that has now been cancelled. Uploading it later would
        // send someone else's files to a console they never chose.
        s.pending.lock().unwrap().clear();
        if let Some(ui) = w.upgrade() {
            ui.set_signed_in(false);
            ui.set_waiting(0);
            // Everything the previous session put on screen goes with it. A screenshot of this
            // bug showed "not connected" next to the DEMO badge, a full usage bar and two live
            // rows — which reads as "still connected, label is wrong", the worst possible
            // confusion for a tool that shows where your files are.
            ui.set_links(ModelRc::from(std::rc::Rc::new(VecModel::<Link>::default())));
            ui.set_entries(ModelRc::from(std::rc::Rc::new(VecModel::<Entry>::default())));
            ui.set_elsewhere(0);
            ui.set_usage_text("".into());
            ui.set_usage_fraction(0.0);
            ui.set_session("".into());
            ui.set_demo(false);
            ui.set_status("".into());
            ui.set_toast_visible(false);
            ui.set_toast("".into());
            // The demo checkbox drives sign-in/out, so leaving the session has to clear it —
            // otherwise it sits ticked with nothing ticked behind it, and the next click reads as
            // "already on" and does nothing.
            ui.set_demo_on(false);
        }
    });
}

// MARK: - work

fn load(s: &Arc<State>, c: Client, folder: String) {
    *s.client.lock().unwrap() = Some(Arc::clone(&c));
    let prefix = drive::absolute_prefix(&folder);

    match c.usage() {
        Ok(u) => {
            let frac = if u.total_bytes > 0 {
                u.used_bytes as f32 / u.total_bytes as f32
            } else { 0.0 };
            let _ = s.tx.send(Msg::Usage {
                text: format!("{} free of {}", human(u.free_bytes()), human(u.total_bytes)),
                fraction: frac,
            });
        }
        Err(e) => { let _ = s.tx.send(Msg::Status(format!("{e}"))); }
    }

    // file_id -> (link id, direct URL). Built from the same fetch as the link rows, so a file's row
    // and the link list can never disagree about whether something is shared.
    let mut link_of: HashMap<String, (String, String)> = HashMap::new();

    match c.list_links() {
        Ok(links) => {
            {
                let mut map = s.by_id.lock().unwrap();
                for l in &links {
                    map.insert(l.id.clone(), l.clone());
                    link_of.entry(l.file_id.clone()).or_insert_with(|| (
                        l.id.clone(),
                        l.direct_url.as_ref().map(|u| u.to_string()).unwrap_or_default(),
                    ));
                }
            }
            // Only this folder's links, which is what makes the folder field mean something. The
            // macOS popover used to list every link on the drive, so a link copied from it had no
            // relation to the folder on screen; the count of what was left out is reported rather
            // than silently dropped, so "where is my link?" has an answer.
            let mut here: Vec<&ShareItem> = links
                .iter()
                .filter(|l| l.file_id == prefix || l.file_id.starts_with(&format!("{prefix}/")))
                .collect();
            // Newest first. The id tie-break is not decoration: two rows created in the same second
            // would otherwise swap places on a refresh and move a different row under the cursor.
            here.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| a.id.cmp(&b.id)));

            let rows: Vec<Link> = here.iter().map(|i| row_for(i)).collect();
            let _ = s.tx.send(Msg::Links(rows));
            let _ = s.tx.send(Msg::Elsewhere((links.len() - here.len()) as i32));
        }
        Err(e) => { let _ = s.tx.send(Msg::Status(format!("{e}"))); }
    }

    // A failed refresh leaves the previous listing on screen rather than blanking it.
    if let Ok(entries) = c.browse(&folder) {
        let rows: Vec<Entry> = entries.iter().map(|e| Entry {
            name: e.name.clone().into(),
            path: e.path.clone().into(),
            is_dir: e.is_dir,
            // Which files already have a link decides whether the row offers "create link" or
            // "copy link", and stops the menu from offering a share that would come back 403.
            link_id: link_of.get(&e.path).map(|(id, _)| id.clone()).unwrap_or_default().into(),
            direct: link_of.get(&e.path).map(|(_, d)| d.clone()).unwrap_or_default().into(),
        }).collect();
        let _ = s.tx.send(Msg::Entries(rows));
    }

    let _ = s.tx.send(Msg::Busy(false));
}

/// Upload → share → refresh, in one worker, for the whole batch.
///
/// Each step was missing, and each was a bug the user hit:
///
/// | was | consequence |
/// |-----|-------------|
/// | `upload()` returns `share_url: None` and nothing created a link | the file was on the Drive with no link, and the toast said "Shared" |
/// | no refresh after upload | the new file only appeared after pressing Refresh |
/// | status never cleared | the bottom line sat on "Uploading …" forever |
/// | one worker per file | N concurrent tus sessions hammering one console |
///
/// The share is created with the expiry chosen in Settings, and `create_share` already resolves a
/// "link already exists" 403 into the existing link, so re-uploading a name is not an error.
fn upload_all(s: Arc<State>, paths: Vec<PathBuf>, folder: String, expiry: drivedrop::models::Expiration,
              copy_after: bool) {
    let Some(c) = s.client.lock().unwrap().clone() else { return };
    let tx = s.tx.clone();
    std::thread::spawn(move || {
        let n = paths.len();
        let mut shared: Vec<(String, String)> = Vec::new();   // (name, url)
        let mut problems: Vec<String> = Vec::new();

        for (i, path) in paths.iter().enumerate() {
            let name = path.file_name().map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| "upload.bin".into());
            let label = if n > 1 { format!("{name} ({}/{n})", i + 1) } else { name.clone() };
            let _ = tx.send(Msg::UploadProgress(0.0));
            let _ = tx.send(Msg::Status(format!("Uploading {label}…")));

            let cb = |p: f32| { let _ = tx.send(Msg::UploadProgress(p)); };
            let item = match c.upload(path, &folder, &cb) {
                Ok(it) => it,
                Err(e) => { problems.push(format!("{name}: {e}")); continue; }
            };

            // The upload puts bytes on the Drive; this is the step that makes it a link.
            let _ = tx.send(Msg::Status(format!("Sharing {label}…")));
            match c.create_share(&item.file_id, expiry, None) {
                Ok(link) => {
                    s.by_id.lock().unwrap().insert(link.id.clone(), link.clone());
                    match link.share_url.as_deref() {
                        Some(u) => shared.push((name, u.to_string())),
                        // A link object with no URL is not shareable; saying "Shared" here is the
                        // lie that started this.
                        None => problems.push(format!("{name}: the console returned a link with no URL")),
                    }
                }
                Err(e) => problems.push(format!("{name}: uploaded, but the link failed: {e}")),
            }
        }

        // One line, truthful, and then cleared: the progress bar and "Uploading" must not outlive
        // the upload.
        let _ = tx.send(Msg::Uploaded);
        let _ = tx.send(Msg::Status(String::new()));

        let toast = match (shared.len(), problems.len()) {
            (0, 0) => "Upload finished with no files".to_string(),
            (0, _) => format!("Upload failed — {}", problems.join("; ")),
            (s, 0) if s == n => {
                if copy_after {
                    match shared.last().map(|(_, u)| copy_to_clipboard(u)) {
                        Some(Ok(())) => format!("{s} shared — link copied"),
                        Some(Err(e)) => format!("{s} shared — the copy failed: {e}"),
                        None => format!("{s} shared"),
                    }
                } else {
                    format!("{s} shared")
                }
            }
            (s, p) => format!("{s} shared, {p} not: {}", problems.join("; ")),
        };
        let _ = tx.send(Msg::Toast(toast));

        // The listing is what tells the user it worked. Refreshing it here is the difference
        // between "it went fast" and "it worked".
        load(&s, c, folder);
    });
}


fn report_session(s: &Arc<State>, c: &LiveClient) {
    // LiveClient exposes the bearer token's expiry so "will this die mid-upload?" is answerable
    // at a glance, matching the macOS popover.
    if let Some((_, _, expire_ms)) = c.session() {
        let days = (expire_ms - Utc::now().timestamp_millis()) / 86_400_000;
        let _ = s.tx.send(Msg::Session(format!("session ~{days}d")));
    }
}

/// A row is only clickable-as-copy when it has a live URL and has not expired. Everything else
/// offers "New link", because copying a dead URL and reporting success is worse than refusing.
fn row_for(i: &ShareItem) -> Link {
    let expired = i.expires_at.map(|e| e <= Utc::now()).unwrap_or(false);
    let live = i.share_url.is_some() && !expired;
    let subtitle = match (expired, i.expires_at) {
        (true, _) => "expired — click to make a new link".to_string(),
        (false, Some(e)) => format!("expires {}", e.format("%b %d")),
        (false, None) => "never expires".to_string(),
    };
    // How soon it goes away, as a tone rather than only words: a row that expires in two hours and
    // a row that never expires should not read identically.
    let soon = i.expires_at
        .map(|e| (e - Utc::now()).num_seconds())
        .filter(|s| *s > 0 && *s < 86_400);
    let tone = if expired { 2 } else if soon.is_some() { 1 } else { 0 };

    // Which picker choice produced this link. The console stores an absolute time, so this is
    // recovered from the link's lifetime and matched loosely; -1 means "none of the five, tick
    // nothing" rather than guessing and ticking the wrong one.
    let exp = match (i.expires_at, soon) {
        (None, _) => 4,
        (Some(e), _) => {
            let secs = (e - i.created_at).num_seconds().max(0);
            [3_600i64, 86_400, 604_800, 2_592_000]
                .iter()
                .position(|s| (secs - s).abs() <= (*s as f64 * 0.05) as i64)
                .map(|p| p as i32)
                .unwrap_or(-1)
        }
    };

    Link {
        id: i.id.clone().into(),
        name: i.name.clone().into(),
        subtitle: subtitle.into(),
        live,
        direct: i.direct_url.as_ref().map(|u| u.to_string()).unwrap_or_default().into(),
        tone,
        exp,
    }
}

// MARK: - ui updates (UI thread only)

/// When the toast should fade out, and when its text should be released afterwards.
#[derive(Default)]
struct ToastClock {
    hide_at: Option<Instant>,
    clear_at: Option<Instant>,
}

const TOAST_LIFE: Duration = Duration::from_millis(2200);

fn apply(ui: &App, m: Msg, clock: &std::cell::RefCell<ToastClock>) {
    match m {
        Msg::Busy(b) => ui.set_busy(b),
        // A status change dismisses the toast rather than competing with it.
        Msg::Status(s) => {
            ui.set_toast_visible(false);
            ui.set_toast("".into());
            clock.borrow_mut().hide_at = None;
            clock.borrow_mut().clear_at = None;
            ui.set_status(s.into());
        }
        Msg::Toast(t) => {
            ui.set_toast(t.into());
            ui.set_toast_visible(true);
            let mut c = clock.borrow_mut();
            c.hide_at = Some(Instant::now() + TOAST_LIFE);
            c.clear_at = None;
        }
        Msg::Failed(e) => { ui.set_toast("".into()); ui.set_status(e.into()); ui.set_upload_progress(-1.0); }
        Msg::Session(s) => ui.set_session(s.into()),
        Msg::Usage { text, fraction } => {
            ui.set_usage_text(text.into());
            ui.set_usage_fraction(fraction);
        }
        Msg::Links(v) => ui.set_links(ModelRc::from(std::rc::Rc::new(VecModel::from(v)))),
        Msg::Elsewhere(n) => ui.set_elsewhere(n),
        Msg::Entries(v) => ui.set_entries(ModelRc::from(std::rc::Rc::new(VecModel::from(v)))),
        Msg::UploadProgress(p) => ui.set_upload_progress(p),
        Msg::Uploaded => ui.set_upload_progress(-1.0),
        // The overlay is driven from here rather than from the COM callback, because the callback
        // cannot reach the UI and must not try.
        Msg::DropHover(on) => ui.set_drop_hover(on),
        // Intercepted by the drain loop, which has the shared state this needs; `apply` is only
        // allowed to paint. Unreachable, and exhaustive matching is what keeps it honest if a
        // variant is ever added.
        Msg::Dropped(_) => {}
        Msg::SignedIn { demo } => {
            ui.set_signed_in(true);
            ui.set_demo(demo);
            // Keep the settings checkbox truthful when demo mode is entered from the sign-in card
            // rather than from the checkbox itself.
            ui.set_demo_on(demo);
        }
    }
}

// MARK: - clipboard

fn copy_to_clipboard(text: &str) -> Result<(), String> {
    let mut cb = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    cb.set_text(text.to_string()).map_err(|e| e.to_string())
}

/// Bytes → a human string, matching `Fmt.bytes` in the macOS app so both show "19.55 TB".
fn human(n: i64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let neg = n < 0;
    let mut v = n.abs() as f64;
    let mut u = 0;
    while v >= 1000.0 && u < UNITS.len() - 1 { v /= 1024.0; u += 1; }
    let s = if v < 10.0 { format!("{v:.1}") } else { format!("{v:.0}") };
    format!("{}{} {}", if neg { "-" } else { "" }, s, UNITS[u])
}

/// The upload flow, end to end against the same MockClient the demo uses.
///
/// This is the bug the operator hit on a real console: the file uploaded fast, nothing appeared
/// until Refresh, the bottom line stayed on "Uploading…", and the file had no link to copy or
/// delete. The cause was sequencing in the UI, not the transport, so it is tested here rather than
/// only against a live Drive — and `MockClient::upload` returns `share_url: None` exactly like the
/// live client does, so a fix that forgot the share step would fail this.
/// The wording a dropped file gets when nobody is signed in. Tested on its own because the code
/// path that shows it needs a window, a real drag and a mouse, none of which a test has.
#[test]
fn a_drop_before_sign_in_says_how_many_files_are_waiting() {
    assert_eq!(waiting_toast(1), "1 file waiting — sign in to upload it");
    assert_eq!(waiting_toast(4), "4 files waiting — sign in to upload them");
}

#[cfg(test)]
mod upload_tests {
    use super::*;

    #[test]
    fn upload_shares_refreshes_and_clears_the_status() {
        let (tx, rx) = channel::<Msg>();
        let st = Arc::new(State { client: Mutex::new(None), by_id: Mutex::new(HashMap::new()), pending: Mutex::new(Vec::new()), tx });
        let mock: Client = Arc::new(MockClient::new());
        *st.client.lock().unwrap() = Some(Arc::clone(&mock));

        let f = std::env::temp_dir().join("drivedrop-upload-test.txt");
        std::fs::write(&f, b"hello drivedrop").expect("temp file");

        upload_all(Arc::clone(&st), vec![f.clone()], "/Public".into(),
                   drivedrop::models::Expiration::SevenDays, false);

        let mut links: Vec<Link> = Vec::new();
        let mut status = String::from("unset");
        let mut toast = String::new();
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Msg::Links(v)) => links = v,
                Ok(Msg::Status(s)) => status = s,
                Ok(Msg::Toast(t)) => toast = t,
                Ok(_) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
            if !links.is_empty() && status.is_empty() && !toast.is_empty() { break; }
        }
        let _ = std::fs::remove_file(&f);

        assert!(!links.is_empty(),
                "the uploaded file must appear in the link list with no manual refresh");
        assert!(links.iter().any(|l| l.name.starts_with("drivedrop-upload-test")),
                "the new file's row must be among the links shown, got {:?}",
                links.iter().map(|l| l.name.to_string()).collect::<Vec<_>>());
        assert!(toast.contains("shared"), "the toast must report a real share, got {toast:?}");
        assert_eq!(status, "", "the status line must not stay on \"Uploading…\"");
    }

    #[test]
    fn a_failed_upload_says_so_instead_of_claiming_a_share() {
        let (tx, rx) = channel::<Msg>();
        let st = Arc::new(State { client: Mutex::new(None), by_id: Mutex::new(HashMap::new()), pending: Mutex::new(Vec::new()), tx });
        *st.client.lock().unwrap() = Some(Arc::new(MockClient::new()));

        // A path that cannot exist: the upload step must fail, not report success.
        let missing = PathBuf::from("Z:\\definitely-not-here\\ghost.bin");
        upload_all(Arc::clone(&st), vec![missing], "/Public".into(),
                   drivedrop::models::Expiration::SevenDays, false);

        let mut toast = String::new();
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Msg::Toast(t)) => toast = t,
                Ok(_) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
            if !toast.is_empty() { break; }
        }

        assert!(!toast.is_empty(), "a finished batch must always say something");
        assert!(!toast.contains("shared"),
                "nothing was shared, so the toast must not say it was: {toast:?}");
    }
}

#[cfg(test)]
mod settings_tests {
    use super::settings::{parse, render, Settings};

    #[test]
    fn round_trips() {
        let s = Settings {
            expiry_choice: 4,
            copy_on_upload: false,
            close_to_tray: false,
            accept_self_signed: true,
        };
        assert_eq!(parse(&render(&s)), s, "what we write must be what we read");
    }

    #[test]
    fn missing_file_is_defaults_not_crash() {
        assert_eq!(parse(""), Settings::default());
    }

    #[test]
    fn junk_lines_are_skipped_and_good_ones_still_apply() {
        // A half-written or hand-edited file must not lose the settings that are readable.
        let s = parse("# comment\ngarbage\nexpiry-choice=\ncopy-on-upload=false\nexpiry-choice=1\n");
        assert!(!s.copy_on_upload, "an explicit false must beat the default true");
        assert_eq!(s.expiry_choice, 1);
    }

    #[test]
    fn out_of_range_expiry_clamps_instead_of_panicking_at_use() {
        assert_eq!(parse("expiry-choice=99").expiry_choice, 4);
        assert_eq!(parse("expiry-choice=-7").expiry_choice, 0);
    }
}

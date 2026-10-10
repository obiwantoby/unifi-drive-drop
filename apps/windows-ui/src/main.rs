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
use std::time::Duration;

use chrono::Utc;
use slint::{Model, ModelRc, VecModel};
use drivedrop::api::MockClient;
use drivedrop::{DriveClient, Expiration, LiveClient, ShareItem};

type Client = Arc<dyn DriveClient + Send + Sync>;

/// Drive paths, mirroring `DrivePath` in the macOS app so both clients mean the same thing by
/// `/Public`.
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
}

/// Shared with worker threads, so everything in here is `Arc<Mutex<…>>` rather than
/// `Rc<RefCell<…>>`. The UI itself is never reachable from a thread — only this.
struct State {
    client: Mutex<Option<Client>>,
    /// id → the item behind it. Re-share needs the drive path, and the UI only carries ids.
    by_id: Mutex<HashMap<String, ShareItem>>,
    tx: Sender<Msg>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ui = App::new().expect("failed to create the window");
    ui.set_dark(system_prefers_dark());
    install_backdrop(&ui);

    let tray = Tray::new().expect("failed to create the tray");
    wire_tray(&ui, &tray);

    // Closing the window hides it to the tray, like the macOS menu-bar app, and Quit lives in the
    // tray menu. That is Slint's default close behaviour (HideWindow), so there is no
    // on_close_requested here. The run loop only survives the last window because a visible tray
    // counts as a top level — see the note in tray.rs's place in main.slint.

    let (tx, rx) = channel::<Msg>();
    let st = Arc::new(State { client: Mutex::new(None), by_id: Mutex::new(HashMap::new()), tx });

    wire(&ui, &st);

    // Drain console results on the UI thread. 40 ms is below the threshold where a progress bar
    // looks steppy and far below anything that costs noticeable power when idle.
    let sink = ui.as_weak();
    let drain = rx;
    let timer = slint::Timer::default();
    timer.start(
        slint::TimerMode::Repeated,
        Duration::from_millis(40),
        move || {
            let Some(ui) = sink.upgrade() else { return };
            while let Ok(m) = drain.try_recv() {
                apply(&ui, m);
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

// Keeps the retry timer alive: a Timer that is dropped cancels its pending callback.
thread_local! {
    static BACKUP_TIMERS: std::cell::RefCell<Vec<slint::Timer>> = const { std::cell::RefCell::new(Vec::new()) };
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

    // Tinted dark so white text keeps contrast over a bright wallpaper. The alpha is the amount
    // of blur that survives, not a dimmer: at 0xFF there is no point having asked for acrylic.
    match window_vibrancy::apply_acrylic(handle, Some((0x1b, 0x1b, 0x1b, 0xb4))) {
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
        // Native dialog, on the UI thread — rfd drives the platform picker itself.
        let folder = drive::canonical(&ui.get_folder());
        let Some(paths) = rfd::FileDialog::new()
            .set_title(format!("Upload to {folder}"))
            .pick_files()
        else { return };
        for p in paths {
            upload_one(&s, p, folder.clone());
        }
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
    ui.on_re_share(move |id| {
        // Cloned per invocation: the outer callback is FnMut, so moving `s` into the thread
        // would consume it on the first click and break every later one.
        let s = Arc::clone(&s);
        let (Some(c), Some(item)) = (s.client.lock().unwrap().clone(),
                                     s.by_id.lock().unwrap().get(id.as_str()).cloned())
        else { return };
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || {
            // Expiry is create-only (spec C23), so changing it replaces the link and rotates the
            // token. Offered only for expired or unshared rows, where the old URL is already
            // dead or does not exist.
            let _ = c.delete_link(&item.id);
            match c.create_share(&item.file_id, Expiration::SevenDays, None) {
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
    ui.on_delete_link(move |id| {
        let s = Arc::clone(&s);
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let id = id.to_string();
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
        });
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_sign_out(move || {
        if let Some(ui) = w.upgrade() { ui.set_signed_in(false); }
        *s.client.lock().unwrap() = None;
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

    match c.list_links() {
        Ok(links) => {
            {
                let mut map = s.by_id.lock().unwrap();
                for l in &links { map.insert(l.id.clone(), l.clone()); }
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
        }).collect();
        let _ = s.tx.send(Msg::Entries(rows));
    }

    let _ = s.tx.send(Msg::Busy(false));
}

fn upload_one(s: &Arc<State>, path: PathBuf, folder: String) {
    let Some(c) = s.client.lock().unwrap().clone() else { return };
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tx = s.tx.clone();
    let _ = tx.send(Msg::UploadProgress(0.0));
    let _ = tx.send(Msg::Status(format!("Uploading {name} to {folder}…")));

    std::thread::spawn(move || {
        // The progress callback is invoked from this worker, so it only ever touches the
        // channel — never the UI.
        let cb = |p: f32| { let _ = tx.send(Msg::UploadProgress(p)); };
        match c.upload(&path, &folder, &cb) {
            Ok(item) => {
                let _ = tx.send(Msg::Uploaded);
                let _ = tx.send(Msg::Toast(format!("Shared {}", item.name)));
            }
            Err(e) => {
                let _ = tx.send(Msg::Uploaded);
                let _ = tx.send(Msg::Failed(format!("{name}: {e}")));
            }
        }
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
    Link {
        id: i.id.clone().into(),
        name: i.name.clone().into(),
        subtitle: subtitle.into(),
        live,
    }
}

// MARK: - ui updates (UI thread only)

fn apply(ui: &App, m: Msg) {
    match m {
        Msg::Busy(b) => ui.set_busy(b),
        // A status change clears a stale toast, so the two never fight over one line.
        Msg::Status(s) => { ui.set_toast("".into()); ui.set_status(s.into()); }
        Msg::Toast(t) => ui.set_toast(t.into()),
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
        Msg::SignedIn { demo } => {
            ui.set_signed_in(true);
            ui.set_demo(demo);
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

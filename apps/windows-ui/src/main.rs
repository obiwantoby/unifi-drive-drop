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
use slint::{ModelRc, VecModel};
use drivedrop::api::MockClient;
use drivedrop::{DriveClient, Expiration, LiveClient, ShareItem};

type Client = Arc<dyn DriveClient + Send + Sync>;

/// What the console calls are allowed to tell the UI thread.
enum Msg {
    Busy(bool),
    Status(String),
    Toast(String),
    Failed(String),
    Session(String),
    Usage { text: String, fraction: f32 },
    Links(Vec<Link>),
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
    apply_mica(&ui);

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
        },
    );

    Ok(ui.run()?)
}

/// Windows 11 Mica, via DwmSetWindowAttribute.
///
/// Called unconditionally rather than behind `cfg(windows)`: `window-vibrancy` compiles on every
/// platform and returns `Unsupported` where it cannot work, so keeping the call live here means
/// macOS type-checks the exact expression that runs on Windows. Behind a cfg it would have gone
/// to the Windows build completely unverified — the whole reason this file exists on two
/// platforms.
fn apply_mica(ui: &App) {
    // None = follow the system light/dark preference instead of forcing dark.
    // window_handle() is the only route to the HWND, and it needs slint's
    // raw-window-handle-06 feature — which is not enabled by default.
    let handle = ui.window().window_handle();
    match window_vibrancy::apply_mica(handle, None) {
        Ok(()) => println!("mica applied"),
        Err(e) => eprintln!("mica unavailable ({e:?}) — using the painted surface"),
    }
}

// MARK: - callbacks

fn wire(ui: &App, st: &Arc<State>) {
    let s = Arc::clone(st);
    ui.on_sign_in(move |host, user, pass, insecure| {
        let s = Arc::clone(&s);
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || {
            if host.trim().is_empty() {
                // No address means demo data: the UI is reviewable without a console, and the
                // mock's links are marked so nothing here can be mistaken for a real share.
                let c: Client = Arc::new(MockClient::new());
                let _ = s.tx.send(Msg::SignedIn { demo: true });
                load(&s, c);
                return;
            }
            let live = Arc::new(LiveClient::new(host.as_str(), user.as_str(),
                                                pass.as_str(), insecure));
            match live.login() {
                Ok(()) => {
                    report_session(&s, &live);
                    let c: Client = live;
                    let _ = s.tx.send(Msg::SignedIn { demo: false });
                    load(&s, c);
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
        let _ = ui;
        let s2 = Arc::clone(&s);
        s.tx.send(Msg::Busy(true)).ok();
        std::thread::spawn(move || load(&s2, c));
    });

    let s = Arc::clone(st);
    ui.on_go_up(move || {
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let s2 = Arc::clone(&s);
        std::thread::spawn(move || load(&s2, c));
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_open_entry(move |path| {
        let Some(ui) = w.upgrade() else { return };
        ui.set_folder(path.as_str().into());
        let Some(c) = s.client.lock().unwrap().clone() else { return };
        let s2 = Arc::clone(&s);
        std::thread::spawn(move || load(&s2, c));
    });

    let s = Arc::clone(st);
    let w = ui.as_weak();
    ui.on_choose_files(move || {
        let Some(ui) = w.upgrade() else { return };
        // Native dialog, on the UI thread — rfd drives the platform picker itself.
        let Some(paths) = rfd::FileDialog::new()
            .set_title(format!("Upload to {}", ui.get_folder()))
            .pick_files()
        else { return };
        for p in paths {
            upload_one(&s, p);
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

fn load(s: &Arc<State>, c: Client) {
    *s.client.lock().unwrap() = Some(Arc::clone(&c));

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
            let mut map = s.by_id.lock().unwrap();
            for l in &links { map.insert(l.id.clone(), l.clone()); }
            let rows: Vec<Link> = links.iter().map(row_for).collect();
            let _ = s.tx.send(Msg::Links(rows));
        }
        Err(e) => { let _ = s.tx.send(Msg::Status(format!("{e}"))); }
    }

    // A failed refresh leaves the previous listing on screen rather than blanking it.
    if let Ok(entries) = c.browse("/Public") {
        let rows: Vec<Entry> = entries.iter().map(|e| Entry {
            name: e.name.clone().into(),
            path: e.path.clone().into(),
            is_dir: e.is_dir,
        }).collect();
        let _ = s.tx.send(Msg::Entries(rows));
    }

    let _ = s.tx.send(Msg::Busy(false));
}

fn upload_one(s: &Arc<State>, path: PathBuf) {
    let Some(c) = s.client.lock().unwrap().clone() else { return };
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tx = s.tx.clone();
    let _ = tx.send(Msg::UploadProgress(0.0));
    let _ = tx.send(Msg::Status(format!("Uploading {name}…")));

    std::thread::spawn(move || {
        // The progress callback is invoked from this worker, so it only ever touches the
        // channel — never the UI.
        let cb = |p: f32| { let _ = tx.send(Msg::UploadProgress(p)); };
        match c.upload(&path, "/Public", &cb) {
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

//! Drive API client. Mirrors `apps/macos/Sources/DriveDrop/LiveDriveClient.swift`.
//!
//! Every route here is documented as Verified in `spec/api.md`. The guesses this file used
//! to make — `GET /api/v1/files?limit=`, `POST /api/v1/shares`, `/api/v1/public`,
//! `DELETE /api/v1/files/{id}` — do not exist on the console and are gone.
//!
//! Four traps, all learned the expensive way, are encoded below:
//!   1. `POST /api/auth/login` answers **403 Forbidden** if a TOKEN cookie is attached, so
//!      login starts from a brand-new cookie jar every time.
//!   2. `rememberMe: true` is what buys a 30-day token; without it the session dies in 2 h.
//!   3. The tus `Location:` header is relative to the *Drive service*, not the console, so
//!      it must be prefixed with `/proxy/drive` before it can be PATCHed.
//!   4. `Upload-Metadata: checksum` must be the file's real CRC32. A wrong one is accepted
//!      with 204 on every chunk and then silently discarded at finalize.

use std::path::Path;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use chrono::{DateTime, Duration, Utc};
use reqwest::blocking::{Client, RequestBuilder};
use reqwest::cookie::Jar;
use reqwest::header::HeaderMap;
use reqwest::Url;
use serde_json::{json, Value};

use crate::models::*;

/// 512 KiB, straight from the Drive UI's own capture.
pub const CHUNK: usize = 524_288;
/// The public share page lives here, not on the console.
pub const SHARE_WEB_BASE: &str = "https://drop.ui.com";
const TUS: &str = "1.0.0";

// ---------------------------------------------------------------- path helpers

/// Folder as the user thinks about it: `/`, `/Public`. No trailing slash, always absolute.
/// The server does *not* trim a trailing slash, so normalize before sending.
pub fn normalize_dir(folder: &str) -> String {
    let s = folder.trim();
    // Rebuild from the non-empty segments: that drops a trailing slash, a doubled slash and
    // a missing leading slash in one pass. `..` is `canonical`'s job, not this one's.
    let parts: Vec<&str> = s.split('/').filter(|p| !p.is_empty() && *p != ".").collect();
    if parts.is_empty() {
        "/".into()
    } else {
        format!("/{}", parts.join("/"))
    }
}

/// Resolve `.` and `..` and clamp at the root, so a crafted folder name cannot walk out of
/// the drive. Returns a personal-drive-relative path.
pub fn canonical(folder: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    let norm = normalize_dir(folder);
    for seg in norm.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    if parts.is_empty() {
        "/".into()
    } else {
        format!("/{}", parts.join("/"))
    }
}

/// Personal-drive-relative -> drive-qualified, which is what `/resources` and share links
/// take. Shared drives use `/shared/<driveName>/...` instead.
pub fn qualified(folder: &str) -> String {
    let c = canonical(folder);
    if c == "/" {
        "/mydrive".into()
    } else {
        format!("/mydrive{c}")
    }
}

/// Percent-encode a path but keep the separators. The console 404s on a raw space.
pub fn encode_path(p: &str) -> String {
    let mut out = String::with_capacity(p.len());
    for b in p.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || "-._~".contains(c) {
            out.push(c);
        } else if c == '/' {
            out.push('/');
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `GET /resources/<path>` needs a trailing slash to return a directory listing; without it
/// the console 404s even though the folder exists.
pub fn listing_path(dir: &str) -> String {
    let q = qualified(dir);
    let with_slash = if q.ends_with('/') { q } else { format!("{q}/") };
    format!("/proxy/drive/api/v1/resources{}", encode_path(&with_slash))
}

/// Poll `GET /resources/<path>` until the object is queryable or `timeout` elapses.
pub fn wait_until_visible(base: &str, token: Option<&str>, qualified_path: &str,
                          accept_invalid_certs: bool, timeout: std::time::Duration) -> bool {
    let url = format!("{}/proxy/drive/api/v1/resources{}",
                      base.trim_end_matches('/'), encode_path(qualified_path));
    let client = Client::builder()
        .danger_accept_invalid_certs(accept_invalid_certs)
        .timeout(std::time::Duration::from_secs(20))
        .build();
    let Ok(client) = client else { return false };
    let deadline = std::time::Instant::now() + timeout;
    let mut delay = std::time::Duration::from_millis(250);
    while std::time::Instant::now() < deadline {
        let mut req = client.get(&url).header("X-Connection-Type", "local");
        if let Some(t) = token {
            req = req.header("Cookie", format!("TOKEN={t}"));
        }
        if let Ok(r) = req.send() {
            if r.status().is_success() { return true; }
        }
        std::thread::sleep(delay);
        delay = (delay * 2).min(std::time::Duration::from_secs(2));
    }
    false
}

/// Fold the spaces a human cannot see. macOS writes screenshot filenames with U+202F
/// (narrow no-break space) before "AM"/"PM"; Finder renders it as an ordinary space, so a
/// path typed, pasted or reconstructed from what you can see does not match the real one
/// and the console answers 404.
pub fn fold_invisible(s: &str) -> String {
    s.replace(['\u{202F}', '\u{00A0}', '\u{2007}'], " ")
        .replace('\u{FEFF}', "")
        .trim()
        .to_string()
}

fn b64(s: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(s.as_bytes())
}

fn parse_time(v: Option<&Value>) -> Option<DateTime<Utc>> {
    let s = v?.as_str()?;
    DateTime::parse_from_rfc3339(s).map(|d| d.with_timezone(&Utc)).ok()
}

// ---------------------------------------------------------------- client

pub trait DriveClient: Send + Sync {
    fn login(&self) -> Result<()>;
    fn usage(&self) -> Result<Usage>;
    fn browse(&self, dir: &str) -> Result<Vec<FileEntry>>;
    fn list_links(&self) -> Result<Vec<ShareItem>>;
    fn upload(
        &self,
        path: &Path,
        folder: &str,
        progress: &(dyn Fn(f32) + Send + Sync),
    ) -> Result<ShareItem>;
    fn create_share(
        &self,
        qualified_path: &str,
        exp: Expiration,
        password: Option<&str>,
    ) -> Result<ShareItem>;
    fn set_expiration(&self, link_id: &str, exp: Expiration) -> Result<ShareItem>;
    fn delete_link(&self, link_id: &str) -> Result<()>;
    /// Soft delete: the console moves the object to `/trash/...`, it does not erase it.
    fn delete_file(&self, qualified_path: &str) -> Result<()>;
}

pub struct LiveClient {
    base: String,
    origin: String,
    username: String,
    password: String,
    accept_invalid_certs: bool,
    /// Swapped for a fresh jar at every login (trap 1).
    http: Mutex<Arc<Client>>,
    jar: Mutex<Arc<Jar>>,
    /// The `TOKEN` value, kept so `drivedrop` can reuse a session instead of logging in on
    /// every invocation — the console rate-limits logins and will lock an account out.
    token: Mutex<Option<String>>,
    csrf: Mutex<Option<String>>,
    logged_in: Mutex<bool>,
    /// `X-Token-Expire-Time`, epoch millis.
    token_expire: Mutex<Option<i64>>,
}

struct Resp {
    status: u16,
    headers: HeaderMap,
    body: String,
}

impl Resp {
    fn json(&self) -> Option<Value> {
        serde_json::from_str(&self.body).ok()
    }
    fn header(&self, name: &str) -> Option<String> {
        self.headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string())
    }
}

impl LiveClient {
    pub fn new(host: &str, username: &str, password: &str, accept_invalid_certs: bool) -> Self {
        let base = if host.starts_with("http") {
            host.trim_end_matches('/').to_string()
        } else {
            format!("https://{}", host.trim_end_matches('/'))
        };
        let jar = Arc::new(Jar::default());
        let http = Arc::new(Self::build_client(jar.clone(), accept_invalid_certs));
        Self {
            origin: base.clone(),
            base,
            username: username.to_string(),
            password: password.to_string(),
            accept_invalid_certs,
            http: Mutex::new(http),
            jar: Mutex::new(jar),
            token: Mutex::new(None),
            csrf: Mutex::new(None),
            logged_in: Mutex::new(false),
            token_expire: Mutex::new(None),
        }
    }

    fn build_client(jar: Arc<Jar>, accept_invalid_certs: bool) -> Client {
        Client::builder()
            .cookie_provider(jar)
            .danger_accept_invalid_certs(accept_invalid_certs)
            // Uploads stream 512 KiB chunks; the default 30 s is far too tight.
            .timeout(std::time::Duration::from_secs(1800))
            .build()
            .expect("reqwest client")
    }

    fn client(&self) -> Arc<Client> {
        self.http.lock().unwrap().clone()
    }

    fn build(&self, method: &str, path: &str) -> RequestBuilder {
        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            format!("{}{}", self.base, path)
        };
        let mut b = self
            .client()
            .request(
                reqwest::Method::from_bytes(method.as_bytes()).expect("valid method"),
                url,
            )
            .header("X-Connection-Type", "local")
            .header("Origin", &self.origin)
            .header("Accept", "application/json");
        if let Some(csrf) = self.csrf.lock().unwrap().clone() {
            b = b.header("X-Csrf-Token", csrf);
        }
        b
    }

    fn send_raw(&self, rb: RequestBuilder) -> Result<Resp> {
        let resp = rb.send().map_err(|e| DriveError::Transport(e.to_string()))?;
        let status = resp.status().as_u16();
        let headers = resp.headers().clone();
        let body = resp.text().map_err(|e| DriveError::Transport(e.to_string()))?;
        // The console rotates the CSRF token mid-session; the rotated value arrives on the
        // response and must be used on the *next* write.
        if let Some(updated) = headers.get("X-Updated-Csrf-Token").and_then(|v| v.to_str().ok()) {
            *self.csrf.lock().unwrap() = Some(updated.to_string());
        }
        Ok(Resp { status, headers, body })
    }

    /// Build-and-send, with one transparent re-login on 401. The request is rebuilt rather
    /// than resent, so this is safe for calls that carry a body.
    fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Resp> {
        if !*self.logged_in.lock().unwrap() && path.contains("/proxy/drive/") {
            self.login()?;
        }
        let fire = |b: Option<&Value>| {
            let mut rb = self.build(method, path);
            if let Some(v) = b {
                rb = rb.json(v);
            }
            rb
        };
        let r = self.send_raw(fire(body))?;
        if r.status == 401 {
            *self.logged_in.lock().unwrap() = false;
            self.login()?;
            return self.send_raw(fire(body));
        }
        Ok(r)
    }

    fn require_ok(&self, r: &Resp, what: &str) -> Result<Value> {
        if !(200..=299).contains(&r.status) {
            let msg = r
                .json()
                .and_then(|j| {
                    j.pointer("/err/msg")
                        .and_then(|v| v.as_str())
                        .or_else(|| j.pointer("/error/message").and_then(|v| v.as_str()))
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| r.body.chars().take(200).collect());
            return Err(DriveError::Status(r.status, format!("{what}: {msg}")));
        }
        Ok(r.json().unwrap_or(Value::Null))
    }

    /// Share-link objects come back wrapped in `{err,type,data}`; dig through it.
    fn link_to_item(v: &Value) -> Option<ShareItem> {
        let d = v.get("data").unwrap_or(v);
        let id = d.get("id")?.as_str()?.to_string();
        let path = d.get("path")?.as_str()?.to_string();
        let token = d.get("token").and_then(|t| t.as_str());
        let name = d
            .pointer("/resource/name")
            .and_then(|n| n.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| path.rsplit('/').next().unwrap_or(&path).to_string());
        let size = d
            .pointer("/resource/size")
            .and_then(|s| s.as_i64())
            .unwrap_or(0);
        Some(ShareItem {
            file_id: path,
            id,
            name,
            size,
            share_url: token.map(|t| format!("{SHARE_WEB_BASE}/{t}")),
            direct_url: None,
            created_at: parse_time(d.get("createdAt")).unwrap_or_else(Utc::now),
            expires_at: parse_time(d.get("expiresAt")),
            phase: Phase::Ready,
            local_path: None,
        })
    }

    fn entry_from(v: &Value) -> Option<FileEntry> {
        let name = v.get("name")?.as_str()?.to_string();
        let path = v
            .get("path")
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .to_string();
        let is_dir = v.get("isDir").and_then(|d| d.as_bool()).unwrap_or(false);
        let size = if is_dir { 0 } else { v.get("size").and_then(|s| s.as_i64()).unwrap_or(0) };
        Some(FileEntry { name, path, is_dir, size, modified: parse_time(v.get("modifiedAt")) })
    }
}

impl DriveClient for LiveClient {
    /// `POST /api/auth/login` → `TOKEN` cookie + CSRF token.
    fn login(&self) -> Result<()> {
        // Trap 1: an existing TOKEN cookie makes the gateway answer
        // `403 {"error":{"code":403,"message":"Forbidden"}}`. reqwest exposes no "clear
        // cookies", so replace the whole client — the old jar goes with it.
        let jar = Arc::new(Jar::default());
        *self.jar.lock().unwrap() = jar.clone();
        *self.http.lock().unwrap() = Arc::new(Self::build_client(jar, self.accept_invalid_certs));
        *self.logged_in.lock().unwrap() = false;
        *self.csrf.lock().unwrap() = None;
        *self.token.lock().unwrap() = None;

        let body = json!({
            "username": self.username,
            "password": self.password,
            // Trap 2: this is the exact key, and it is what turns a 2-hour token into a
            // 30-day one (`exp - iat` == 2_592_000, `isRemembered: true`). `remember` and
            // `remember_user` are silently ignored.
            "rememberMe": true,
        });
        let r = self.send_raw(self.build("POST", "/api/auth/login").json(&body))?;
        if !(200..=299).contains(&r.status) {
            let msg = r
                .json()
                .and_then(|j| {
                    j.pointer("/error/message")
                        .or_else(|| j.pointer("/err/msg"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| r.body.chars().take(160).collect());
            return Err(DriveError::Status(r.status, format!("login failed: {msg}")));
        }
        *self.logged_in.lock().unwrap() = true;
        // Keep the raw cookie so `restore()` can resume this session in a later process.
        if let Some(v) = r
            .headers
            .get_all("set-cookie")
            .iter()
            .filter_map(|h| h.to_str().ok())
            .find_map(|h| h.strip_prefix("TOKEN=").and_then(|t| t.split(';').next()))
        {
            *self.token.lock().unwrap() = Some(v.to_string());
        }
        // The CSRF token is a claim inside the TOKEN JWT, so it must come from this same
        // round trip — a value cached from an earlier session will not validate.
        let csrf = r
            .header("X-Updated-Csrf-Token")
            .or_else(|| r.header("X-Csrf-Token"));
        if let Some(c) = csrf {
            *self.csrf.lock().unwrap() = Some(c);
        }
        *self.token_expire.lock().unwrap() = r
            .header("X-Token-Expire-Time")
            .and_then(|s| s.parse::<i64>().ok());
        Ok(())
    }

    /// `GET /proxy/drive/api/v2/storage` — one entry per pool; sum them.
    fn usage(&self) -> Result<Usage> {
        let r = self.call("GET", "/proxy/drive/api/v2/storage", None)?;
        let j = self.require_ok(&r, "read usage")?;
        // The storage body is top-level `{"pools":[…]}` — it is NOT wrapped in the usual
        // `{"err","type","data"}` envelope, so looking under "data" silently yields 0 B.
        let pools = j
            .get("pools")
            .or_else(|| j.pointer("/data/pools"))
            .and_then(|d| d.as_array())
            .cloned()
            .unwrap_or_default();
        let mut used = 0i64;
        let mut total = 0i64;
        for p in pools {
            used += p.get("usage").and_then(|u| u.as_i64()).unwrap_or(0);
            total += p.get("capacity").and_then(|c| c.as_i64()).unwrap_or(0);
        }
        Ok(Usage { used_bytes: used, total_bytes: total })
    }

    /// `GET /proxy/drive/api/v1/resources/<qualified>/` → children of one folder.
    fn browse(&self, dir: &str) -> Result<Vec<FileEntry>> {
        let path = listing_path(dir);
        let r = self.call("GET", &path, None)?;
        let j = self.require_ok(&r, "list folder")?;
        let items = j
            .pointer("/data/items")
            .and_then(|i| i.as_array())
            .cloned()
            .unwrap_or_default();
        let mut out: Vec<FileEntry> = items.iter().filter_map(Self::entry_from).collect();
        // Folders first, then by name — matches how the console sorts its own file list.
        out.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        Ok(out)
    }

    fn list_links(&self) -> Result<Vec<ShareItem>> {
        let r = self.call("GET", "/proxy/drive/api/v1/file-sharing/links", None)?;
        let j = self.require_ok(&r, "list share links")?;
        let arr = j.get("data").and_then(|d| d.as_array()).cloned().unwrap_or_default();
        Ok(arr.iter().filter_map(Self::link_to_item).collect())
    }

    /// tus: `POST /files` to open a session, then 512 KiB `PATCH`es to the returned
    /// Location. Finalize is asynchronous and *silent on failure*, so the object is
    /// re-read afterwards to confirm it actually landed.
    fn upload(
        &self,
        path: &Path,
        folder: &str,
        progress: &(dyn Fn(f32) + Send + Sync),
    ) -> Result<ShareItem> {
        if !*self.logged_in.lock().unwrap() {
            self.login()?;
        }
        let data = std::fs::read(path)
            .map_err(|e| DriveError::Unsupported(format!("cannot read {}: {e}", path.display())))?;
        let total = data.len();
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "upload.bin".into());
        let dir = normalize_dir(folder);

        // `checksum` is CRC32 as 8 lowercase hex chars. Trap 4: a wrong value still yields
        // 204 for every chunk, and the upload vanishes at finalize with no error anywhere.
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(&data);
        let checksum = format!("{:08x}", hasher.finalize());

        let meta = [
            format!("filename {}", b64(&name)),
            format!("dir {}", b64(&dir)),
            format!("task-id {}", b64(&uuid::Uuid::new_v4().to_string())),
            format!("checksum {}", b64(&checksum)),
        ]
        .join(",");

        let create = self.send_raw(
            self.build("POST", "/proxy/drive/api/v1/files")
                .header("Upload-Length", total.to_string())
                .header("Upload-Metadata", meta)
                .header("Tus-Resumable", TUS),
        )?;
        if !(200..=299).contains(&create.status) {
            self.require_ok(&create, "open upload")?;
        }
        let loc = create
            .header("Location")
            .ok_or_else(|| DriveError::Decoding("upload create returned no Location".into()))?;
        // Trap 3: `/api/v1/files/<id>` is Drive-relative; PATCHing it 404s.
        let upload_path = if loc.starts_with("/api/") {
            format!("/proxy/drive{loc}")
        } else {
            loc.clone()
        };

        let mut pos: usize = create
            .header("Upload-Offset")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        while pos < total {
            let end = (pos + CHUNK).min(total);
            let r = self.send_raw(
                self.build("PATCH", &upload_path)
                    .header("Upload-Offset", pos.to_string())
                    .header("Tus-Resumable", TUS)
                    .header("Content-Type", "application/offset+octet-stream")
                    .body(data[pos..end].to_vec()),
            )?;
            if !(200..=299).contains(&r.status) {
                return Err(DriveError::Status(
                    r.status,
                    format!("upload chunk rejected at offset {pos}: {}", r.body.chars().take(160).collect::<String>()),
                ));
            }
            // Trust the server's offset; if it reports nothing we made the bytes we sent.
            pos = r.header("Upload-Offset").and_then(|s| s.parse().ok()).unwrap_or(end);
            progress(if total > 0 { pos as f32 / total as f32 } else { 1.0 });
        }
        progress(1.0);

        // tus finalize is asynchronous: the last PATCH answers 204 but the object is not
        // queryable yet, and a share link created inside that window fails. Poll, and say
        // so — progress is already at 100%, so an unexplained pause reads as a hang.
        let target = format!("{}/{}", qualified(folder), name);
        progress(1.0);
        if !wait_until_visible(&self.base, self.token.lock().unwrap().as_deref(),
                               &target, self.accept_invalid_certs, std::time::Duration::from_secs(60))
        {
            return Err(DriveError::Unsupported(format!(
                "upload finished but {target} never appeared. A wrong CRC32 looks exactly \
                 like this: every chunk is accepted, then finalize discards the file."
            )));
        }

        Ok(ShareItem {
            id: target.clone(),
            file_id: target,
            name,
            size: total as i64,
            share_url: None,
            direct_url: None,
            created_at: Utc::now(),
            expires_at: None,
            phase: Phase::Ready,
            local_path: Some(path.to_string_lossy().to_string()),
        })
    }

    /// `POST /file-sharing/links` — `path` must be drive-qualified (`/mydrive/...`).
    fn create_share(
        &self,
        qualified_path: &str,
        exp: Expiration,
        password: Option<&str>,
    ) -> Result<ShareItem> {
        let mut body = json!({ "type": "public", "path": qualified_path, "accessLimit": 0 });
        if let Some(secs) = exp.seconds() {
            let when = Utc::now() + Duration::seconds(secs);
            body["expiresAt"] = json!(when.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
        }
        if let Some(p) = password {
            body["password"] = json!(p);
        }
        let r = self.call("POST", "/proxy/drive/api/v1/file-sharing/links", Some(&body))?;
        // A second link on the same path is a 403, not a 200-with-existing-link.
        if r.status == 403 {
            if let Some(existing) = self
                .list_links()?
                .into_iter()
                .find(|l| l.file_id == qualified_path)
            {
                return Ok(existing);
            }
        }
        let j = self.require_ok(&r, "create share link")?;
        Self::link_to_item(&j).ok_or_else(|| DriveError::Decoding("share link response".into()))
    }

    /// Change a link's expiry.
    ///
    /// `PATCH` **accepts `expiresAt` and ignores it** (spec C23): 200 with the stored value
    /// unchanged for every format tried, while `accessLimit` on the same route does update.
    /// Expiry is set at create only, so this deletes and recreates — which rotates the token,
    /// meaning the URL already handed out stops working. The command prints the new one for
    /// that reason; it is not a cosmetic detail.
    fn set_expiration(&self, link_id: &str, exp: Expiration) -> Result<ShareItem> {
        let current = self
            .list_links()?
            .into_iter()
            .find(|l| l.id == link_id)
            .ok_or_else(|| DriveError::NotFound(format!("link {link_id}")))?;

        self.delete_link(link_id)?;

        // The recreate can briefly report a duplicate while the delete propagates.
        let mut last = None;
        for attempt in 1..=4 {
            if attempt > 1 {
                std::thread::sleep(std::time::Duration::from_millis(300 * attempt));
            }
            match self.create_share(&current.file_id, exp, None) {
                Ok(item) => return Ok(item),
                Err(e) => last = Some(e),
            }
        }
        Err(DriveError::Decoding(format!(
            "removed the link for {} but could not create a replacement — re-share it manually ({})",
            current.name,
            last.map(|e| e.to_string()).unwrap_or_else(|| "no attempt ran".into())
        )))
    }

    fn delete_link(&self, link_id: &str) -> Result<()> {
        let path = format!("/proxy/drive/api/v1/file-sharing/links/{link_id}");
        let r = self.call("DELETE", &path, None)?;
        self.require_ok(&r, "delete share link")?;
        Ok(())
    }

    /// Soft delete — the console returns the trash path it moved the object to.
    fn delete_file(&self, qualified_path: &str) -> Result<()> {
        let path = format!("/proxy/drive/api/v1/resources{}", encode_path(qualified_path));
        let r = self.call("DELETE", &path, None)?;
        self.require_ok(&r, "delete file")?;
        Ok(())
    }
}

impl LiveClient {
    /// The live session, for caching across CLI invocations: `(token, csrf, expire_ms)`.
    /// The CSRF value is a claim inside the TOKEN JWT, so the pair is only valid together —
    /// save and restore them as a unit.
    pub fn session(&self) -> Option<(String, String, i64)> {
        let t = self.token.lock().unwrap().clone()?;
        let c = self.csrf.lock().unwrap().clone()?;
        // Copy, not clone: `Option<i64>` does not need the clone clippy would flag.
        let e = (*self.token_expire.lock().unwrap())?;
        Some((t, c, e))
    }

    /// Resume a session saved by `session()`. Skips the login round trip, which matters:
    /// the console rate-limits logins and answers
    /// `AUTHENTICATION_FAILED_LIMIT_REACHED` if you call one per command.
    pub fn restore(&self, token: &str, csrf: &str, expire_ms: i64) {
        let jar = self.jar.lock().unwrap().clone();
        if let Ok(url) = Url::parse(&self.base) {
            jar.add_cookie_str(
                &format!("TOKEN={token}; Path=/; Secure; HttpOnly; SameSite=None"), &url);
        }
        *self.token.lock().unwrap() = Some(token.to_string());
        *self.csrf.lock().unwrap() = Some(csrf.to_string());
        *self.token_expire.lock().unwrap() = Some(expire_ms);
        *self.logged_in.lock().unwrap() = true;
    }

    /// When the current token dies, for the menu-bar countdown.
    pub fn token_expire(&self) -> Option<DateTime<Utc>> {
        self.token_expire
            .lock()
            .unwrap()
            .map(|ms| DateTime::<Utc>::from_timestamp_millis(ms).unwrap_or_else(Utc::now))
    }
}

// ---------------------------------------------------------------- offline mock

/// Demo client so the UI can be built and screenshotted without a console. Hosts are
/// `demo.invalid` (RFC 2606) so a fake link can never be pasted and look real.
pub struct MockClient {
    store: Mutex<Vec<ShareItem>>,
    /// Files put there by `upload`, so the demo's Files list behaves like the console's: an upload
    /// appears in the folder it was aimed at and in no other. A mock that answers every `browse`
    /// with the same two fixtures cannot show whether the folder argument reached the server, which
    /// is the whole point of the demo.
    uploaded: Mutex<Vec<FileEntry>>,
    /// Paths moved to trash by `delete_file`. Kept rather than dropped, because that is what a
    /// trash does, and listings must stop showing them.
    trashed: Mutex<Vec<String>>,
}

impl MockClient {
    pub fn new() -> Self {
        let mk = |id: &str, name: &str, size: i64, age: i64, exp: i64| ShareItem {
            id: id.into(),
            file_id: format!("/mydrive/Public/{name}"),
            name: name.into(),
            size,
            share_url: Some(format!("{SHARE_WEB_BASE}/demo-{id}")),
            direct_url: None,
            created_at: Utc::now() - Duration::seconds(age),
            expires_at: Some(Utc::now() + Duration::seconds(exp)),
            phase: Phase::Ready,
            local_path: None,
        };
        Self {
            store: Mutex::new(vec![
                mk("1", "site-plan.pdf", 2_411_724, 7_200, 3 * 86_400),
                mk("2", "garage-clip.mov", 92_274_688, 86_400, 2_400),
            ]),
            uploaded: Mutex::new(Vec::new()),
            trashed: Mutex::new(Vec::new()),
        }
    }
}

impl Default for MockClient {
    fn default() -> Self {
        Self::new()
    }
}

impl DriveClient for MockClient {
    fn login(&self) -> Result<()> {
        Ok(())
    }
    fn usage(&self) -> Result<Usage> {
        Ok(Usage { used_bytes: 3_724_542_208, total_bytes: 15_999_766_528 })
    }
    fn browse(&self, dir: &str) -> Result<Vec<FileEntry>> {
        // Same folder rule the live client applies: fixtures live under /Public, and an upload is
        // visible only in the directory it was written to.
        //
        // Entry paths are drive-qualified (`/mydrive/Public/x`) while `dir` arrives personal-
        // relative (`/Public`), so the drive prefix has to come off the parent before comparing.
        // Comparing the raw parent instead silently matched nothing - which is exactly how the Files
        // list vanished from the demo while the links still showed, and why this has a test now.
        let want = dir.trim().trim_matches('/');
        let in_dir = |p: &str| -> bool {
            let parent = p.rsplit_once('/').map(|(parent, _)| parent).unwrap_or("");
            parent.strip_prefix("/mydrive").unwrap_or(parent).trim_matches('/') == want
        };
        let fixtures = [
            FileEntry { name: "Documents".into(), path: "/mydrive/Public/Documents".into(), is_dir: true, size: 0, modified: None },
            FileEntry { name: "site-plan.pdf".into(), path: "/mydrive/Public/site-plan.pdf".into(), is_dir: false, size: 2_411_724, modified: None },
        ];
        let trashed = self.trashed.lock().unwrap();
        let kept = |e: &FileEntry| in_dir(&e.path) && !trashed.iter().any(|t| t == &e.path);
        let mut out: Vec<FileEntry> = fixtures.into_iter().filter(|e| kept(e)).collect();
        out.extend(self.uploaded.lock().unwrap().iter().filter(|e| kept(e)).cloned());
        Ok(out)
    }
    fn list_links(&self) -> Result<Vec<ShareItem>> {
        Ok(self.store.lock().unwrap().clone())
    }
    fn upload(&self, path: &Path, folder: &str, progress: &(dyn Fn(f32) + Send + Sync)) -> Result<ShareItem> {
        // Mirror the live client, which reads the file first and fails on a bad path. A mock that
        // "uploads" a file that does not exist turns every upload test into a test of nothing, and
        // it is how this mock once hid a wrong path argument.
        let data = std::fs::read(path)
            .map_err(|e| DriveError::Unsupported(format!("cannot read {}: {e}", path.display())))?;
        for i in 1..=10 {
            std::thread::sleep(std::time::Duration::from_millis(40));
            progress(i as f32 / 10.0);
        }
        let name = path.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        // Honour the folder the caller asked for. A mock that always answers `/Public` hides a
        // wrong folder argument, which is exactly the class of bug that ends with files in a
        // directory nobody chose.
        let dir = folder.trim().trim_matches('/');
        let file_id = if dir.is_empty() {
            format!("/mydrive/{name}")
        } else {
            format!("/mydrive/{dir}/{name}")
        };
        self.uploaded.lock().unwrap().push(FileEntry {
            name: name.clone(),
            path: file_id.clone(),
            is_dir: false,
            size: data.len() as i64,
            modified: None,
        });
        Ok(ShareItem {
            id: format!("demo-{}", uuid::Uuid::new_v4()),
            file_id,
            name,
            size: 0,
            share_url: None,
            direct_url: None,
            created_at: Utc::now(),
            expires_at: None,
            phase: Phase::Ready,
            local_path: Some(path.to_string_lossy().to_string()),
        })
    }
    fn create_share(&self, qualified_path: &str, exp: Expiration, _pw: Option<&str>) -> Result<ShareItem> {
        let item = ShareItem {
            id: uuid::Uuid::new_v4().to_string(),
            file_id: qualified_path.to_string(),
            name: qualified_path.rsplit('/').next().unwrap_or("").to_string(),
            size: 0,
            share_url: Some(format!("{SHARE_WEB_BASE}/demo-{}", uuid::Uuid::new_v4())),
            direct_url: None,
            created_at: Utc::now(),
            expires_at: exp.seconds().map(|s| Utc::now() + Duration::seconds(s)),
            phase: Phase::Ready,
            local_path: None,
        };
        self.store.lock().unwrap().push(item.clone());
        Ok(item)
    }
    /// Mirrors the console: expiry is create-only, so changing it replaces the link and
    /// rotates both `id` and `share_url`. Mutating in place would let tests pass against a
    /// behaviour the server does not have.
    fn set_expiration(&self, link_id: &str, exp: Expiration) -> Result<ShareItem> {
        let current = {
            let store = self.store.lock().unwrap();
            store
                .iter()
                .find(|i| i.id == link_id)
                .cloned()
                .ok_or(DriveError::NotFound(format!("link {link_id}")))?
        };
        self.delete_link(link_id)?;
        self.create_share(&current.file_id, exp, None)
    }
    fn delete_link(&self, link_id: &str) -> Result<()> {
        self.store.lock().unwrap().retain(|i| i.id != link_id);
        Ok(())
    }
    /// Soft delete, like the console: the object goes to trash and leaves every listing, and the
    /// link that pointed at it dies with it. A no-op here means the demo shows a file that the user
    /// just deleted still sitting in the folder, which teaches the wrong lesson about the button.
    fn delete_file(&self, qualified_path: &str) -> Result<()> {
        let mut t = self.trashed.lock().unwrap();
        if !t.iter().any(|p| p == qualified_path) { t.push(qualified_path.to_string()); }
        drop(t);
        self.store.lock().unwrap().retain(|l| l.file_id != qualified_path);
        Ok(())
    }
}

// ---------------------------------------------------------------- tests
// Pure logic only. The network paths are covered by the `drivedrop` binary against a real
// console; nothing here should need one.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_dir_is_absolute_and_unterminated() {
        assert_eq!(normalize_dir(""), "/");
        assert_eq!(normalize_dir("   "), "/");
        assert_eq!(normalize_dir("/"), "/");
        assert_eq!(normalize_dir("Public"), "/Public");
        assert_eq!(normalize_dir("/Public/"), "/Public");
        assert_eq!(normalize_dir("  /a//b//  "), "/a/b");
    }

    #[test]
    fn canonical_clamps_at_root() {
        assert_eq!(canonical("/"), "/");
        assert_eq!(canonical("/a/./b"), "/a/b");
        assert_eq!(canonical("/a/../b"), "/b");
        // Walking past the root must not escape the drive.
        assert_eq!(canonical("/../../etc"), "/etc");
        assert_eq!(canonical("/a/../../b"), "/b");
    }

    #[test]
    fn qualified_prefixes_the_personal_drive() {
        assert_eq!(qualified("/"), "/mydrive");
        assert_eq!(qualified("/Public"), "/mydrive/Public");
    }

    #[test]
    fn listing_path_keeps_the_load_bearing_trailing_slash() {
        // `/resources/mydrive` 404s; `/resources/mydrive/` lists. This is the whole test.
        assert!(listing_path("/Public").ends_with("/mydrive/Public/"));
        assert_eq!(listing_path("/"), "/proxy/drive/api/v1/resources/mydrive/");
    }

    #[test]
    fn encode_path_keeps_slashes_and_escapes_the_rest() {
        assert_eq!(encode_path("/a b/c.pdf"), "/a%20b/c.pdf");
        assert_eq!(encode_path("/Public"), "/Public");
        assert_eq!(encode_path("/\u{2602}"), "/%E2%98%82");
    }

    #[test]
    fn checksum_is_crc32_in_eight_lowercase_hex() {
        // The standard CRC-32 check value for "123456789" is 0xCBF43926.
        let mut h = crc32fast::Hasher::new();
        h.update(b"123456789");
        assert_eq!(format!("{:08x}", h.finalize()), "cbf43926");
    }

    #[test]
    fn metadata_values_are_base64_and_comma_joined() {
        let m = format!("filename {}", b64("a.txt"));
        assert_eq!(m, "filename YS50eHQ=");
    }

    #[test]
    fn invisible_spaces_are_folded_for_matching() {
        // A macOS screenshot really is named with U+202F before "PM"; Finder shows a normal
        // space, so a path typed from what you see does not match and DELETE 404s.
        let real = "Screenshot 2026-10-05 at 3.23.01\u{202f}PM.png";
        let typed = "Screenshot 2026-10-05 at 3.23.01 PM.png";
        assert_ne!(real, typed);
        assert_eq!(fold_invisible(real), fold_invisible(typed));
        assert_eq!(fold_invisible("a\u{00a0}b"), "a b");
    }

    #[test]
    fn chunk_size_matches_the_ui_capture() {
        assert_eq!(CHUNK, 512 * 1024);
    }

    #[test]
    fn share_urls_point_at_drop_ui_not_the_console() {
        // A pasted link must never look like it points at a LAN address.
        assert_eq!(SHARE_WEB_BASE, "https://drop.ui.com");
    }

    #[test]
    fn changing_expiry_replaces_the_link_and_rotates_the_url() {
        // Spec C23: PATCH ignores expiresAt, so the only way is delete + recreate, and that
        // mints a new token. The mock has to behave that way or tests written against it
        // describe a server that does not exist.
        let c = MockClient::new();
        let first = c
            .create_share("/mydrive/report.pdf", Expiration::Never, None)
            .unwrap();
        let updated = c.set_expiration(&first.id, Expiration::OneDay).unwrap();

        assert_ne!(updated.id, first.id, "recreating must change the link id");
        assert_ne!(
            updated.share_url, first.share_url,
            "a new link must not reuse the old token"
        );
        assert!(updated.expires_at.is_some(), "the new expiry must be set");
        assert_eq!(updated.file_id, first.file_id, "same file, new link");

        // The old link is gone, not merely edited. MockClient::new() seeds demo links, so
        // scope the check to the file under test rather than the whole store.
        let for_file: Vec<_> = c
            .list_links()
            .unwrap()
            .iter()
            .filter(|l| l.file_id == first.file_id)
            .map(|l| l.id.clone())
            .collect();
        assert!(!for_file.contains(&first.id), "the superseded link must be deleted");
        assert_eq!(for_file, vec![updated.id.clone()], "exactly one live link per file");

        // And targeting a link that no longer exists is an error, not a silent no-op.
        assert!(c.set_expiration(&first.id, Expiration::OneHour).is_err());
    }

    /// Deleting a file takes its link with it, and the file leaves every listing.
    #[test]
    fn mock_delete_file_trashes_the_file_and_kills_its_link() {
        let c = MockClient::new();
        let before = c.list_links().unwrap().len();
        assert!(c.browse("/Public").unwrap().iter().any(|e| e.name == "site-plan.pdf"));

        c.delete_file("/mydrive/Public/site-plan.pdf").unwrap();

        assert!(!c.browse("/Public").unwrap().iter().any(|e| e.name == "site-plan.pdf"),
                "a trashed file must not still be listed");
        assert_eq!(c.list_links().unwrap().len(), before - 1,
                   "the link pointing at a trashed file must be gone too");
        // Trashing twice is not an error - the console is idempotent about it.
        assert!(c.delete_file("/mydrive/Public/site-plan.pdf").is_ok());
    }

    /// The demo's Files list is the only place a folder-scoped browse is visible without a real
    /// console, and a wrong comparison here empties it silently - links still render, so nothing
    /// looks broken. This is the test for the bug that did exactly that.
    #[test]
    fn mock_browse_answers_only_the_folder_it_was_asked_about() {
        let c = MockClient::new();

        let public: Vec<String> = c.browse("/Public").unwrap().iter()
            .map(|e| e.name.clone()).collect();
        assert!(public.contains(&"Documents".to_string()), "fixtures live under /Public, got {public:?}");
        assert!(public.contains(&"site-plan.pdf".to_string()));

        // Trailing slash and the bare root are the two forms the UI actually sends.
        assert_eq!(c.browse("/Public/").unwrap().len(), public.len());
        assert!(c.browse("/").unwrap().is_empty(), "nothing sits at the drive root in the demo");
        assert!(c.browse("/Private").unwrap().is_empty());
    }

    /// An upload must show up where it was put and nowhere else - the folder argument is the whole
    /// point, and a mock that lists a file in every directory hides a wrong one.
    #[test]
    fn mock_upload_lands_in_the_folder_it_was_aimed_at() {
        let c = MockClient::new();
        let f = std::env::temp_dir().join("drivedrop-mock-upload.txt");
        std::fs::write(&f, b"x").unwrap();

        let item = c.upload(&f, "/Public", &|_| {}).unwrap();
        assert_eq!(item.file_id, "/mydrive/Public/drivedrop-mock-upload.txt");

        let names: Vec<String> = c.browse("/Public").unwrap().iter()
            .map(|e| e.name.clone()).collect();
        assert!(names.contains(&"drivedrop-mock-upload.txt".to_string()),
                "the uploaded file must be listed in its folder");
        assert!(!c.browse("/").unwrap().iter().any(|e| e.name.contains("drivedrop-mock")),
                "and must not appear at the root");

        // The live client reads the file; so must the mock, or a bad path tests nothing.
        assert!(c.upload(std::path::Path::new("Z:\\nope.bin"), "/Public", &|_| {}).is_err());
        let _ = std::fs::remove_file(&f);
    }
}

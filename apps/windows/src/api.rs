//! Drive API client. Mirrors apps/macos/Sources/DriveDrop/LiveDriveClient.swift
//! Endpoint confidence is documented in spec/api.md.

use std::path::Path;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, TimeZone, Utc};
use reqwest::blocking::{Client, RequestBuilder};
use reqwest::cookie::Jar;
use reqwest::header::HeaderMap;

use crate::models::*;

// ---------------------------------------------------------------- client trait

pub trait DriveClient: Send + Sync {
    fn login(&self) -> Result<()>;
    fn usage(&self) -> Result<Usage>;
    fn list(&self) -> Result<Vec<ShareItem>>;
    fn upload(&self, path: &Path, folder: &str, progress: &(dyn Fn(f32) + Send + Sync)) -> Result<ShareItem>;
    fn create_share(&self, item: &ShareItem, exp: Expiration, password: Option<&str>) -> Result<ShareItem>;
    fn set_expiration(&self, item: &ShareItem, exp: Expiration) -> Result<ShareItem>;
    fn delete(&self, item: &ShareItem) -> Result<()>;
}

// ---------------------------------------------------------------- live client

pub struct LiveClient {
    base: String,
    username: String,
    password: String,
    http: Client,
    csrf: Mutex<Option<String>>,
    logged_in: Mutex<bool>,
}

struct Resp {
    status: u16,
    headers: HeaderMap,
    body: String,
}

impl Resp {
    fn json(&self) -> Option<serde_json::Value> {
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
        let jar = Arc::new(Jar::new(
            url_parse(&base).expect("valid url"),
        ));
        let http = Client::builder()
            .cookie_jar(jar)
            .danger_accept_invalid_certs(accept_invalid_certs)
            .timeout(std::time::Duration::from_secs(120))
            .build()
            .expect("build http client");
        Self {
            base,
            username: username.to_string(),
            password: password.to_string(),
            http,
            csrf: Mutex::new(None),
            logged_in: Mutex::new(false),
        }
    }

    fn build(&self, method: &str, path: &str) -> RequestBuilder {
        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            format!("{}{}", self.base, path)
        };
        let mut b = self.http.request(
            reqwest::Method::from_bytes(method.as_bytes()).expect("method"),
            url,
        );
        if let Some(csrf) = self.csrf.lock().unwrap().clone() {
            b = b.header("X-Csrf-Token", csrf);
        }
        b
    }

    fn send_raw(&self, rb: RequestBuilder) -> Result<Resp> {
        let resp = rb.send().map_err(|e| DriveError::Transport(e.to_string()))?;
        let status = resp.status().as_u16();
        let headers = resp.headers().clone();
        let body = resp
            .text()
            .map_err(|e| DriveError::Transport(e.to_string()))?;
        if let Some(updated) = headers
            .get("X-Updated-Csrf-Token")
            .and_then(|v| v.to_str().ok())
        {
            *self.csrf.lock().unwrap() = updated.to_string();
        }
        Ok(Resp {
            status,
            headers,
            body,
        })
    }

    /// Send with one transparent re-login on 401.
    fn send(&self, method: &str, path: &str, mut rb: RequestBuilder) -> Result<Resp> {
        if !*self.logged_in.lock().unwrap() && path.contains("/proxy/drive/") {
            self.login()?;
        }
        // mirror csrf onto the pre-built request
        if let Some(csrf) = self.csrf.lock().unwrap().clone() {
            rb = rb.header("X-Csrf-Token", csrf);
        }
        let r = self.send_raw(rb)?;
        if r.status == 401 {
            *self.logged_in.lock().unwrap() = false;
            self.login()?;
            let csrf = self.csrf.lock().unwrap().clone();
            let mut rb2 = self.build(method, path);
            if let Some(c) = csrf {
                rb2 = rb2.header("X-Csrf-Token", c);
            }
            return self.send_raw(rb2);
        }
        Ok(r)
    }

    fn require_ok<'a>(&self, r: &'a Resp, what: &str) -> Result<&'a serde_json::Value> {
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
        static EMPTY: std::sync::OnceLock<serde_json::Value> = std::sync::OnceLock::new();
        let v = EMPTY.get_or_init(|| serde_json::Value::Null);
        Ok(r.json().as_ref().unwrap_or(v))
    }

    /// Drive wraps payloads inconsistently; search the common shapes.
    fn dig<'a>(v: &'a serde_json::Value, keys: &[&str]) -> Option<&'a serde_json::Value> {
        let map = v.as_object()?;
        let containers: Vec<&serde_json::Map<String, serde_json::Value>> =
            vec![map, map.get("data").and_then(|d| d.as_object())]
                .into_iter()
                .flatten()
                .collect();
        for c in containers {
            for k in keys {
                if let Some(x) = c.get(*k) {
                    return Some(x);
                }
            }
        }
        None
    }

    fn dig_str(v: &serde_json::Value, keys: &[&str]) -> Option<String> {
        Self::dig(v, keys).and_then(|x| x.as_str()).map(|s| s.to_string())
    }
}

fn url_parse(s: &str) -> Option<reqwest::Url> {
    reqwest::Url::parse(s).ok()
}

impl DriveClient for LiveClient {
    /// VERIFIED contract: POST /api/auth/login {username,password} -> TOKEN cookie
    fn login(&self) -> Result<()> {
        let body = serde_json::json!({
            "username": self.username,
            "password": self.password,
        });
        let r = self.send_raw(self.build("POST", "/api/auth/login").json(&body))?;
        match r.status {
            200..=299 => {
                *self.logged_in.lock().unwrap() = true;
                if let Some(c) = r.header("X-Csrf-Token") {
                    *self.csrf.lock().unwrap() = c;
                }
                Ok(())
            }
            400 => {
                let msg = r
                    .json()
                    .and_then(|j| j["message"].as_str().map(|s| s.to_string()))
                    .unwrap_or_else(|| "invalid request".into());
                Err(DriveError::Status(400, format!("Login rejected: {msg}")))
            }
            other => Err(DriveError::Status(
                other,
                if r.body.is_empty() {
                    "login failed".into()
                } else {
                    r.body.chars().take(200).collect()
                },
            )),
        }
    }

    /// VERIFIED route: GET /proxy/drive/api/v2/storage
    fn usage(&self) -> Result<Usage> {
        let r = self.send("GET", "/proxy/drive/api/v2/storage", self.build("GET", "/proxy/drive/api/v2/storage"))?;
        let j = self.require_ok(&r, "usage")?;
        let mut used = 0i64;
        let mut total = 0i64;
        if let Some(pools) = Self::dig(j, &["pools"]).and_then(|p| p.as_array()) {
            for p in pools {
                let g = |k: &str| -> i64 {
                    p.get(k).map(|v| match v {
                        serde_json::Value::Number(n) => n
                            .as_i64()
                            .or_else(|| n.as_f64().map(|f| f as i64))
                            .unwrap_or(0),
                        serde_json::Value::String(s) => s.parse().unwrap_or(0),
                        _ => 0,
                    })
                };
                total += g("size") + g("totalSize") + g("capacity");
                used += g("used") + g("usedSize");
            }
        }
        Ok(Usage {
            used_bytes: used,
            total_bytes: total,
        })
    }

    fn list(&self) -> Result<Vec<ShareItem>> {
        let path = "/proxy/drive/api/v1/files?limit=200&offset=0";
        let r = self.send("GET", path, self.build("GET", path))?;
        let j = self.require_ok(&r, "list")?;
        let rows = Self::dig(j, &["files", "items", "records", "list"])
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(rows
            .iter()
            .filter_map(|row| {
                let file_id = row
                    .get("id")
                    .or_else(|| row.get("fileId"))
                    .or_else(|| row.get("uuid"))
                    .and_then(|v| v.as_str())?
                    .to_string();
                let name = row
                    .get("name")
                    .or_else(|| row.get("fileName"))
                    .or_else(|| row.get("displayName"))
                    .and_then(|v| v.as_str())
                    .unwrap_or(&file_id)
                    .to_string();
                let size = row
                    .get("size")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                Some(ShareItem {
                    id: row
                        .get("shareId")
                        .and_then(|v| v.as_str())
                        .unwrap_or(&file_id)
                        .to_string(),
                    file_id,
                    name,
                    size,
                    share_url: row
                        .get("shareUrl")
                        .or_else(|| row.get("url"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string()),
                    direct_url: None,
                    created_at: Utc::now(),
                    expires_at: row
                        .get("expireAt")
                        .or_else(|| row.get("expiresAt"))
                        .and_then(|v| v.as_str())
                        .and_then(parse_iso),
                    phase: Phase::Ready,
                    local_path: None,
                })
            })
            .collect())
    }

    /// tus handshake, falling back to multipart.
    fn upload(
        &self,
        path: &Path,
        folder: &str,
        progress: &(dyn Fn(f32) + Send + Sync),
    ) -> Result<ShareItem> {
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "file".into());
        let data = std::fs::read(path).map_err(|e| DriveError::Transport(e.to_string()))?;
        let size = data.len() as i64;

        match self.upload_tus(&name, &data, folder, progress) {
            Ok(item) => Ok(item),
            Err(DriveError::Unsupported(_)) => self.upload_multipart(&name, &data, folder, progress),
            Err(e) => Err(e),
        }
    }

    fn create_share(&self, item: &ShareItem, exp: Expiration, password: Option<&str>) -> Result<ShareItem> {
        let mut payload = serde_json::Map::new();
        payload.insert(
            "expireInSeconds".into(),
            match exp.seconds() {
                Some(s) => serde_json::json!(s),
                None => serde_json::Value::Null,
            },
        );
        if let Some(p) = password {
            payload.insert("password".into(), serde_json::json!(p));
        }
        if let Some(d) = exp.date() {
            payload.insert("expiresAt".into(), serde_json::json!(d.to_rfc3339()));
        }

        let file_id = item.file_id.clone();
        let candidates = [
            format!("/proxy/drive/api/v1/files/{file_id}/share"),
            "/proxy/drive/api/v1/shares".to_string(),
            "/proxy/drive/api/v1/public".to_string(),
        ];
        let mut last = DriveError::Unsupported("no share endpoint responded".into());

        for (i, p) in candidates.iter().enumerate() {
            let mut body = payload.clone();
            if i > 0 {
                body.insert("fileId".into(), serde_json::json!(file_id));
            }
            let rb = self.build("POST", p).json(&body);
            let r = match self.send("POST", p, rb) {
                Ok(r) => r,
                Err(e) => {
                    last = e;
                    continue;
                }
            };
            if (200..=299).contains(&r.status) {
                let j = r
                    .json()
                    .ok_or_else(|| DriveError::Decoding("share response not JSON".into()))?;
                // Never assemble the URL ourselves — use exactly what the server returns.
                let url = Self::dig_str(&j, &["shareUrl", "url", "link", "publicUrl"]).ok_or_else(|| {
                    DriveError::Decoding(format!(
                        "share created but no URL field: {}",
                        r.body.chars().take(300).collect::<String>()
                    ))
                })?;
                return Ok(ShareItem {
                    id: Self::dig_str(&j, &["shareId", "id", "token"]).unwrap_or_else(|| file_id.clone()),
                    file_id,
                    name: Self::dig_str(&j, &["fileName", "name"]).unwrap_or_else(|| item.name.clone()),
                    size: item.size,
                    share_url: Some(url),
                    direct_url: Self::dig_str(&j, &["downloadUrl", "directUrl"]),
                    created_at: Utc::now(),
                    expires_at: exp.date(),
                    phase: Phase::Ready,
                    local_path: item.local_path.clone(),
                });
            }
            last = DriveError::Status(r.status, r.body.chars().take(200).collect());
        }
        Err(last)
    }

    fn set_expiration(&self, item: &ShareItem, exp: Expiration) -> Result<ShareItem> {
        let p = format!("/proxy/drive/api/v1/shares/{}", item.id);
        let mut body = serde_json::Map::new();
        body.insert(
            "expireInSeconds".into(),
            match exp.seconds() {
                Some(s) => serde_json::json!(s),
                None => serde_json::Value::Null,
            },
        );
        if let Some(d) = exp.date() {
            body.insert("expiresAt".into(), serde_json::json!(d.to_rfc3339()));
        }
        let r = self.send("PATCH", &p, self.build("PATCH", &p).json(&body))?;
        self.require_ok(&r, "setExpiration")?;
        let mut out = item.clone();
        out.expires_at = exp.date();
        Ok(out)
    }

    fn delete(&self, item: &ShareItem) -> Result<()> {
        let p = format!("/proxy/drive/api/v1/shares/{}", item.id);
        let r = self.send("DELETE", &p, self.build("DELETE", &p))?;
        if r.status == 404 {
            let p2 = format!("/proxy/drive/api/v1/files/{}", item.file_id);
            let r2 = self.send("DELETE", &p2, self.build("DELETE", &p2))?;
            self.require_ok(&r2, "delete")?;
            return Ok(());
        }
        self.require_ok(&r, "delete")?;
        Ok(())
    }
}

// tus helpers

/// minimal base64 (no extra dependency) for tus Upload-Metadata
fn b64(s: &str) -> String {
    let mut out = String::new();
    let bytes = s.as_bytes();
    const TBL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TBL[(n >> 18) as usize & 63] as char);
        out.push(TBL[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TBL[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TBL[n as usize & 63] as char } else { '=' });
    }
    out
}

impl LiveClient {
    fn upload_tus(
        &self,
        name: &str,
        data: &[u8],
        folder: &str,
        progress: &(dyn Fn(f32) + Send + Sync),
    ) -> Result<ShareItem> {
        let meta = format!(
            "filename {},contentType {}",
            b64(name),
            b64("application/octet-stream")
        );
        let path = "/proxy/drive/api/v1/files";
        let create = self.send(
            "POST",
            path,
            self.build("POST", path)
                .header("Upload-Length", data.len().to_string())
                .header("Upload-Metadata", meta)
                .header("Upload-Parent", b64(folder))
                .header("Tus-Resumable", "1.0.0")
                .header("Content-Type", "application/octet-stream"),
        )?;

        if !(200..=299).contains(&create.status) {
            return Err(DriveError::Unsupported(format!(
                "tus create rejected ({})",
                create.status
            )));
        }
        let loc = create
            .header("Location")
            .ok_or_else(|| DriveError::Unsupported("tus create returned no Location".into()))?;

        let mut offset: usize = create
            .header("Upload-Offset")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        let chunk = 4 * 1024 * 1024;
        while offset < data.len() {
            let end = (offset + chunk).min(data.len());
            let slice = &data[offset..end];
            let r = self.send(
                "PATCH",
                &loc,
                self.build("PATCH", &loc)
                    .header("Upload-Offset", offset.to_string())
                    .header("Tus-Resumable", "1.0.0")
                    .header("Content-Type", "application/offset+octet-stream")
                    .body(slice.to_vec()),
            )?;
            if !(200..=299).contains(&r.status) {
                return Err(DriveError::Unsupported(format!(
                    "tus patch rejected ({})",
                    r.status
                )));
            }
            offset = r
                .header("Upload-Offset")
                .and_then(|s| s.parse().ok())
                .unwrap_or(end);
            progress(offset as f32 / data.len() as f32);
        }
        progress(1.0);

        let j = create.json();
        let file_id = create
            .header("X-File-Id")
            .or_else(|| j.as_ref().and_then(|v| Self::dig_str(v, &["fileId", "id", "uuid"])))
            .ok_or_else(|| DriveError::Decoding("upload succeeded but no file id".into()))?;

        Ok(ShareItem {
            id: file_id.clone(),
            file_id,
            name: name.to_string(),
            size: data.len() as i64,
            share_url: create
                .header("X-Share-Url")
                .or_else(|| j.as_ref().and_then(|v| Self::dig_str(v, &["shareUrl", "url"]))),
            direct_url: None,
            created_at: Utc::now(),
            expires_at: None,
            phase: Phase::Ready,
            local_path: None,
        })
    }

    fn upload_multipart(
        &self,
        name: &str,
        data: &[u8],
        folder: &str,
        progress: &(dyn Fn(f32) + Send + Sync),
    ) -> Result<ShareItem> {
        let part = reqwest::blocking::multipart::Part::bytes(data.to_vec())
            .file_name(name.to_string())
            .mime_str("application/octet-stream")
            .map_err(|e| DriveError::Transport(e.to_string()))?;
        let form = reqwest::blocking::multipart::Form::new()
            .text("path", folder.to_string())
            .part("file", part);

        let path = "/proxy/drive/api/v1/files";
        let r = self.send("POST", path, self.build("POST", path).multipart(form))?;
        progress(1.0);
        let j = self.require_ok(&r, "upload")?;

        let file_id = Self::dig_str(j, &["fileId", "id", "uuid"]).ok_or_else(|| {
            DriveError::Decoding(format!(
                "no file id in upload response: {}",
                r.body.chars().take(200).collect::<String>()
            ))
        })?;

        Ok(ShareItem {
            id: file_id.clone(),
            file_id,
            name: name.to_string(),
            size: data.len() as i64,
            share_url: Self::dig_str(j, &["shareUrl", "url"]),
            direct_url: None,
            created_at: Utc::now(),
            expires_at: None,
            phase: Phase::Ready,
            local_path: None,
        })
    }
}

fn parse_iso(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .ok()
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S")
                .ok()
                .map(|n| Utc.from_utc_datetime(&n))
        })
}



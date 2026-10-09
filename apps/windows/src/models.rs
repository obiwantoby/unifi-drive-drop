//! Domain model — mirrors apps/macos/Sources/DriveDrop/Models.swift

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Expiration {
    OneHour,
    OneDay,
    SevenDays,
    ThirtyDays,
    Never,
}

impl Expiration {
    pub const MENU: [Expiration; 5] = [
        Expiration::OneHour,
        Expiration::OneDay,
        Expiration::SevenDays,
        Expiration::ThirtyDays,
        Expiration::Never,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Expiration::OneHour => "1 hour",
            Expiration::OneDay => "1 day",
            Expiration::SevenDays => "7 days",
            Expiration::ThirtyDays => "30 days",
            Expiration::Never => "Never",
        }
    }

    pub fn seconds(self) -> Option<i64> {
        match self {
            Expiration::OneHour => Some(3_600),
            Expiration::OneDay => Some(86_400),
            Expiration::SevenDays => Some(604_800),
            Expiration::ThirtyDays => Some(2_592_000),
            Expiration::Never => None,
        }
    }

    pub fn date(self) -> Option<DateTime<Utc>> {
        self.seconds()
            .map(|s| Utc::now() + chrono::Duration::seconds(s))
    }

    pub fn key(self) -> &'static str {
        match self {
            Expiration::OneHour => "1h",
            Expiration::OneDay => "1d",
            Expiration::SevenDays => "7d",
            Expiration::ThirtyDays => "30d",
            Expiration::Never => "never",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    Queued,
    Uploading(f32),
    Sharing,
    Ready,
    Failed(String),
}

impl Phase {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Phase::Ready | Phase::Failed(_))
    }
}

#[derive(Debug, Clone)]
pub struct ShareItem {
    pub id: String,
    pub file_id: String,
    pub name: String,
    pub size: i64,
    pub share_url: Option<String>,
    pub direct_url: Option<String>,
    pub created_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub phase: Phase,
    pub local_path: Option<String>,
}

impl ShareItem {
    pub fn placeholder(local_path: &str, name: String, size: i64) -> Self {
        Self {
            id: format!("pending-{}", uuid_like()),
            file_id: String::new(),
            name,
            size,
            share_url: None,
            direct_url: None,
            created_at: Utc::now(),
            expires_at: None,
            phase: Phase::Uploading(0.0),
            local_path: Some(local_path.to_string()),
        }
    }
}

/// One row of a folder listing. `path` is drive-qualified (`/mydrive/Public/x.pdf`), which
/// is also the join key against a share link's `path`.
#[derive(Debug, Clone)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: i64,
    pub modified: Option<DateTime<Utc>>,
}

impl FileEntry {
    pub fn display_path(&self) -> String {
        self.path
            .trim_start_matches("/mydrive")
            .trim_start_matches("/shared")
            .to_string()
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Usage {
    pub used_bytes: i64,
    pub total_bytes: i64,
}

impl Usage {
    pub fn free_bytes(&self) -> i64 {
        (self.total_bytes - self.used_bytes).max(0)
    }
}

#[derive(Debug)]
pub enum DriveError {
    NotAuthenticated,
    /// The path you named is not on the console. Distinct from `Unsupported`, which reads
    /// "this console build cannot do that" and sends you debugging the wrong thing.
    NotFound(String),
    Transport(String),
    Status(u16, String),
    Decoding(String),
    Unsupported(String),
}

impl DriveError {
    pub fn human(&self) -> String {
        match self {
            DriveError::NotAuthenticated => "Not signed in to the console.".into(),
            DriveError::NotFound(m) => format!("No such file on the console: {m}"),
            DriveError::Transport(m) => format!("Could not reach the console. {m}"),
            DriveError::Status(c, m) => format!("Console returned {c}: {m}"),
            DriveError::Decoding(m) => format!("Unexpected response from console ({m})."),
            DriveError::Unsupported(m) => format!("Not supported by this console build: {m}"),
        }
    }
}

impl std::fmt::Display for DriveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.human())
    }
}

impl std::error::Error for DriveError {}

pub type Result<T> = std::result::Result<T, DriveError>;

/// Tiny helper so we do not need the uuid crate for display ids.
pub fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64 ^ (d.as_secs() << 7))
        .unwrap_or(0);
    format!("{:08x}", n & 0xffff_ffff)
}

pub mod fmt {
    use super::*;

    pub fn bytes(n: i64) -> String {
        const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
        if n <= 0 {
            return "0 B".into();
        }
        let mut v = n as f64;
        let mut u = 0;
        while v >= 1024.0 && u < UNITS.len() - 1 {
            v /= 1024.0;
            u += 1;
        }
        if u == 0 {
            format!("{} {}", n, UNITS[u])
        } else {
            format!("{:.1} {}", v, UNITS[u])
        }
    }

    pub fn countdown(to: Option<DateTime<Utc>>) -> Option<String> {
        let d = to?;
        let iv = d.timestamp() - Utc::now().timestamp();
        if iv <= 0 {
            return Some("expired".into());
        }
        let days = iv / 86_400;
        let hours = (iv % 86_400) / 3_600;
        let mins = (iv % 3_600) / 60;
        Some(if days > 0 {
            format!("expires in {days}d {hours}h")
        } else if hours > 0 {
            format!("expires in {hours}h {mins}m")
        } else {
            format!("expires in {mins}m")
        })
    }
}

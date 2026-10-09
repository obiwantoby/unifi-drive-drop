//! Native client for UniFi Drive.
//!
//! * `models` — domain types, shared with the macOS app
//! * `api`    — HTTP client, endpoints verified against a live UNAS Pro console
//!
//! The endpoint-by-endpoint evidence lives in `spec/api.md`; anything marked ✅ there is
//! implemented here, and anything that was a guess is deliberately not implemented.

pub mod api;
pub mod models;

pub use api::{DriveClient, LiveClient};
pub use models::{DriveError, Expiration, FileEntry, Phase, Result, ShareItem, Usage};

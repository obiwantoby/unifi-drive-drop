//! Native client for UniFi Drive.
//!
//! * `models` — domain types, shared with the macOS app
//! * `api`    — HTTP client, endpoints verified against a live UNAS Pro console
//!
//! The normative contract lives in `spec/api.md`; how it was established, and what was
//! ruled out, lives in `spec/discovery.md`. Only routes verified against a live console
//! are implemented — the guesses this client originally made are deliberately absent.

pub mod api;
pub mod models;

pub use api::{DriveClient, LiveClient};
pub use models::{DriveError, Expiration, FileEntry, Phase, Result, ShareItem, Usage};

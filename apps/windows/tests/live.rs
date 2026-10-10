//! Live integration test against a real console.
//!
//! Opt-in and destructive-by-design, so it is `#[ignore]`d and refuses to run unless
//! `DRIVEDROP_LIVE=1` is set:
//!
//! ```sh
//! DRIVEDROP_HOST=https://192.0.2.10 DRIVEDROP_INSECURE=1 \
//! DRIVEDROP_USER=… DRIVEDROP_PASS=… DRIVEDROP_LIVE=1 \
//! cargo test --test live -- --ignored --nocapture
//! ```
//!
//! It only ever touches files it creates itself, named `drivedrop-selftest-*`, and removes
//! them again — including on failure, via `Cleanup`. This exists because the two worst bugs
//! found in this client were invisible to unit tests:
//!   * the storage body is top-level `{"pools":[…]}`, not wrapped in `{data:{…}}`; and
//!   * macOS names screenshots with U+202F, so a path rebuilt from the displayed name 404s.

use std::path::PathBuf;

use drivedrop::api::fold_invisible;
use drivedrop::{DriveClient, LiveClient};

/// Remove anything this run created, even when an assertion panics.
struct Cleanup {
    client: LiveClient,
    // RefCell so the run can keep borrowing `cleanup.client` immutably while still
    // registering new paths to undo.
    paths: std::cell::RefCell<Vec<String>>,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        for p in self.paths.borrow_mut().drain(..) {
            match self.client.delete_file(&p) {
                Ok(()) => println!("  cleanup: trashed {p}"),
                // Already gone, or never landed. Either way there is nothing to undo.
                Err(e) => println!("  cleanup: {p} -> {}", e.human()),
            }
        }
    }
}

fn live() -> Option<LiveClient> {
    if std::env::var("DRIVEDROP_LIVE").ok().as_deref() != Some("1") {
        println!("skipping: set DRIVEDROP_LIVE=1 to run against a real console");
        return None;
    }
    let host = std::env::var("DRIVEDROP_HOST").ok()?;
    let user = std::env::var("DRIVEDROP_USER").ok()?;
    let pass = std::env::var("DRIVEDROP_PASS").ok()?;
    let insecure = std::env::var("DRIVEDROP_INSECURE").map(|v| v == "1").unwrap_or(false);
    Some(LiveClient::new(&host, &user, &pass, insecure))
}

fn fixture(name: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!("drivedrop-selftest-{name}"));
    // 1.5 MiB: big enough to force three 512 KiB chunks, small enough to be polite.
    let bytes: Vec<u8> = (0..1_572_864).map(|i| (i % 251) as u8).collect();
    std::fs::write(&p, bytes).expect("write fixture");
    p
}

#[test]
#[ignore]
fn live_end_to_end() {
    let Some(client) = live() else { return };
    let cleanup = Cleanup { client, paths: std::cell::RefCell::new(Vec::new()) };
    // One client for the whole run: a login per assertion is how you trip the console's
    // login rate limit and get the account locked mid-test.
    let c = &cleanup.client;
    c.login().expect("login");

    // 1 -- rememberMe must still buy ~30 days. If this drops to 2 h the key was renamed.
    let exp = c.token_expire().expect("X-Token-Expire-Time header");
    let days = (exp - chrono::Utc::now()).num_hours() / 24;
    println!("  token lifetime: {days}d");
    assert!(days >= 25, "rememberMe regressed: token lives {days}d, expected ~30");

    // 2 -- usage must be non-zero. Zero means the envelope shape moved again.
    let u = c.usage().expect("usage");
    println!("  usage: {} / {}", u.used_bytes, u.total_bytes);
    assert!(u.total_bytes > 0, "storage pools parsed as empty — check the body shape");

    // 3 -- listing returns drive-qualified absolute paths.
    let root = c.browse("/").expect("browse root");
    assert!(!root.is_empty(), "root listing empty");
    assert!(
        root.iter().all(|e| e.path.starts_with("/mydrive") || e.path.starts_with("/shared")),
        "listing paths are not drive-qualified: {:?}",
        root.iter().map(|e| &e.path).collect::<Vec<_>>()
    );

    // 4 -- upload, and the asynchronous finalize actually producing an object.
    let tag = format!("{}-{}", std::process::id(), chrono::Utc::now().timestamp());
    let plain = fixture(&format!("{tag}.txt"));
    let item = c
        .upload(&plain, "/Public", &|_| {})
        .expect("upload should land the object");
    cleanup.paths.borrow_mut().push(item.file_id.clone());
    assert!(item.size > 0, "uploaded object reported size 0");
    println!("  uploaded {}", item.file_id);

    // 5 -- a share link becomes available, and points at drop.ui.com, not the console.
    let link = c.create_share(&item.file_id, drivedrop::Expiration::OneDay, None)
        .expect("create share");
    let url = link.share_url.clone().expect("link has no token");
    assert!(url.starts_with("https://drop.ui.com/"), "unexpected share host: {url}");
    assert!(c.list_links().expect("list links").iter().any(|l| l.id == link.id),
            "created link is missing from the links listing");
    println!("  shared {url}");

    // 6 -- the invisible-space class, end to end. Upload a name Finder would render as an
    // ordinary space and confirm the listing's own `path` is what makes it addressable.
    let narrow = format!("{tag}\u{202f}PM.txt");
    let odd = fixture(&narrow);
    let odd_item = c.upload(&odd, "/Public", &|_| {}).expect("upload narrow-nbsp file");
    cleanup.paths.borrow_mut().push(odd_item.file_id.clone());
    assert!(odd_item.file_id.contains('\u{202f}'), "server normalized the name away");
    let listed = c.browse("/Public").expect("browse Public");
    let typed_with_normal_space = odd_item.file_id.replace('\u{202f}', " ");
    assert_ne!(typed_with_normal_space, odd_item.file_id);
    assert!(
        listed.iter().any(|e| fold_invisible(&e.path) == fold_invisible(&typed_with_normal_space)),
        "folded matching failed for {:?}", odd_item.file_id
    );
    println!("  narrow-nbsp object addressable: {}", odd_item.file_id);

    // 7 -- link delete, then file delete, then confirm both are gone.
    c.delete_link(&link.id).expect("delete link");
    assert!(!c.list_links().expect("relist").iter().any(|l| l.id == link.id),
            "link survived deletion");
    c.delete_file(&item.file_id).expect("delete file");
    cleanup.paths.borrow_mut().retain(|p| p != &item.file_id);
    assert!(!c.browse("/Public").expect("browse").iter().any(|e| e.path == item.file_id),
            "file survived deletion");

    // 8 -- deleting a file twice must produce a clear error, not a panic.
    let again = c.delete_file(&item.file_id);
    assert!(again.is_err(), "double delete should not report success");
    println!("  double delete reported: {}", again.unwrap_err().human());

    println!("live end-to-end: PASSED");
}

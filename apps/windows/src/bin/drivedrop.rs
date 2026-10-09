//! Terminal front-end for the Drive client.
//!
//! The egui/Fluent GUI is not implemented yet, so this binary is what proves the API port
//! works end to end on Windows. It is also useful on its own: scripting uploads.
//!
//! ```text
//! set DRIVEDROP_HOST=192.168.1.10
//! set DRIVEDROP_USER=admin
//! set DRIVEDROP_PASS=secret
//! drivedrop ls /Public
//! drivedrop put .\invoice.pdf --dir /Public --share --expire 7d
//! ```

use std::path::PathBuf;
use std::process::ExitCode;

use drivedrop::models::{DriveError, Expiration};
use drivedrop::{DriveClient, LiveClient};

const USAGE: &str = "\
drivedrop — UniFi Drive from a terminal

  drivedrop login                      verify credentials and token lifetime
  drivedrop usage                      free / used capacity
  drivedrop ls [DIR]                   list a folder (default /Public)
  drivedrop links                      list share links
  drivedrop put FILE [--dir D]         upload (optionally --share, --expire 1h|1d|7d|30d)
  drivedrop share PATH [--expire E]    create a share link for a drive path
  drivedrop expire LINKID E            1h|1d|7d|30d|never
  drivedrop rm PATH                    move a file to the Drive trash
  drivedrop rm-link LINKID             delete a share link

Environment:
  DRIVEDROP_HOST   console address (required)
  DRIVEDROP_USER   username        (required)
  DRIVEDROP_PASS   password        (required)
  DRIVEDROP_INSECURE=1  accept the console's self-signed TLS certificate

Paths are personal-drive relative: /, /Public, /Archive/2026.";

struct Args {
    positional: Vec<String>,
    dir: String,
    share: bool,
    expire: Expiration,
}

fn parse_expire(v: &str) -> Option<Expiration> {
    Some(match v {
        "1h" | "hour" => Expiration::OneHour,
        "1d" | "day" => Expiration::OneDay,
        "7d" | "week" => Expiration::SevenDays,
        "30d" | "month" => Expiration::ThirtyDays,
        "never" | "off" | "-" => Expiration::Never,
        _ => return None,
    })
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || argv[0] == "help" || argv[0] == "--help" {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }

    let mut positional = Vec::new();
    let mut dir = "/Public".to_string();
    let mut share = false;
    let mut expire = Expiration::Never;

    let mut i = 0;
    while i < argv.len() {
        let a = &argv[i];
        match a.as_str() {
            "--dir" => {
                i += 1;
                dir = argv.get(i).cloned().unwrap_or_else(|| dir.clone());
            }
            "--share" => share = true,
            "--expire" => {
                i += 1;
                let raw = argv.get(i).cloned().unwrap_or_default();
                match parse_expire(&raw) {
                    Some(e) => expire = e,
                    None => return fail(&format!("bad --expire '{raw}' (use 1h|1d|7d|30d|never)")),
                }
            }
            _ => positional.push(a.clone()),
        }
        i += 1;
    }

    let cmd = positional.first().cloned().unwrap_or_default();
    let args = Args { positional: positional.clone(), dir, share, expire };

    let host = match std::env::var("DRIVEDROP_HOST") {
        Ok(h) if !h.is_empty() => h,
        _ => return fail("DRIVEDROP_HOST is not set"),
    };
    let user = std::env::var("DRIVEDROP_USER").unwrap_or_default();
    let pass = std::env::var("DRIVEDROP_PASS").unwrap_or_default();
    if user.is_empty() || pass.is_empty() {
        return fail("DRIVEDROP_USER / DRIVEDROP_PASS are not set");
    }
    let insecure = std::env::var("DRIVEDROP_INSECURE").map(|v| v == "1").unwrap_or(false);
    let client = LiveClient::new(&host, &user, &pass, insecure);

    // Wrapped in a closure so `?` inside the arms returns the inner Result rather than
    // trying to exit main with a DriveError.
    let run = || -> Result<(), DriveError> {
        match cmd.as_str() {
        "login" => {
            client.login()?;
            println!("signed in");
            if let Some(exp) = client.token_expire() {
                let secs = (exp - chrono::Utc::now()).num_seconds();
                println!("token valid for {}d {}h", secs / 86_400, (secs % 86_400) / 3_600);
            }
            Ok(())
        }
        "usage" => run_usage(&client),
        "ls" => run_ls(&client, positional_dir(&args)),
        "links" => run_links(&client),
        "put" => run_put(&client, &args),
        "share" => run_share(&client, &args),
        "expire" => {
            let id = args.positional.get(1).cloned().unwrap_or_default();
            let e = args
                .positional
                .get(2)
                .and_then(|s| parse_expire(s))
                .unwrap_or(Expiration::Never);
            client.set_expiration(&id, e).map(|l| println!("{}", l.share_url.unwrap_or_default()))
        }
        "rm" => {
            let p = args.positional.get(1).cloned().unwrap_or_default();
            client.delete_file(&drivedrop::api::qualified(&p)).map(|_| println!("moved to trash: {p}"))
        }
        "rm-link" => {
            let id = args.positional.get(1).cloned().unwrap_or_default();
            client.delete_link(&id).map(|_| println!("link deleted"))
        }
        other => Err(DriveError::Unsupported(format!("unknown command '{other}'"))),
        }
    };

    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => fail(&e.human()),
    }
}

/// `ls` with no argument defaults to /Public; `ls /` lists the drive root.
fn positional_dir(a: &Args) -> &str {
    a.positional.get(1).map(|s| s.as_str()).unwrap_or("/Public")
}

fn run_usage(c: &dyn DriveClient) -> Result<(), DriveError> {
    let u = c.usage()?;
    println!(
        "{} used of {} — {} free ({:.0}% used)",
        drivedrop::models::fmt::bytes(u.used_bytes),
        drivedrop::models::fmt::bytes(u.total_bytes),
        drivedrop::models::fmt::bytes(u.free_bytes()),
        if u.total_bytes > 0 { u.used_bytes as f64 * 100.0 / u.total_bytes as f64 } else { 0.0 }
    );
    Ok(())
}

fn run_ls(c: &dyn DriveClient, dir: &str) -> Result<(), DriveError> {
    for e in c.browse(dir)? {
        let kind = if e.is_dir { "d" } else { "-" };
        println!(
            "{kind}  {:>10}  {}",
            if e.is_dir { "-".to_string() } else { drivedrop::models::fmt::bytes(e.size) },
            e.name
        );
    }
    Ok(())
}

fn run_links(c: &dyn DriveClient) -> Result<(), DriveError> {
    for l in c.list_links()? {
        let when = drivedrop::models::fmt::countdown(l.expires_at).unwrap_or_else(|| "no expiry".into());
        println!("{}  {:<28}  {}", l.id, l.name, when);
        if let Some(u) = &l.share_url {
            println!("      {u}");
        }
    }
    Ok(())
}

fn run_put(c: &dyn DriveClient, a: &Args) -> Result<(), DriveError> {
    let raw = a.positional.get(1).cloned().ok_or_else(|| {
        DriveError::Unsupported("put needs a file".into())
    })?;
    let path = PathBuf::from(&raw);
    if !path.exists() {
        return Err(DriveError::Unsupported(format!("no such file: {raw}")));
    }
    // Print progress on one line; carriage return so it does not scroll.
    let bar = |p: f32| {
        let done = (p * 30.0) as usize;
        print!("\r  [{}{}] {:>4.0}%", "#".repeat(done), ".".repeat(30 - done), p * 100.0);
        use std::io::Write;
        let _ = std::io::stdout().flush();
    };
    let item = c.upload(path.as_path(), &a.dir, &bar)?;
    println!("\nuploaded {} -> {}", drivedrop::models::fmt::bytes(item.size), item.file_id);
    if a.share {
        let link = c.create_share(&item.file_id, a.expire, None)?;
        println!("share: {}", link.share_url.unwrap_or_default());
    }
    Ok(())
}

fn run_share(c: &dyn DriveClient, a: &Args) -> Result<(), DriveError> {
    let raw = a.positional.get(1).cloned().ok_or_else(|| {
        DriveError::Unsupported("share needs a path".into())
    })?;
    let q = if raw.starts_with("/mydrive") || raw.starts_with("/shared") {
        raw
    } else {
        drivedrop::api::qualified(&raw)
    };
    let link = c.create_share(&q, a.expire, None)?;
    println!("{}", link.share_url.unwrap_or_default());
    Ok(())
}

fn fail(msg: &str) -> ExitCode {
    eprintln!("error: {msg}");
    ExitCode::FAILURE
}

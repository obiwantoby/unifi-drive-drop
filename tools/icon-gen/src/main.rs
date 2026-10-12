//! Builds `apps/windows-ui/icons/drivedrop.ico` from the master PNG.
//!
//!     cargo run --manifest-path tools/icon-gen/Cargo.toml -- \
//!         apps/windows-ui/icons/app-1024.png apps/windows-ui/icons/drivedrop.ico
//!
//! Why a generator and not a committed blob: the .ico has to carry every size Windows may ask
//! for (16 in the tray, 24 on a 150% tray, 32/48 in the taskbar and Alt-Tab, 256 for large
//! icons), and hand-made .ico files routinely ship the wrong set — then the tray shows a
//! blurry downscale of the 48 px entry and the taskbar shows something else again.
//!
//! The master PNG comes from the macOS icon: `apps/macos/resources/AppIcon.icns` is a plain
//! container of PNG payloads, and the largest entry (1024) is the only one whose declared size
//! matches its pixels. The smaller entries are mislabelled in that file — `ic09` is declared
//! 32×32 and holds a 512×512 image, `ic12` is declared 16×16 and holds 64×64 — so downscaling
//! them "for free" produces the wrong thing. Always resample from the master.

use std::fs::File;
use std::io::BufWriter;
use std::path::PathBuf;

use image::{
    codecs::ico::{IcoEncoder, IcoFrame},
    imageops::FilterType,
    ExtendedColorType,
};

/// Every size a Windows .ico should contain. Missing entries make Windows resample whatever it
/// has, which is how an icon ends up soft in one place and crisp in another.
const SIZES: [u32; 7] = [16, 24, 32, 48, 64, 128, 256];

/// Sizes also written out as standalone PNGs, because Slint embeds a PNG rather than an .ico:
/// the tray wants a real 32 px bitmap (Windows scales tray icons poorly), the window/taskbar
/// icon uses 64 px and scales cleanly from that.
const PNG_SIZES: [u32; 2] = [32, 64];

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let src = args.next().map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from("apps/windows-ui/icons").join("app-1024.png")
    });
    let dst = args.next().map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from("apps/windows-ui/icons").join("drivedrop.ico")
    });

    let master = image::open(&src)?;
    let (w, h) = (master.width(), master.height());
    if w != h {
        return Err(format!("{} is {}x{}, the icon must be square", src.display(), w, h).into());
    }
    if w < *SIZES.last().unwrap() {
        return Err(format!("{} is only {}px; upscaling into a .ico looks terrible", src.display(), w).into());
    }

    // Lanczos3, because the tray renders at 16 px where a box filter loses the arrow's corners.
    // Each entry is stored as PNG (Vista+ reads those) rather than BMP: smaller file, and the
    // 8-bit alpha survives without the AND-mask dance.
    let mut frames = Vec::new();
    for &s in SIZES.iter() {
        let rgba = master.resize_exact(s, s, FilterType::Lanczos3).to_rgba8();
        frames.push(IcoFrame::as_png(rgba.as_raw(), s, s, ExtendedColorType::Rgba8)?);
    }

    if let Some(dir) = dst.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut out = BufWriter::new(File::create(&dst)?);
    IcoEncoder::new(&mut out).encode_images(&frames)?;

    let dir = dst.parent().unwrap_or_else(|| std::path::Path::new("."));
    for &s in PNG_SIZES.iter() {
        let png = dir.join(format!("app-{s}.png"));
        master
            .resize_exact(s, s, FilterType::Lanczos3)
            .to_rgba8()
            .save(&png)?;
    }

    println!("{} <- {} at {:?} (+ {:?} png)", dst.display(), src.display(), SIZES, PNG_SIZES);
    Ok(())
}

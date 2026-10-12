fn main() {
    // Style is fixed at compile time rather than left to the platform default: on macOS Slint
    // would otherwise pick cupertino, and the point is to see the same Fluent 2 controls during
    // development that ship on Windows.
    let config = slint_build::CompilerConfiguration::new().with_style("fluent".into());
    if let Err(e) = slint_build::compile_with_config("ui/main.slint", config) {
        panic!("failed to compile ui/main.slint: {e}");
    }

    #[cfg(windows)]
    {
        let mut r = winresource::WindowsResource::new();
        // The .ico is generated, not hand-saved: `cargo run --manifest-path
        // tools/icon-gen/Cargo.toml -- apps/windows-ui/icons/app-1024.png \
        //   apps/windows-ui/icons/drivedrop.ico`. It is what the taskbar, Alt-Tab and the tray
        // all show; without it Windows draws the generic app icon.
        r.set_icon("icons/drivedrop.ico");
        // PerMonitorV2 wins over the legacy flag where the OS supports it; both are declared so
        // older Windows 10 still gets system DPI awareness. Without this, rustc's default
        // manifest is system-aware only and Windows bitmap-stretches the window when it moves to
        // a display with a different scale factor — which is the blur people blame on fonts.
        r.set_manifest(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>"#,
        );
        if let Err(e) = r.compile() {
            println!("cargo:warning=could not embed the Windows manifest: {e}");
        }
    }
}

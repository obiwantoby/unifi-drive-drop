# Capture what is actually ON SCREEN at the window's rectangle.
#
#   powershell -File tools/shot.ps1 -Out shot.png [-ProcessName drivedrop-ui]
#
# PrintWindow is deliberately NOT used: it asks the window to repaint itself, and a GPU-backed
# window with a DWM backdrop (acrylic/Mica) answers that with a blank surface -- the blur lives in
# the compositor, not in the window. A screen grab is what the user sees, including the acrylic.
param(
    [string]$Out = "shot.png",
    [string]$ProcessName = "drivedrop-ui"
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  // The capture process MUST be as DPI-aware as the app, or everything below is computed in the
  // virtualised (divided-by-scale) coordinate space and a BitBlt of a GPU-composited window comes
  // back as whatever is behind it -- which looks exactly like an app that renders nothing.
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
if (-not [Win]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
    Write-Warning "SetProcessDpiAwarenessContext failed (already set?) -- coordinates may be virtualised"
}

$hwnd = [IntPtr]::Zero
foreach ($p in Get-Process $ProcessName -ErrorAction SilentlyContinue) {
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $p.MainWindowHandle; break }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "no window for '$ProcessName'"; exit 1 }

if ([Win]::IsIconic($hwnd)) { [void][Win]::ShowWindow($hwnd, 9) }  # SW_RESTORE
[void][Win]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 400

$r = New-Object Win+RECT
[void][Win]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { Write-Error "degenerate window rect ($w x $h)"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g.Dispose()

$full = Join-Path (Get-Location).Path $Out
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $full ($w x $h at $($r.Left),$($r.Top))"

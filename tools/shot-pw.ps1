# Capture a window by asking it to paint itself (PrintWindow), not by grabbing the screen.
#
#   powershell -File tools/shot-pw.ps1 -Out shot.png [-ProcessName drivedrop-ui]
#
# Two capture paths exist in tools/ for a reason:
#   * shot.ps1 (screen grab) is what the user sees, but on this machine GDI CopyFromScreen comes
#     back with only the wallpaper - it does not include DWM-composited windows at all, so it
#     cannot be trusted as evidence that an app renders nothing.
#   * this one asks the window to repaint into a DC. PW_RENDERFULLCONTENT (2) is what makes GPU
#     backed windows paint. DWM backdrops (acrylic, Mica) are NOT part of the window's own paint,
#     so they show up here as a flat fill - use the screen grab to judge the blur, this to judge
#     the layout.
#
# The process must be DPI aware or the rectangle it captures is the virtualised one.
param(
    [string]$Out = "shot.png",
    [string]$ProcessName = "drivedrop-ui"
)

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
[void][Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

$hwnd = [IntPtr]::Zero
foreach ($p in Get-Process $ProcessName -ErrorAction SilentlyContinue) {
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $p.MainWindowHandle; break }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "no window for '$ProcessName'"; exit 1 }
if ([Win]::IsIconic($hwnd)) { [void][Win]::ShowWindow($hwnd, 9) }

$r = New-Object Win+RECT
[void][Win]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { Write-Error "degenerate window rect"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Win]::PrintWindow($hwnd, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
if (-not $ok) { Write-Warning "PrintWindow returned false" }

$full = Join-Path (Get-Location).Path $Out
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote $full ($w x $h)"

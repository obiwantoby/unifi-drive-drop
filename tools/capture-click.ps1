# Click a point measured on a window capture, in capture pixels.
#
# UI Automation's rectangles for Slint popup contents are stale: it reported the "Use demo data"
# box 200px away from where it is drawn, because the window grew when the popup opened and the
# cached rect did not follow. A capture is ground truth - it is what the user sees - so this maps
# image pixels through GetWindowRect (which includes the invisible resize border and shadow, the
# same rect the capture was cropped to).
#
#   tools/capture-click.ps1 -X 229 -Y 445            # offset inside the capture
#   tools/capture-click.ps1 -X 229 -Y 445 -Right     # right button
param(
    [Parameter(Mandatory)][int]$X,
    [Parameter(Mandatory)][int]$Y,
    [string]$Process = "drivedrop-ui",
    [switch]$Right,
    [switch]$Middle
)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CapClick {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool join);
  public static void Raise(IntPtr h) {
    // SetForegroundWindow is refused unless we are already the foreground process. Attaching to the
    // current foreground thread's input queue for the duration of the call is the documented way
    // round, and without it every synthetic click is spent on activation instead of the control.
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return;
    uint ft = GetWindowThreadProcessId(fg, IntPtr.Zero);
    uint ct = GetCurrentThreadId();
    AttachThreadInput(ct, ft, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    AttachThreadInput(ct, ft, false);
  }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@ | Out-Null
[CapClick]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

# The Win32 window title is not the Slint title, so find by process and take the largest visible
# top-level (the popup Slint draws is inside the main window; the tray helper is 22px).
$script:target = [IntPtr]::Zero
$script:best = 0
$procs = @(Get-Process -Name $Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$cb = [CapClick+EnumProc] {
    param($h, $l)
    if (-not [CapClick]::IsWindowVisible($h)) { return $true }
    $wpid = 0
    [CapClick]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -notin $procs) { return $true }
    $rr = New-Object CapClick+RECT
    if (-not [CapClick]::GetWindowRect($h, [ref]$rr)) { return $true }
    $area = ($rr.R - $rr.L) * ($rr.B - $rr.T)
    if ($area -gt $script:best) { $script:best = $area; $script:target = $h }
    return $true
}
[CapClick]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if ($target -eq [IntPtr]::Zero) { Write-Error "no visible window for process '$Process'"; exit 1 }
$h = $target
$r = New-Object CapClick+RECT
[CapClick]::GetWindowRect($h, [ref]$r) | Out-Null
$sx = $r.L + $X
$sy = $r.T + $Y
Write-Host "window $($r.R - $r.L)x$($r.B - $r.T) at $($r.L),$($r.T) -> click $sx,$sy"

# A click that arrives while another window owns the foreground is spent activating this one and
# never reaches the control - which is why some earlier synthetic clicks looked like dead UI.
# Bring the window forward first, and only then click.
[CapClick]::Raise($h)
Start-Sleep -Milliseconds 250
[CapClick]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 120
if ([CapClick]::GetForegroundWindow() -ne $h) { Write-Warning "window is still not foreground" }
if ($Right)  { [CapClick]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [CapClick]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero) }
elseif ($Middle) { [CapClick]::mouse_event(0x0020, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [CapClick]::mouse_event(0x0040, 0, 0, 0, [IntPtr]::Zero) }
else { [CapClick]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [CapClick]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero) }
Write-Host "done"

# Right-click at a point inside the app window, so the context menu can be verified rather than
# assumed. UI Automation's InvokePattern only does left-click, which is why click.ps1 cannot do this.
#
#   tools/rightclick.ps1 -X 300 -Y 320          # window-relative logical pixels
param(
    [int]$X = 200,
    [int]$Y = 260,
    [string]$Process = "drivedrop-ui"
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RC {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  public struct P { public int X; public int Y; }
  public const uint RIGHT_DOWN = 0x0008, RIGHT_UP = 0x0010;
}
"@ | Out-Null
# Without this the 4K desktop is reported at 2560x1440 and the click lands somewhere else entirely.
[RC]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$proc = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $Process window"; exit 1 }
$el = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
$r = $el.Current.BoundingRectangle

# BoundingRectangle is in DIPs; SetCursorPos wants physical pixels. Recover the factor by moving
# the cursor to a known DIP-ish point and reading it back, rather than hardcoding 150%.
$probe = 400
$cur = New-Object RC+P
[RC]::SetCursorPos($probe, $probe) | Out-Null
[RC]::GetCursorPos([ref]$cur) | Out-Null
$factor = [math]::Round([double]$cur.X / $probe, 3)
if ($factor -lt 0.9 -or $factor -gt 4) { $factor = 1.0 }

$px = [int]($r.X + $X * $factor)
$py = [int]($r.Y + $Y * $factor)
Write-Host ("window {0}x{1} at {2},{3}; factor {4}; right-clicking physical {5},{6}" -f `
    [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y, $factor, $px, $py)

[RC]::SetCursorPos($px, $py) | Out-Null
Start-Sleep -Milliseconds 120
[RC]::mouse_event([RC]::RIGHT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[RC]::mouse_event([RC]::RIGHT_UP, 0, 0, 0, [UIntPtr]::Zero)
Write-Host "done"

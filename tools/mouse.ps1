# Click at a point inside the app window with a real mouse event.
#
# UI Automation's InvokePattern reports success on Slint checkboxes without toggling them, so a
# UIA-driven click can prove nothing about a control that needs a press/release at its coordinates.
# This sends the real thing.
#
#   tools/mouse.ps1 -X 300 -Y 300            # left click
#   tools/mouse.ps1 -X 300 -Y 300 -Right     # right click
param(
    [int]$X = 200,
    [int]$Y = 260,
    [switch]$Right,
    [string]$Process = "drivedrop-ui"
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MouseSim {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  public struct P { public int X; public int Y; }
  public const uint LEFT_DOWN = 0x0002, LEFT_UP = 0x0004, RIGHT_DOWN = 0x0008, RIGHT_UP = 0x0010;
}
"@ | Out-Null
# Without this the 4K desktop is reported as 2560x1440 and every coordinate is wrong.
[MouseSim]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$proc = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $Process window"; exit 1 }
$el = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
$r = $el.Current.BoundingRectangle          # DIPs

# Recover the DPI factor by moving the cursor somewhere known and reading it back in physicals.
$probe = 400
$cur = New-Object MouseSim+P
[MouseSim]::SetCursorPos($probe, $probe) | Out-Null
[MouseSim]::GetCursorPos([ref]$cur) | Out-Null
$factor = [math]::Round([double]$cur.X / $probe, 3)
if ($factor -lt 0.9 -or $factor -gt 4) { $factor = 1.0 }

$px = [int]($r.X + $X * $factor)
$py = [int]($r.Y + $Y * $factor)
$which = if ($Right) { "right" } else { "left" }
Write-Host ("window {0}x{1} at {2},{3}; dpi {4}; {5}-click physical {6},{7}" -f `
    [int]$r.Width, [int]$r.Height, [int]$r.X, [int]$r.Y, $factor, $which, $px, $py)

[MouseSim]::SetCursorPos($px, $py) | Out-Null
Start-Sleep -Milliseconds 120
if ($Right) {
    [MouseSim]::mouse_event([MouseSim]::RIGHT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseSim]::mouse_event([MouseSim]::RIGHT_UP, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [MouseSim]::mouse_event([MouseSim]::LEFT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MouseSim]::mouse_event([MouseSim]::LEFT_UP, 0, 0, 0, [UIntPtr]::Zero)
}
Write-Host "done"

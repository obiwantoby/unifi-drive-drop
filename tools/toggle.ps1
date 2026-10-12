# Toggle a checkbox by name, located through UI Automation rather than guessed coordinates.
#
# Two attempts, because Slint exposes both patterns and neither is sufficient on its own:
#   1. TogglePattern.Toggle() -- the "correct" way; observed to do nothing on a Slint CheckBox.
#   2. A real press/release at the element's own BoundingRectangle centre -- works, and self-locating
#      so it does not depend on getting the DPI factor right (UIA reports physicals to a
#      PerMonitorV2-aware client, so multiplying by 1.5 sends the click somewhere else).
#
#   tools/toggle.ps1 -Name "Start with Windows"
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Process = "drivedrop-ui"
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MouseTap {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  public const uint LEFT_DOWN = 0x0002, LEFT_UP = 0x0004;
}
"@ | Out-Null
[MouseTap]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$proc = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $Process window"; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)

# Popups are separate top levels, so search the desktop for the element by name as well.
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
$el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
if (-not $el) {
    $desk = [System.Windows.Automation.AutomationElement]::RootElement
    $el = $desk.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    if (-not $el) { $el = $desk.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond) }
}
if (-not $el) { Write-Error "no element named '$Name'"; exit 1 }

$r = $el.Current.BoundingRectangle
Write-Host ("found '{0}' at {1},{2} {3}x{4}" -f $Name, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)

$tog = $null
if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tog)) {
    $state = ([System.Windows.Automation.TogglePattern]$tog).ToggleState
    Write-Host "TogglePattern present, state=$state; calling Toggle()"
    try { ([System.Windows.Automation.TogglePattern]$tog).Toggle(); Start-Sleep -Milliseconds 400 } catch { Write-Host "toggle threw: $_" }
    $after = ([System.Windows.Automation.TogglePattern]$tog).ToggleState
    if ($after -ne $state) { Write-Host "toggled by UIA ($state -> $after)"; exit 0 }
    Write-Host "UIA Toggle did not change the state ($state -> $after); falling back to a real click"
} else {
    Write-Host "no TogglePattern; using a real click"
}

# The element rect spans the label as well as the box; aim at the box.
$cx = [int]($r.X + 14)
$cy = [int]($r.Y + $r.Height / 2)
[MouseTap]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 120
[MouseTap]::mouse_event([MouseTap]::LEFT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[MouseTap]::mouse_event([MouseTap]::LEFT_UP, 0, 0, 0, [UIntPtr]::Zero)
Write-Host "clicked $cx,$cy"

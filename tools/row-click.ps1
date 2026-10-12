# Click a link row, located by its accessible name.
#
# The rows are Slint Rectangles with a TouchArea, so they carry no UIA name unless the .slint sets
# `accessible-label`. That is why this exists: a control you cannot address cannot be tested, and
# the context menu was "verified" only in the sense that nothing complained about it.
#
#   tools/row-click.ps1                      right-click the first link row
#   tools/row-click.ps1 -Index 2 -Button left
param(
    [int]$Index = 0,
    [ValidateSet("right", "left")][string]$Button = "right",
    [string]$Process = "drivedrop-ui"
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class TapRow {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  public const uint RIGHT_DOWN = 0x0008, RIGHT_UP = 0x0010, LEFT_DOWN = 0x0002, LEFT_UP = 0x0004;
}
"@ | Out-Null
[TapRow]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$proc = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $Process window"; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
$wr = $root.Current.BoundingRectangle
Write-Host ("window at {0},{1} {2}x{3}" -f [int]$wr.X, [int]$wr.Y, [int]$wr.Width, [int]$wr.Height)

$items = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ControlType.ProgrammaticName -match 'ListItem|DataItem' })

if ($items.Count -le $Index) {
    Write-Host "no link row at index $Index (found $($items.Count)); is a folder with links showing?"
    exit 1
}

$el = $items[$Index]
$r = $el.Current.BoundingRectangle
Write-Host ("row {0} '{1}' at {2},{3} {4}x{5}" -f $Index, $el.Current.Name, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
if ($r.X -lt $wr.X -or $r.X -gt ($wr.X + $wr.Width)) {
    Write-Host "NOTE: the row's rectangle is outside the window rectangle - coordinates disagree"
}

# Not the exact centre: at the bottom edge the press can land outside the row's TouchArea, and the
# right-click silently does nothing. (This line was eaten twice by `perl -pi` interpolating $r and
# $cx as perl variables — if a tool blanks your `$foo` assignments, that is why.)
$cx = [int]($r.X + $r.Width * 0.35)
$cy = [int]($r.Y + $r.Height * 0.4)
[TapRow]::SetCursorPos($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 150
if ($Button -eq "right") {
    [TapRow]::mouse_event([TapRow]::RIGHT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [TapRow]::mouse_event([TapRow]::LEFT_DOWN, 0, 0, 0, [UIntPtr]::Zero)
}
Start-Sleep -Milliseconds 60
if ($Button -eq "right") {
    [TapRow]::mouse_event([TapRow]::RIGHT_UP, 0, 0, 0, [UIntPtr]::Zero)
} else {
    [TapRow]::mouse_event([TapRow]::LEFT_UP, 0, 0, 0, [UIntPtr]::Zero)
}
Write-Host "$Button-clicked $cx,$cy"

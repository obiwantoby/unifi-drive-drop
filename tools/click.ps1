# Drive the app from outside: press a button by name, then screenshot.
#
#   powershell -File tools/click.ps1 -Name Connect
#
# UI Automation reaches the Slint tree because AccessKit is wired into the winit backend. This is
# how the demo path gets exercised end to end without a console and without a hand on the mouse.
param(
    [string]$Name = "Connect",
    [string]$ProcessName = "drivedrop-ui"
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;using System.Runtime.InteropServices;
public class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c); }
"@
[void][Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4))

$pid2 = (Get-Process $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if (-not $pid2) { Write-Error "no $ProcessName process"; exit 1 }

$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pid2)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { Write-Error "no window for pid $pid2"; exit 1 }

# Button, and also anything that supports Invoke with a matching name (Slint exposes Fluent
# buttons as control type Button; Text/CheckBox come out differently).
$nameCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
$el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
if (-not $el) {
    Write-Output "NOT FOUND: '$Name'. Names present:"
    foreach ($e in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        $n = $e.Current.Name
        if ($n) { "  - $n" }
    }
    exit 2
}

$invoke = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$invoke.Invoke()
Write-Output "invoked '$Name'"

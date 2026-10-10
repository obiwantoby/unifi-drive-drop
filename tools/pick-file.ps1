# Drive the native Windows file picker that rfd opens, so "upload a file" can be tested end to end.
#
#   tools/pick-file.ps1 -Path C:\path\to\file.txt
#
# Two things this learned the hard way:
#   - The dialog holds several Edit controls (breadcrumb, search, filename). The first one UIA
#     returns is the search box, so SetValue writes into the wrong field and the dialog just sits
#     there with an empty name. The filename field has focus by default, so raising the dialog and
#     typing is both simpler and correct.
#   - Keys only reach a dialog that owns the foreground, and SetForegroundWindow is refused unless
#     we attach to the current foreground thread's input queue.
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$TimeoutSec = 20
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PickWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool join);
  public static void Raise(IntPtr h) {
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return;
    uint ft = GetWindowThreadProcessId(fg, IntPtr.Zero);
    uint ct = GetCurrentThreadId();
    AttachThreadInput(ct, ft, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    AttachThreadInput(ct, ft, false);
  }
}
"@ | Out-Null
[PickWin]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dlg = $null

while ($null -eq $dlg -and (Get-Date) -lt $deadline) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, "#32770")
    $dlg = $AE::RootElement.FindFirst($Scope::Children, $cond)
    if ($null -eq $dlg) { Start-Sleep -Milliseconds 250 }
}
if ($null -eq $dlg) { Write-Error "no file dialog appeared within $TimeoutSec s"; exit 1 }
Write-Host "dialog: '$($dlg.Current.Name)'"

[PickWin]::Raise([IntPtr]$dlg.Current.NativeWindowHandle)
Start-Sleep -Milliseconds 350

# SendKeys reads braces, parens and +^%~ as keystroke syntax, so a path containing them has to be
# escaped or something else gets typed.
$e = $Path.Replace('{', '{{}').Replace('}', '{}}').Replace('(', '{(}').Replace(')', '{)}}')
$e = $e.Replace('+', '{+}').Replace('^', '{^}').Replace('%', '{%}').Replace('~', '{~}')
[System.Windows.Forms.SendKeys]::SendWait($e)
Start-Sleep -Milliseconds 250
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Write-Host "typed the path and pressed Enter"

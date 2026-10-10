# Capture EVERY top-level window the app owns, not just the main one.
#
# Slint's PopupWindow is a real top level on Windows, so PrintWindow on MainWindowHandle captures
# the window and misses the popup entirely — which is exactly how a context menu can look broken
# ("nothing appeared") when it is open and fine, just in a window nobody photographed.
#
#   powershell -File tools/shot-all.ps1 -OutPrefix shot
#   -> shot-0-main.png, shot-1-popup.png ...
param(
    [string]$OutPrefix = "shot",
    [string]$ProcessName = "drivedrop-ui"
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class WinAll {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static List<IntPtr> ForProcess(uint target) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target && IsWindowVisible(h)) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
"@
[void][WinAll]::SetProcessDpiAwarenessContext([IntPtr](-4))   # PER_MONITOR_AWARE_V2

$procs = Get-Process $ProcessName -ErrorAction SilentlyContinue
if (-not $procs) { Write-Error "no $ProcessName process"; exit 1 }
$pid_ = $procs[0].Id
$hwnds = [WinAll]::ForProcess($pid_)
Write-Host "$($hwnds.Count) visible top-level window(s) for pid $pid_"

$i = 0
foreach ($h in $hwnds) {
    $r = New-Object WinAll+RECT
    [void][WinAll]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -le 1 -or $ht -le 1) { $i++; continue }

    $cls = New-Object System.Text.StringBuilder 256
    [void][WinAll]::GetClassNameW($h, $cls, 256)
    $title = New-Object System.Text.StringBuilder 256
    [void][WinAll]::GetWindowTextW($h, $title, 256)

    $bmp = New-Object System.Drawing.Bitmap($w, $ht)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    # PW_RENDERFULLCONTENT = 2: without it a Direct3D/GL surface paints nothing.
    [void][WinAll]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()

    $name = "{0}-{1}.png" -f $OutPrefix, $i
    $bmp.Save($name, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  {0}  {1}x{2}  class={3} title='{4}'" -f $name, $w, $ht, $cls.ToString(), $title.ToString())
    $i++
}

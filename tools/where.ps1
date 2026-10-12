# Diagnostic: is the window actually where it says it is, and what is on screen there?
param([string]$ProcessName = "drivedrop-ui")

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct PT { public int X; public int Y; }
public class W {
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr m, out MI i);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MI { public int cb; public RECT rcMonitor; public RECT rcWork; public uint flags; }
}
"@

foreach ($p in Get-Process $ProcessName -ErrorAction SilentlyContinue) {
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { continue }
    $r = New-Object W+RECT
    [void][W]::GetWindowRect($h, [ref]$r)
    $cx = [int](($r.Left + $r.Right) / 2)
    $cy = [int](($r.Top + $r.Bottom) / 2)

    $pt = New-Object PT
    $pt.X = $cx; $pt.Y = $cy
    $at = [W]::WindowFromPoint($pt)
    $root = [W]::GetAncestor($at, 2)   # GA_ROOT

    $mon = [W]::MonitorFromWindow($h, 0)
    $mi = New-Object W+MI
    $mi.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    [void][W]::GetMonitorInfo($mon, [ref]$mi)

    "hwnd            = $h"
    "rect            = $($r.Left),$($r.Top) - $($r.Right),$($r.Bottom)  ($($r.Right-$r.Left) x $($r.Bottom-$r.Top))"
    "dpi             = $([W]::GetDpiForWindow($h))  iconic=$([W]::IsIconic($h))"
    "monitor         = $($mi.rcMonitor.Left),$($mi.rcMonitor.Top) - $($mi.rcMonitor.Right),$($mi.rcMonitor.Bottom)"
    "WindowFromPoint = $at  root=$root  is-ours=$($root -eq $h)"

    $bmp = New-Object System.Drawing.Bitmap(80, 80)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($cx - 40, $cy - 40, 0, 0, (New-Object System.Drawing.Size(80, 80)))
    $g.Dispose()
    $c = $bmp.GetPixel(40, 40)
    $e = $bmp.GetPixel(5, 5)
    "pixel center    = R$($c.R) G$($c.G) B$($c.B) A$($c.A)"
    "pixel corner    = R$($e.R) G$($e.G) B$($e.B) A$($e.A)"
    $bmp.Dispose()
}

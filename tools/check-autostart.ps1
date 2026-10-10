# Read back the autostart registry value and say whether it is actually launchable.
#
# The first implementation wrote the command as UTF-8 into a REG_SZ (which is UTF-16LE). The write
# succeeded, the checkbox stayed ticked, and the value was garbage -- every check that only asks
# "did the write return OK?" passes on that. So this asks the only question that matters: is what
# the loader will run a real path to a real exe?
#
#   tools/check-autostart.ps1            read and validate
#   tools/check-autostart.ps1 -Clear     remove the value (leave the machine as found)
param([switch]$Clear)

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Clear) {
    Remove-ItemProperty -Path $key -Name DriveDrop -ErrorAction SilentlyContinue
    Write-Host 'removed DriveDrop from the Run key'
    exit 0
}

$v = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).DriveDrop
if (-not $v) { Write-Host 'autostart: not registered'; exit 0 }

# A mangled UTF-8-as-UTF-16 value shows up as non-printable or replacement characters.
if ($v -match '[^\x20-\x7E"]') {
    Write-Host "autostart: VALUE IS CORRUPT (non-ASCII bytes) -- the loader cannot run this"
    Write-Host "           raw: $([System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($v)).Substring(0, [Math]::Min(60, $v.Length)))"
    exit 1
}

# The value is a command line: "C:\path\drivedrop.exe" --hidden
# PowerShell 5.1 cannot assign from a bare `if`; it needs the subexpression.
$exe = $(if ($v -match '^"([^"]+)"') { $Matches[1] } else { ($v -split '\s+--')[0] })
$hidden = $v -match '--hidden'

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "autostart: registered but the exe is not there: $exe"
    exit 1
}
Write-Host "autostart: OK"
Write-Host "           exe     : $exe"
Write-Host "           starts  : $(if ($hidden) { 'hidden (straight to the tray)' } else { 'with a window' })"
if (-not $hidden) { Write-Host "           note    : a tray app that opens a window on every login is the wrong default" }

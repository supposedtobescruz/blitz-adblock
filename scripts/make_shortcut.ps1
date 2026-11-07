# Creates a desktop shortcut that launches Blitz with the ad-blocking PAC.
#
# The shortcut runs launch_noads.ps1 with a hidden window, because the PAC URL is
# a ~5.7k character data: URL and does not fit in a .lnk Arguments field.
param(
    [string]$Base = $PSScriptRoot,
    [string]$Name = 'Blitz (no ads)'
)

$ErrorActionPreference = 'Stop'

$blitzExe = Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe'
$launcher = Join-Path $Base 'launch_noads.ps1'
if (-not (Test-Path $launcher)) {
    Write-Error "launcher missing: $launcher"
    exit 1
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop ($Name + '.lnk')

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '"'
$shortcut.WorkingDirectory = Split-Path $blitzExe -Parent
if (Test-Path $blitzExe) {
    $shortcut.IconLocation = "$blitzExe,0"
}
$shortcut.Description = 'Blitz with ad domains routed to a dead proxy (Blitz process only)'
$shortcut.Save()

Write-Host "shortcut created: $lnk"

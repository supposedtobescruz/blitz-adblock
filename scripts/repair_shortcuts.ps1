# Silently checks the Blitz launchers and restores the launcher wiring when a
# Blitz update rewrote them. Only touches the three known icons and the autostart
# Run value; backups are appended to build\shortcut-backup.txt / autostart-backup.txt.
# Exit code is always 0 unless an unexpected error occurs.
param(
    [string]$Base = $PSScriptRoot
)

$ErrorActionPreference = 'SilentlyContinue'

$buildDir = Join-Path $Base '..\build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$launcher = Join-Path $Base 'launch_noads.ps1'
if (-not (Test-Path $launcher)) { exit 0 }

$blitzExe = Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launchArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '"'

$shortcutBackup = Join-Path $buildDir 'shortcut-backup.txt'
$autostartBackup = Join-Path $buildDir 'autostart-backup.txt'

function Repair-Shortcut([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    if ($shortcut.TargetPath -like '*Blitz.exe' -and $shortcut.Arguments -notlike '*launch_noads.ps1*') {
        "$Path`t$($shortcut.TargetPath)`t$($shortcut.Arguments)" | Add-Content -Path $shortcutBackup -Encoding UTF8
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $launchArgs
        $shortcut.WorkingDirectory = Split-Path $blitzExe -Parent
        if (Test-Path $blitzExe) { $shortcut.IconLocation = "$blitzExe,0" }
        $shortcut.Description = 'Blitz with ad domains routed to a dead proxy (Blitz process only)'
        $shortcut.Save()
        Write-Host "repaired: $Path"
    }
}

$userProfile = [Environment]::GetFolderPath('UserProfile')
$candidates = @(
    (Join-Path $env:USERPROFILE 'Desktop\Blitz.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Blitz.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Blitz.lnk')
)
foreach ($c in $candidates) { Repair-Shortcut $c }

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$properties = Get-ItemProperty -Path $runKey
if ($properties) {
    foreach ($property in $properties.PSObject.Properties) {
        if ($property.Name -like 'PS*') { continue }
        $value = [string]$property.Value
        if ($value -notlike '*Blitz.exe*') { continue }
        if ($value -like '*launch_noads.ps1*') { continue }
        "$($property.Name)`t$value" | Add-Content -Path $autostartBackup -Encoding UTF8
        $extra = ''
        if ($value -match '--autostart') { $extra = ' -BlitzArgs "--autostart"' }
        Set-ItemProperty -Path $runKey -Name $property.Name -Value ('"' + $powershell + '" ' + $launchArgs + $extra)
        Write-Host "repaired Run value: $($property.Name)"
    }
}

exit 0

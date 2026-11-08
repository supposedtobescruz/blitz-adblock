# Routes every existing Blitz launcher through launch_noads.ps1 so the PAC is
# always applied, no matter which icon is used (desktop, Start Menu, taskbar
# pin, autostart registry value).
#
# Original shortcut targets and the Run value are backed up under build\ before
# being changed. Running the script twice is harmless.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\retarget_shortcuts.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\retarget_shortcuts.ps1 -DryRun
param(
    [string]$Base = $PSScriptRoot,
    [switch]$DryRun,
    [switch]$SkipAutostart
)

$ErrorActionPreference = 'Stop'

$buildDir = Join-Path $Base '..\build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$shortcutBackup = Join-Path $buildDir 'shortcut-backup.txt'
$autostartBackup = Join-Path $buildDir 'autostart-backup.txt'

$launcher = Join-Path $Base 'launch_noads.ps1'
if (-not (Test-Path $launcher)) {
    Write-Error "launcher missing: $launcher"
    exit 1
}

$blitzExe = Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcherArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $launcher + '"'

$dirs = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('Programs'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
    (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\Start Menu\Programs\StartUp')
) | Select-Object -Unique

$shell = New-Object -ComObject WScript.Shell
$changed = 0

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $_.FullName
        $shortcut = $shell.CreateShortcut($path)
        $target = $shortcut.TargetPath
        if ($target -notlike '*Blitz.exe') { return }
        if ($target -eq $powershell) { return }
        if ($shortcut.Arguments -like '*launch_noads.ps1*') { return }

        "$path`t$target`t$($shortcut.Arguments)" | Add-Content -Path $shortcutBackup -Encoding UTF8
        if ($DryRun) {
            Write-Host "would retarget: $path"
            return
        }

        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $launcherArgs
        $shortcut.WorkingDirectory = Split-Path $blitzExe -Parent
        if (Test-Path $blitzExe) { $shortcut.IconLocation = "$blitzExe,0" }
        $shortcut.Description = 'Blitz with ad domains routed to a dead proxy (Blitz process only)'
        $shortcut.Save()
        Write-Host "retargeted: $path"
        $script:changed++
    }
}

if (-not $SkipAutostart) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $properties = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
    if ($properties) {
        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }
            $value = [string]$property.Value
            if ($value -notlike '*Blitz.exe*') { continue }
            if ($value -like '*launch_noads.ps1*') { continue }

            "$($property.Name)`t$value" | Add-Content -Path $autostartBackup -Encoding UTF8
            $extra = ''
            if ($value -match '--autostart') { $extra = ' -BlitzArgs "--autostart"' }
            $newValue = '"' + $powershell + '" ' + $launcherArgs + $extra
            if ($DryRun) {
                Write-Host "would update Run value: $($property.Name) = $newValue"
                continue
            }
            Set-ItemProperty -Path $runKey -Name $property.Name -Value $newValue
            Write-Host "updated Run value: $($property.Name)"
            $script:changed++
        }
    }
}

Write-Host "done: $changed change(s)"

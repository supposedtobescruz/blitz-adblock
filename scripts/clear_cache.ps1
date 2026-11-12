# Clears Blitz HTTP cache and Service Worker cache so cached ad creatives from
# before an update cannot render. The folders are moved into a timestamped
# backup under %LOCALAPPDATA%\BlitzNoAds, not deleted.
#
# Normally called automatically by launch_noads.ps1 after a version change
# (sync_pac.py writes build\.cache-clear in that case). Can also be forced.
param(
    [string]$BlitzDir = (Join-Path $env:APPDATA 'Blitz'),
    [string]$BackupDir = (Join-Path $env:LOCALAPPDATA 'BlitzNoAds'),
    [string]$Marker,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$buildDir = Join-Path $PSScriptRoot '..\build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
if (-not $Marker) { $Marker = Join-Path $buildDir '.cache-clear' }

if (-not $Force) {
    if (-not (Test-Path $Marker)) {
        Write-Host 'cache clear not requested'
        exit 0
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupDir ("cache-backup-" + $stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null

$moved = 0
foreach ($name in @('Cache', 'Code Cache', 'Service Worker')) {
    $src = Join-Path $BlitzDir $name
    if (Test-Path $src) {
        try {
            Move-Item $src (Join-Path $backup ($name -replace ' ', '_')) -Force
            $moved++
        }
        catch {
            Write-Host "could not move ${name}: $($_.Exception.Message)"
        }
    }
}

if (Test-Path $Marker) { Remove-Item $Marker -Force }
Write-Host "cleared $moved folder(s), backup: $backup"

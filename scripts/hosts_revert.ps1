#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the managed block from the Windows hosts file.

.PARAMETER Base
    Data directory used for the log file. Defaults to %LOCALAPPDATA%\BlitzNoAds.
#>
param(
    [string]$Base = (Join-Path $env:LOCALAPPDATA 'BlitzNoAds')
)

$ErrorActionPreference = 'Stop'
$hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
$log = Join-Path $Base 'hosts-revert.log'
$begin = '# BEGIN BLITZ NOADS'
$end = '# END BLITZ NOADS'

try {
    New-Item -ItemType Directory -Force -Path $Base | Out-Null

    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in (Get-Content $hostsPath -ErrorAction SilentlyContinue)) {
        if ($line -match [regex]::Escape($begin)) { $skip = $true; continue }
        if ($line -match [regex]::Escape($end)) { $skip = $false; continue }
        if (-not $skip) { $out.Add($line) }
    }

    Set-Content -Path $hostsPath -Value $out -Encoding ASCII -Force
    ipconfig /flushdns | Out-Null
    "OK reverted $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content $log -Encoding ASCII
    Write-Host 'Hosts block removed.'
}
catch {
    "ERROR: $($_.Exception.Message)" | Set-Content $log -Encoding ASCII
    Write-Error $_
}

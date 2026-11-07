#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies a system-wide DNS block for Blitz ad/tracker domains via the Windows hosts file.

.DESCRIPTION
    Reads domains.txt, removes a previous managed block (if present), writes a new one between
    marker lines, then flushes the DNS cache. A timestamped backup of the hosts file is created
    next to this script's data directory.

.PARAMETER Base
    Data directory. Defaults to %LOCALAPPDATA%\BlitzNoAds.

.PARAMETER DomainsFile
    Domain list. Defaults to ..\domains.txt relative to this script.
#>
param(
    [string]$Base = (Join-Path $env:LOCALAPPDATA 'BlitzNoAds'),
    [string]$DomainsFile = (Join-Path $PSScriptRoot '..\domains.txt')
)

$ErrorActionPreference = 'Stop'
$hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
$log = Join-Path $Base 'hosts-apply.log'
$begin = '# BEGIN BLITZ NOADS'
$end = '# END BLITZ NOADS'

try {
    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $hostsPath (Join-Path $Base "hosts-backup-$stamp.txt") -Force

    $domains = Get-Content $DomainsFile | Where-Object { $_.Trim() -ne '' }

    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in (Get-Content $hostsPath -ErrorAction SilentlyContinue)) {
        if ($line -match [regex]::Escape($begin)) { $skip = $true; continue }
        if ($line -match [regex]::Escape($end)) { $skip = $false; continue }
        if (-not $skip) { $out.Add($line) }
    }

    $out.Add('')
    $out.Add("$begin - Blitz ad/tracker block - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($d in $domains) {
        $out.Add('0.0.0.0 ' + $d)
        $out.Add('0.0.0.0 www.' + $d)
    }
    $out.Add($end)

    Set-Content -Path $hostsPath -Value $out -Encoding ASCII -Force
    ipconfig /flushdns | Out-Null

    $count = (Select-String -Path $hostsPath -Pattern '^0\.0\.0\.0 ').Count
    "OK $stamp entries=$count domains=$($domains.Count)" | Set-Content $log -Encoding ASCII
    Write-Host "Blocked $($domains.Count) domains ($count hosts entries)."
}
catch {
    "ERROR: $($_.Exception.Message)" | Set-Content $log -Encoding ASCII
    Write-Error $_
}

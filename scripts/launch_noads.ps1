# Starts Blitz with a proxy PAC that routes known ad domains to a dead proxy.
# Scoped to the Blitz process tree: no system DNS or hosts changes.
#
# Requires blitz-pac-url.txt next to this script (generate it with make_pac.py).
param(
    [string]$Base = $PSScriptRoot,
    [string]$Exe = (Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
    Write-Error "Blitz.exe not found: $Exe"
    exit 1
}

$pacUrlFile = Join-Path $Base 'blitz-pac-url.txt'
if (-not (Test-Path $pacUrlFile)) {
    # make_pac.py writes to build/ next to the repo root
    $pacUrlFile = Join-Path $Base 'build\blitz-pac-url.txt'
}
if (-not (Test-Path $pacUrlFile)) {
    $pacUrlFile = Join-Path $Base '..\build\blitz-pac-url.txt'
}
if (-not (Test-Path $pacUrlFile)) {
    Write-Error "PAC URL missing: $pacUrlFile (run make_pac.py first)"
    exit 1
}

$pacUrl = (Get-Content $pacUrlFile -Raw).Trim()
Start-Process -FilePath $Exe -ArgumentList ('--proxy-pac-url="' + $pacUrl + '"')

# Starts Blitz with a proxy PAC that routes known ad domains to a dead proxy.
# Scoped to the Blitz process tree: no system DNS or hosts changes.
#
# Before launching, the PAC is re-generated when the installed Blitz version or
# the domain list changed (see sync_pac.py), so a client update does not leave a
# stale block list behind.
#
# Requires build/blitz-pac-url.txt (generate it with make_pac.py or sync_pac.py).
param(
    [string]$Base = $PSScriptRoot,
    [string]$Exe = (Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
    Write-Error "Blitz.exe not found: $Exe"
    exit 1
}

# --- keep the PAC current -------------------------------------------------
$sync = Join-Path $Base 'sync_pac.py'
$logDir = Join-Path $Base '..\build'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'sync.log'

if (Test-Path $sync) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        try {
            $output = & $python.Source $sync --quiet 2>&1
            if ($LASTEXITCODE -ne 0 -or $output) {
                "[$(Get-Date -Format 's')] $output" | Add-Content -Path $log -Encoding UTF8
            }
        }
        catch {
            "[$(Get-Date -Format 's')] sync failed: $($_.Exception.Message)" |
                Add-Content -Path $log -Encoding UTF8
        }
    }
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

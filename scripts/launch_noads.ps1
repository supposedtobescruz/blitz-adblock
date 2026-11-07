# Starts Blitz with a proxy PAC that routes known ad domains to a dead proxy.
# Scoped to the Blitz process tree: no system DNS or hosts changes.
#
# Before launching, the PAC is re-generated when the installed Blitz version or
# the domain list changed. After launching, a short-lived watcher tails the app
# log: if Blitz finds an update, the watcher waits for it to install, rebuilds the
# PAC and restarts Blitz with the new PAC. When no update is pending the watcher
# exits within seconds, so nothing keeps running in the background.
#
# Requires build/blitz-pac-url.txt (generate it with make_pac.py or sync_pac.py).
param(
    [string]$Base = $PSScriptRoot,
    [string]$Exe = (Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe'),
    [switch]$NoWatch
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
    Write-Error "Blitz.exe not found: $Exe"
    exit 1
}

$buildDir = Join-Path $Base '..\build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$log = Join-Path $buildDir 'sync.log'

function Resolve-Python {
    $cache = Join-Path $buildDir 'python-path.txt'
    if (Test-Path $cache) {
        $cached = (Get-Content $cache -Raw).Trim()
        if ($cached -and (Test-Path $cached)) { return $cached }
    }
    $command = Get-Command python -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    try {
        $exe = (& $command.Source -c "import sys; print(sys.executable)").Trim()
    }
    catch {
        return $null
    }
    if (-not $exe -or -not (Test-Path $exe)) { return $null }
    Set-Content -Path $cache -Value $exe -Encoding ASCII
    return $exe
}

$pythonPath = Resolve-Python

# --- keep the PAC current before launch -----------------------------------
$sync = Join-Path $Base 'sync_pac.py'
if ((Test-Path $sync) -and $pythonPath) {
    try {
        $output = & $pythonPath $sync --quiet 2>&1
        if ($LASTEXITCODE -ne 0 -or $output) {
            "[$(Get-Date -Format 's')] $output" | Add-Content -Path $log -Encoding UTF8
        }
    }
    catch {
        "[$(Get-Date -Format 's')] sync failed: $($_.Exception.Message)" |
            Add-Content -Path $log -Encoding UTF8
    }
}

$pacUrlFile = Join-Path $Base 'blitz-pac-url.txt'
if (-not (Test-Path $pacUrlFile)) {
    $pacUrlFile = Join-Path $buildDir 'blitz-pac-url.txt'
}
if (-not (Test-Path $pacUrlFile)) {
    $pacUrlFile = Join-Path $Base '..\build\blitz-pac-url.txt'
}
if (-not (Test-Path $pacUrlFile)) {
    Write-Error "PAC URL missing: $pacUrlFile (run make_pac.py first)"
    exit 1
}

$pacUrl = (Get-Content $pacUrlFile -Raw).Trim()

# --- launch ---------------------------------------------------------------
$appLog = Join-Path $env:APPDATA 'Blitz\app.log'
$logSize = 0
if (Test-Path $appLog) {
    $logSize = (Get-Item $appLog).Length
}

Start-Process -FilePath $Exe -ArgumentList ('--proxy-pac-url="' + $pacUrl + '"')

# --- watch this launch for an update -------------------------------------
if (-not $NoWatch) {
    $watch = Join-Path $Base 'watch_update.py'
    if ((Test-Path $watch) -and $pythonPath) {
        Start-Process -FilePath $pythonPath `
            -ArgumentList @($watch, '--since-bytes', $logSize) `
            -WindowStyle Hidden
    }
}

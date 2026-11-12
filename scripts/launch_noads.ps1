# Starts Blitz with a proxy PAC that routes known ad domains to a dead proxy.
# Scoped to the Blitz process tree: no system DNS or hosts changes.
#
# Behaviour:
#   * regenerates the PAC when the Blitz version or the domain list changed
#   * if Blitz is already running without the PAC (autostart, taskbar icon,
#     post-update relaunch) it restarts Blitz so the PAC actually applies
#   * if a newer PAC exists than the running process, it restarts Blitz too
#   * repairs the launcher wiring of the known icons if a Blitz update reset them
#   * clears stale Blitz HTTP caches on every launch so cached ad creatives
#     cannot render even before the PAC can block them
#   * after launching, a short-lived watcher tails the app log: if Blitz finds an
#     update it waits for the install, rebuilds the PAC and restarts Blitz.
#     When no update is pending the watcher exits within seconds.
param(
    [string]$Base = $PSScriptRoot,
    [string]$Exe = (Join-Path $env:LOCALAPPDATA 'Programs\Blitz\Blitz.exe'),
    [string]$BlitzArgs = '',
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

function Write-LauncherLog([string]$Message) {
    "[$(Get-Date -Format 's')] $Message" | Add-Content -Path $log -Encoding UTF8
}

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

function Get-BlitzMainProcess {
    Get-CimInstance Win32_Process -Filter "Name='Blitz.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' } |
        Sort-Object CreationDate |
        Select-Object -First 1
}

$pythonPath = Resolve-Python

# --- keep the PAC current before launch -----------------------------------
$sync = Join-Path $Base 'sync_pac.py'
if ((Test-Path $sync) -and $pythonPath) {
    try {
        $output = & $pythonPath $sync --quiet 2>&1
        if ($LASTEXITCODE -ne 0 -or $output) { Write-LauncherLog $output }
    }
    catch {
        Write-LauncherLog "sync failed: $($_.Exception.Message)"
    }
}

$pacUrlFile = Join-Path $Base 'blitz-pac-url.txt'
foreach ($candidate in @(
        (Join-Path $Base 'blitz-pac-url.txt'),
        (Join-Path $buildDir 'blitz-pac-url.txt'),
        (Join-Path $Base '..\build\blitz-pac-url.txt'))) {
    if (Test-Path $candidate) { $pacUrlFile = $candidate; break }
}
if (-not (Test-Path $pacUrlFile)) {
    Write-Error "PAC URL missing: $pacUrlFile (run make_pac.py first)"
    exit 1
}

$pacUrl = (Get-Content $pacUrlFile -Raw).Trim()
$pacWritten = (Get-Item $pacUrlFile).LastWriteTime

# --- make sure the running instance actually uses the PAC ------------------
$running = Get-BlitzMainProcess
if ($running) {
    $hasPac = $running.CommandLine -match '--proxy-pac-url'
    $stalePac = $running.CreationDate -lt $pacWritten
    if ($hasPac -and -not $stalePac) {
        Write-LauncherLog "Blitz already running with PAC (pid $($running.ProcessId))"
        exit 0
    }
    $reason = if (-not $hasPac) { 'without PAC' } else { 'with an outdated PAC' }
    Write-LauncherLog "restarting Blitz (pid $($running.ProcessId)) $reason"
    & taskkill /F /T /PID $running.ProcessId 2>$null | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Get-Process Blitz -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
}

# --- repair shortcuts after a Blitz update ----------------------------------
$repair = Join-Path $Base 'repair_shortcuts.ps1'
if (Test-Path $repair) {
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $repair 2>&1
        foreach ($line in $out) { if ($line) { Write-LauncherLog $line } }
    }
    catch {
        Write-LauncherLog "repair failed: $($_.Exception.Message)"
    }
}

# --- clear stale caches before launch ------------------------------------------
$clear = Join-Path $Base 'clear_cache.ps1'
if (Test-Path $clear) {
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $clear -Force 2>&1
        foreach ($line in $out) { if ($line) { Write-LauncherLog $line } }
    }
    catch {
        Write-LauncherLog "cache clear failed: $($_.Exception.Message)"
    }
}

# --- launch ---------------------------------------------------------------
$appLog = Join-Path $env:APPDATA 'Blitz\app.log'
$logSize = 0
if (Test-Path $appLog) {
    $logSize = (Get-Item $appLog).Length
}

$arguments = '--proxy-pac-url="' + $pacUrl + '" --disable-quic'
if ($BlitzArgs) { $arguments += ' ' + $BlitzArgs }

Start-Process -FilePath $Exe -ArgumentList $arguments
Write-LauncherLog 'launched Blitz with PAC'

# --- watch this launch for an update -------------------------------------
if (-not $NoWatch) {
    $watch = Join-Path $Base 'watch_update.py'
    if ((Test-Path $watch) -and $pythonPath) {
        Start-Process -FilePath $pythonPath `
            -ArgumentList @($watch, '--since-bytes', $logSize) `
            -WindowStyle Hidden
    }
}

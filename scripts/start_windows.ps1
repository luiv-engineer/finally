<#
.SYNOPSIS
    FinAlly - start the app (Windows / PowerShell).

.DESCRIPTION
    Builds the Docker image if it is missing, then runs the container with the
    ./data bind mount and your .env file. Safe to run repeatedly. Never touches
    your data.

.EXAMPLE
    .\scripts\start_windows.ps1
.EXAMPLE
    .\scripts\start_windows.ps1 -Build
.EXAMPLE
    .\scripts\start_windows.ps1 -Port 9000 -NoOpen
#>

[CmdletBinding()]
param(
    [switch] $Build,
    [switch] $NoOpen,
    [int]    $Port = 8000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ImageName     = 'finally:latest'
$ContainerName = 'finally'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Write-Info { param([string]$Message) Write-Host "· $Message" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$Message) Write-Host "+ $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "! $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "x $Message" -ForegroundColor Red; exit 1 }

# --- preflight ---------------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail 'Docker is not installed. Get Docker Desktop: https://docker.com/products/docker-desktop'
}
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Docker is installed but not running. Start Docker Desktop and try again.'
}

Set-Location $ProjectRoot

# .env - create from the example on first run.
$EnvFile     = Join-Path $ProjectRoot '.env'
$EnvExample  = Join-Path $ProjectRoot '.env.example'
if (-not (Test-Path $EnvFile)) {
    if (-not (Test-Path $EnvExample)) { Write-Fail '.env.example is missing; cannot create .env' }
    Copy-Item $EnvExample $EnvFile
    Write-Warn 'No .env found - created one from .env.example.'
    Write-Info '  FinAlly runs fine as-is (market simulator, AI chat disabled).'
    Write-Info '  Add an OPENROUTER_API_KEY to .env to enable the AI assistant.'
}

# Runtime data directory. Bind-mounted into the container (CONTRACTS.md section 9),
# so the SQLite file is visible - and deletable - right here on your machine.
$DataDir = Join-Path $ProjectRoot 'data'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

# --- build -------------------------------------------------------------------
docker image inspect $ImageName 2>&1 | Out-Null
$ImageExists = ($LASTEXITCODE -eq 0)

if ($Build -or -not $ImageExists) {
    if ($Build) {
        Write-Info "Building $ImageName (-Build)..."
    } else {
        Write-Info "Image $ImageName not found - building it (first run takes a few minutes)..."
    }
    docker build -t $ImageName $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Docker build failed.' }
    Write-Ok 'Image built.'
} else {
    Write-Info "Using existing image $ImageName. Pass -Build to rebuild."
}

# --- container ---------------------------------------------------------------
function Get-ContainerState {
    $state = docker inspect -f '{{.State.Status}}' $ContainerName 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($state | Out-String).Trim()
}

$State = Get-ContainerState
$Url   = "http://localhost:$Port"

if ($State -eq 'running' -and -not $Build) {
    Write-Ok 'FinAlly is already running.'
    Write-Host "  $Url" -ForegroundColor White
    Write-Info "Logs:  docker logs -f $ContainerName"
    Write-Info 'Stop:  .\scripts\stop_windows.ps1'
    exit 0
}

if ($State -ne '') {
    Write-Info "Removing existing container ($State)..."
    docker rm -f $ContainerName 2>&1 | Out-Null
}

# Note: no --user here. Windows bind mounts do not carry POSIX ownership, so
# the image's built-in non-root user can write to /app/data as-is.
Write-Info 'Starting container...'
docker run -d `
    --name $ContainerName `
    -p "${Port}:8000" `
    --env-file "$EnvFile" `
    -e DATABASE_PATH=/app/data/finally.db `
    -v "${DataDir}:/app/data" `
    $ImageName | Out-Null

if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to start the container.' }

# --- wait for health ---------------------------------------------------------
Write-Info 'Waiting for the app to come up...'
$Ready = $false
foreach ($i in 1..60) {
    if ((Get-ContainerState) -ne 'running') {
        docker logs --tail 40 $ContainerName
        Write-Fail 'Container exited during startup (logs above).'
    }
    try {
        $resp = Invoke-WebRequest -Uri "$Url/api/health" -TimeoutSec 2 -UseBasicParsing
        if ($resp.StatusCode -eq 200) { $Ready = $true; break }
    } catch {
        # not up yet
    }
    Start-Sleep -Seconds 1
}

if ($Ready) {
    Write-Ok 'FinAlly is up.'
} else {
    Write-Warn 'Container is running but /api/health did not respond within 60s.'
    Write-Info 'Recent logs:'
    docker logs --tail 40 $ContainerName
}

Write-Host ''
Write-Host "  $Url" -ForegroundColor White
Write-Host ''
Write-Info "Logs:  docker logs -f $ContainerName"
Write-Info 'Stop:  .\scripts\stop_windows.ps1'

if (-not $NoOpen -and $Ready) {
    Start-Process $Url | Out-Null
}

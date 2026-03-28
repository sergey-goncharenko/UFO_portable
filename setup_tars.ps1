<#
.SYNOPSIS
    Install Agent TARS CLI alongside UFO2.
.DESCRIPTION
    Installs Node.js 22+ (if needed) and Agent TARS CLI globally.
    
    Usage:
        .\setup_tars.ps1 -ApiKey "sk-proj-..."
        .\setup_tars.ps1                          # will use OPENAI_API_KEY env var
#>
param(
    [string]$ApiKey,
    [string]$NodeVersion = "22"
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Agent TARS Setup' -ForegroundColor Cyan
Write-Host '  ================' -ForegroundColor Cyan
Write-Host ''

# ── 1. Check / Install Node.js ─────────────────────────────
Write-Step 'Checking Node.js installation...'

$nodeOk = $false
try {
    $nodeVer = cmd /c 'node --version 2>&1'
    if ($nodeVer -match 'v(\d+)') {
        $major = [int]$Matches[1]
        if ($major -ge 22) {
            Write-Ok ('Found Node.js ' + $nodeVer)
            $nodeOk = $true
        } else {
            Write-Warn ('Found Node.js ' + $nodeVer + ' but need v22+')
        }
    }
} catch {}

if (-not $nodeOk) {
    Write-Step 'Installing Node.js 22 LTS...'
    $nodeInstaller = Join-Path $env:TEMP 'node-installer.msi'
    $nodeUrl = 'https://nodejs.org/dist/v22.16.0/node-v22.16.0-x64.msi'
    
    try {
        Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeInstaller -UseBasicParsing
        Write-Host '    Installing silently...'
        Start-Process msiexec.exe -ArgumentList '/i', $nodeInstaller, '/quiet', '/norestart' -Wait -NoNewWindow
        
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        
        $nodeVer = cmd /c 'node --version 2>&1'
        Write-Ok ('Installed Node.js ' + $nodeVer)
        Remove-Item $nodeInstaller -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host ('    ERROR: Node.js install failed: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '    Install manually from https://nodejs.org/' -ForegroundColor Red
        exit 1
    }
}

# ── 2. Install Agent TARS CLI ──────────────────────────────
Write-Step 'Installing Agent TARS CLI...'

$tarsResult = cmd /c 'npm install @agent-tars/cli@latest -g 2>&1'
$tarsExit = $LASTEXITCODE

if ($tarsExit -eq 0) {
    $tarsVer = cmd /c 'agent-tars --version 2>&1'
    Write-Ok ('Agent TARS CLI installed: ' + $tarsVer)
} else {
    Write-Warn 'npm install had warnings (this is usually fine)'
    # Check if it actually installed
    $tarsCheck = cmd /c 'agent-tars --version 2>&1'
    if ($tarsCheck -match '\d+\.\d+') {
        Write-Ok ('Agent TARS CLI available: ' + $tarsCheck)
    } else {
        Write-Host '    ERROR: Agent TARS CLI not found after install' -ForegroundColor Red
        exit 1
    }
}

# ── 3. Install Chrome (needed for browser control) ─────────
Write-Step 'Checking Chrome...'
$chromeExe = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (Test-Path $chromeExe) {
    Write-Ok 'Chrome is installed'
} else {
    Write-Warn 'Chrome not found. Agent TARS needs Chrome for browser control.'
    Write-Host '    Install from https://www.google.com/chrome/' -ForegroundColor Yellow
}

# ── 4. Create default config ───────────────────────────────
Write-Step 'Creating Agent TARS config...'

$tarsConfigDir = Join-Path $env:USERPROFILE '.agent-tars-workspace'
New-Item -ItemType Directory -Path $tarsConfigDir -Force | Out-Null

if (-not $ApiKey -and $env:OPENAI_API_KEY) { $ApiKey = $env:OPENAI_API_KEY }

$configContent = @()
$configContent += '{'
$configContent += '  "model": {'
$configContent += '    "provider": "openai",'
$configContent += '    "id": "gpt-4o",'
if ($ApiKey) {
    $configContent += '    "apiKey": "' + $ApiKey + '"'
} else {
    $configContent += '    "apiKey": "OPENAI_API_KEY"'
}
$configContent += '  },'
$configContent += '  "browser": {'
$configContent += '    "control": "hybrid"'
$configContent += '  }'
$configContent += '}'

$configPath = Join-Path $tarsConfigDir 'agent-tars.config.json'
[IO.File]::WriteAllLines($configPath, $configContent)
Write-Ok ('Config written to ' + $configPath)

# ── Done ────────────────────────────────────────────────────
Write-Host '' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '   Agent TARS is ready!' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  Interactive UI:' -ForegroundColor Green
Write-Host '    agent-tars' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  One-shot command:' -ForegroundColor Green
Write-Host '    agent-tars run --input "Search Google for weather in NYC"' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  With specific model:' -ForegroundColor Green
Write-Host '    agent-tars run --model.provider openai --model.id gpt-4o-mini --model.apiKey YOUR_KEY --input "your task"' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''

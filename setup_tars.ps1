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
    [string]$NodeVersion = "22",
    [string]$UserProfile = ""  # Override user profile path (for SYSTEM context)
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

# ── 4. Setup browser profile ────────────────────────────────
Write-Step 'Setting up persistent browser profile...'

# Resolve target profile (use -UserProfile if running as SYSTEM)
$targetProfile = if ($UserProfile) { $UserProfile } else { $env:USERPROFILE }
$targetLocalAppData = if ($UserProfile) { Join-Path $UserProfile 'AppData\Local' } else { $env:LOCALAPPDATA }

# Create a dedicated Chrome profile directory for the agent
$agentProfileDir = 'C:\tars_browser_profile'
New-Item -ItemType Directory -Path $agentProfileDir -Force | Out-Null

# Copy the user's existing Chrome profile (with cookies/logins) if it exists
$userChromeProfile = Join-Path $targetLocalAppData 'Google\Chrome\User Data'
$profileReady = $false

if (Test-Path $userChromeProfile) {
    # Check if we already copied it before
    $defaultProfile = Join-Path $agentProfileDir 'Default'
    if (-not (Test-Path $defaultProfile)) {
        Write-Host '    Copying user Chrome profile (cookies, logins, bookmarks)...'
        Write-Host '    This may take a minute...' -ForegroundColor DarkGray
        
        # Close Chrome first to avoid locked files
        Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # Copy key profile data (not the entire cache)
        $itemsToCopy = @('Default', 'Local State', 'First Run')
        foreach ($item in $itemsToCopy) {
            $src = Join-Path $userChromeProfile $item
            $dst = Join-Path $agentProfileDir $item
            if (Test-Path $src) {
                if ((Get-Item $src).PSIsContainer) {
                    cmd /c ('robocopy "' + $src + '" "' + $dst + '" /E /NFL /NDL /NJH /NJS /NC /NS /XD "Cache" "Code Cache" "Service Worker" "GPUCache" 2>nul') | Out-Null
                } else {
                    Copy-Item $src $dst -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $profileReady = $true
        Write-Ok ('Copied user profile to ' + $agentProfileDir)
    } else {
        $profileReady = $true
        Write-Ok ('Profile already exists at ' + $agentProfileDir)
    }
} else {
    Write-Warn 'No existing Chrome profile found. Agent will start with a clean browser.'
    Write-Host '    To pre-authenticate: open Chrome, log into your apps, then re-run setup.' -ForegroundColor Yellow
}

# ── 5. Create configs (public + authenticated) ─────────────
Write-Step 'Creating Agent TARS configs...'

$tarsConfigDir = Join-Path $targetProfile '.agent-tars-workspace'
New-Item -ItemType Directory -Path $tarsConfigDir -Force | Out-Null

if (-not $ApiKey -and $env:OPENAI_API_KEY) { $ApiKey = $env:OPENAI_API_KEY }
$apiKeyValue = if ($ApiKey) { $ApiKey } else { 'OPENAI_API_KEY' }

# Config 1: Public/benchmark mode (clean browser, no profile)
$publicConfig = @()
$publicConfig += '{'
$publicConfig += '  "model": {'
$publicConfig += '    "provider": "openai",'
$publicConfig += '    "id": "gpt-4o",'
$publicConfig += '    "apiKey": "' + $apiKeyValue + '"'
$publicConfig += '  },'
$publicConfig += '  "browser": {'
$publicConfig += '    "control": "hybrid"'
$publicConfig += '  }'
$publicConfig += '}'

$publicConfigPath = Join-Path $tarsConfigDir 'agent-tars.config.json'
[IO.File]::WriteAllLines($publicConfigPath, $publicConfig)
Write-Ok ('Public config: ' + $publicConfigPath)

# Config 2: Authenticated mode (user's Chrome profile with logins)
$authConfig = @()
$authConfig += '{'
$authConfig += '  "model": {'
$authConfig += '    "provider": "openai",'
$authConfig += '    "id": "gpt-4o",'
$authConfig += '    "apiKey": "' + $apiKeyValue + '"'
$authConfig += '  },'
$authConfig += '  "browser": {'
$authConfig += '    "control": "hybrid",'
$authConfig += '    "launchOptions": {'
$authConfig += '      "args": ['
$authConfig += '        "--user-data-dir=' + ($agentProfileDir -replace '\\', '\\\\') + '"'
$authConfig += '      ]'
$authConfig += '    }'
$authConfig += '  }'
$authConfig += '}'

$authConfigPath = Join-Path $tarsConfigDir 'agent-tars-auth.config.json'
[IO.File]::WriteAllLines($authConfigPath, $authConfig)
Write-Ok ('Authenticated config: ' + $authConfigPath)

# Also save configs to the portable repo dir for easy access
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tarsConfigsDir = Join-Path $scriptDir 'configs\tars'
New-Item -ItemType Directory -Path $tarsConfigsDir -Force | Out-Null
Copy-Item $publicConfigPath (Join-Path $tarsConfigsDir 'public.config.json') -Force
Copy-Item $authConfigPath (Join-Path $tarsConfigsDir 'auth.config.json') -Force

# ── Done ────────────────────────────────────────────────────
Write-Host '' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '   Agent TARS is ready!' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  Public mode (clean browser, for benchmarks):' -ForegroundColor Green
Write-Host '    agent-tars' -ForegroundColor Green
Write-Host '    agent-tars run --input "Search Google for weather"' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  Authenticated mode (user profile with logins):' -ForegroundColor Yellow
Write-Host ('    agent-tars --config "' + $authConfigPath + '"') -ForegroundColor Yellow
Write-Host ('    agent-tars run --config "' + $authConfigPath + '" --input "Check my email"') -ForegroundColor Yellow
Write-Host '' -ForegroundColor Green
if ($profileReady) {
    Write-Host '  Browser profile: READY (copied from user Chrome)' -ForegroundColor Green
} else {
    Write-Host '  Browser profile: EMPTY (log into apps in Chrome, then re-run setup)' -ForegroundColor Yellow
}
Write-Host ('  Profile dir: ' + $agentProfileDir) -ForegroundColor DarkGray
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''

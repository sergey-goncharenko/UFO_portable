<#
.SYNOPSIS
    One-click UFO² setup for a fresh Windows VM.
.DESCRIPTION
    Run this script on a clean Windows 10/11 VM to install Python, clone UFO,
    install dependencies, and configure the LLM API key.
    
    Usage:
        .\setup_ufo.ps1 -ApiKey "sk-proj-..."
        .\setup_ufo.ps1                          # will prompt for API key
.NOTES
    Requirements: Windows 10+, internet access, PowerShell 5.1+
#>
param(
    [string]$ApiKey,
    [string]$InstallDir = "C:\UFO",
    [string]$Model = "gpt-4o",
    [string]$PythonVersion = "3.11.9"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# --- Colors ---
function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

Write-Host ""
Write-Host '  _   _  _____   ___   ____' -ForegroundColor Magenta
Write-Host ' | | | ||  ___| / _ \ |___ \' -ForegroundColor Magenta
Write-Host ' | | | || |_   | | | |  __) |' -ForegroundColor Magenta
Write-Host ' | |_| ||  _|  | |_| | / __/' -ForegroundColor Magenta
Write-Host '  \___/ |_|     \___/ |_____|' -ForegroundColor Magenta
Write-Host '' -ForegroundColor Magenta
Write-Host '  UFO2 Desktop AgentOS - VM Setup' -ForegroundColor Magenta
Write-Host '  ================================' -ForegroundColor Magenta
Write-Host ""

# ──────────────────────────────────────────────────────────────
# 1. Check / Install Python
# ──────────────────────────────────────────────────────────────
Write-Step "Checking Python installation..."

$python = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3\.(1[0-9]|[2-9]\d)") {
            $python = $cmd
            Write-Ok "Found $ver ($cmd)"
            break
        }
    } catch {}
}

if (-not $python) {
    Write-Step "Python 3.10+ not found. Installing Python $PythonVersion..."
    $installer = Join-Path $env:TEMP 'python-installer.exe'
    $url = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
    
    Write-Host "    Downloading from $url ..."
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    
    Write-Host "    Installing (silent)..."
    Start-Process -FilePath $installer -ArgumentList `
        "/quiet", "InstallAllUsers=1", "PrependPath=1", `
        "Include_pip=1", "Include_test=0" -Wait -NoNewWindow
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    
    $python = "python"
    $ver = & $python --version 2>&1
    Write-Ok "Installed $ver"
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
}

# ──────────────────────────────────────────────────────────────
# 2. Clone or update UFO
# ──────────────────────────────────────────────────────────────
Write-Step "Setting up UFO repository in $InstallDir..."

if (Test-Path (Join-Path $InstallDir '.git')) {
    Write-Host "    Repository exists, pulling latest..."
    Push-Location $InstallDir
    git pull --ff-only
    Pop-Location
    Write-Ok "Updated to latest"
} else {
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
    }
    git clone https://github.com/microsoft/UFO.git $InstallDir
    Write-Ok "Cloned to $InstallDir"
}

# ──────────────────────────────────────────────────────────────
# 3. Create virtual environment & install deps
# ──────────────────────────────────────────────────────────────
Write-Step "Creating Python virtual environment..."

Push-Location $InstallDir
$venvPath = Join-Path $InstallDir '.venv'
$venvPython = Join-Path $venvPath 'Scripts\python.exe'
$venvPip = Join-Path $venvPath 'Scripts\pip.exe'

# If venv exists but is broken (missing critical packages), recreate it
$needsCreate = $true
if (Test-Path $venvPython) {
    $testImport = cmd /c ($venvPython + ' -c "import pip; print(''OK'')" 2>&1')
    if ($testImport -match 'OK') {
        Write-Ok ".venv already exists and works"
        $needsCreate = $false
    } else {
        Write-Warn ".venv is broken, recreating..."
        Remove-Item $venvPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($needsCreate) {
    & $python -m venv $venvPath
    Write-Ok "Created .venv"
}

Write-Step "Enabling Windows long paths (avoids 260-char path errors)..."
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    $current = Get-ItemProperty -Path $regPath -Name LongPathsEnabled -ErrorAction SilentlyContinue
    if (-not $current -or $current.LongPathsEnabled -ne 1) {
        Set-ItemProperty -Path $regPath -Name LongPathsEnabled -Value 1
        Write-Ok "Long paths enabled in registry"
    } else {
        Write-Ok "Long paths already enabled"
    }
} catch {
    Write-Warn "Could not enable long paths (needs admin). Continuing with workarounds..."
}

Write-Step "Upgrading pip..."
cmd /c ($venvPython + ' -m pip install --upgrade pip setuptools wheel 2>&1') | Out-Null
Write-Ok "pip upgraded"

Write-Step "Installing dependencies (this may take several minutes)..."

# Use short temp dir to avoid 260-char path limit
$shortTmp = 'C:\tmp\pip'
New-Item -ItemType Directory -Path $shortTmp -Force | Out-Null
$env:TMPDIR = $shortTmp
$env:TEMP = $shortTmp
$env:TMP = $shortTmp

# Helper: run pip install, return exit code
function Install-PipPackages {
    param([string]$Label, [string]$PipArgs)
    Write-Host ('    Installing ' + $Label + '...') -ForegroundColor DarkGray
    $result = cmd /c ($venvPip + ' install ' + $PipArgs + ' 2>&1')
    $code = $LASTEXITCODE
    $result | ForEach-Object {
        if ($_ -match 'Successfully installed') { Write-Host "    $_" -ForegroundColor Green }
    }
    if ($code -ne 0) {
        Write-Host ('    WARNING: Failed to install ' + $Label) -ForegroundColor Yellow
        $result | ForEach-Object {
            if ($_ -match 'ERROR') { Write-Host "    $_" -ForegroundColor Red }
        }
    }
    return $code
}

# Stage 1: Core packages that UFO imports at startup (must succeed)
$corePackages = 'colorama PyYAML requests openai Pillow pywin32 pywinauto psutil beautifulsoup4 rich art protobuf msal pyautogui uiautomation comtypes'
$code = Install-PipPackages 'core packages' ('--prefer-binary ' + $corePackages)
if ($code -ne 0) {
    Write-Host '    ERROR: Core packages failed to install. Cannot continue.' -ForegroundColor Red
    Pop-Location
    exit 1
}

# Stage 2: Web framework and MCP packages (required for UFO startup)
$webPackages = 'flask fastapi fastmcp uvicorn websockets pydantic anthropic html2text PyPDF2 pyperclip jsonschema gradio_client azure-identity azure-identity-broker azure-storage-blob'
Install-PipPackages 'web/MCP packages' ('--prefer-binary ' + $webPackages) | Out-Null

# Stage 3: Scientific/ML packages (may need binary-only)
$mlPackages = 'numpy pandas faiss-cpu lxml matplotlib'
Install-PipPackages 'scientific packages' ('--prefer-binary --only-binary numpy,pandas,lxml,faiss-cpu ' + $mlPackages) | Out-Null

# Stage 4: LLM/AI packages
$aiPackages = 'langchain langchain_community langchain_huggingface sentence-transformers'
Install-PipPackages 'AI/LLM packages' ('--prefer-binary ' + $aiPackages) | Out-Null

# Stage 5: Remaining packages from requirements (catches anything we missed)
$reqFile = Join-Path $InstallDir 'requirements.txt'
$fixedReq = Join-Path $InstallDir 'requirements_vm.txt'
$content = Get-Content $reqFile -Raw
# Relax pinned versions
$content = $content -replace 'pandas==1\.4\.3', 'pandas>=1.5.0'
$content = $content -replace 'faiss-cpu==1\.8\.0', 'faiss-cpu>=1.8.0'
$content = $content -replace 'numpy==1\.26\.4', 'numpy>=1.26.0'
$content = $content -replace 'sentence-transformers==2\.6\.0', 'sentence-transformers>=2.6.0'
$content = $content -replace 'lxml==5\.1\.0', 'lxml>=5.1.0'
$content = $content -replace 'psutil==5\.9\.8', 'psutil>=5.9.0'
$content = $content -replace 'Pillow==11\.3\.0', 'Pillow>=10.0.0'
$content | Set-Content $fixedReq -Encoding UTF8

Write-Host '    Installing remaining requirements...' -ForegroundColor DarkGray
$pipResult = cmd /c ($venvPip + ' install --prefer-binary -r ' + $fixedReq + ' 2>&1')
$pipResult | ForEach-Object {
    if ($_ -match 'Successfully installed') { Write-Host "    $_" -ForegroundColor Green }
}

# Restore temp dir
$env:TEMP = [System.IO.Path]::GetTempPath()
$env:TMP = $env:TEMP
$env:TMPDIR = $env:TEMP
Remove-Item $shortTmp -Recurse -Force -ErrorAction SilentlyContinue

# Verify critical imports (run via cmd to avoid PS treating traceback stderr as error)
$checkResult = cmd /c ($venvPython + ' -c "import colorama, openai, yaml, requests, fastmcp; print(''OK'')" 2>&1')
if ($checkResult -match 'OK') {
    Write-Ok "Dependencies installed and verified (colorama, openai, yaml, requests)"
} else {
    Write-Host '    ERROR: Critical packages missing after install!' -ForegroundColor Red
    Write-Host '    Output:' -ForegroundColor Red
    Write-Host "    $checkResult" -ForegroundColor Red
    Write-Host '    Deleting broken venv so next run starts fresh...' -ForegroundColor Yellow
    Remove-Item $venvPath -Recurse -Force -ErrorAction SilentlyContinue
    Pop-Location
    exit 1
}

# ──────────────────────────────────────────────────────────────
# 4. Configure API key
# ──────────────────────────────────────────────────────────────
Write-Step "Configuring LLM API key..."

if (-not $ApiKey) {
    if ($env:OPENAI_API_KEY) {
        $ApiKey = $env:OPENAI_API_KEY
        Write-Ok "Using OPENAI_API_KEY from environment"
    } else {
        $secureKey = Read-Host "Enter your OpenAI API key" -AsSecureString
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))
    }
}

$configDir = Join-Path $InstallDir 'config\ufo'
$configFile = Join-Path $configDir 'agents.yaml'
$configTemplate = Join-Path $configDir 'agents.yaml.template'
Copy-Item $configTemplate $configFile -Force

# Replace placeholder keys and fix API_BASE
$content = Get-Content $configFile -Raw
$content = $content -replace 'sk-YOUR_KEY_HERE', $ApiKey
$content = $content -replace 'https://api\.openai\.com/v1/chat/completions', 'https://api.openai.com/v1'
$content = $content -replace 'API_MODEL:\s*"gpt-4o"', "API_MODEL: `"$Model`""
$content | Set-Content $configFile -Encoding UTF8

Write-Ok "Config written to $configFile"

# ──────────────────────────────────────────────────────────────
# 5. Create launcher scripts
# ──────────────────────────────────────────────────────────────
Write-Step "Creating launcher scripts..."

# Use [char]34 for double-quote to avoid all PowerShell quoting issues
$q = [char]34

# Interactive launcher
$lines = @()
$lines += "@echo off"
$lines += "title UFO2 Desktop AgentOS"
$lines += "cd /d ${q}${InstallDir}${q}"
$lines += "${q}${venvPath}\Scripts\python.exe${q} -m ufo --task demo %*"
$batPath = Join-Path $InstallDir 'ufo_interactive.bat'
[IO.File]::WriteAllLines($batPath, $lines)

# One-shot launcher
$lines = @()
$lines += "@echo off"
$lines += "title UFO2 - Running Task"
$lines += "cd /d ${q}${InstallDir}${q}"
$lines += "${q}${venvPath}\Scripts\python.exe${q} -m ufo --task demo_%RANDOM% -r %*"
$batPath = Join-Path $InstallDir 'ufo_run.bat'
[IO.File]::WriteAllLines($batPath, $lines)

# Desktop shortcuts
$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell

$lnkPath = Join-Path $desktop 'UFO2 Interactive.lnk'
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = Join-Path $InstallDir 'ufo_interactive.bat'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.IconLocation = "shell32.dll,12"
$shortcut.Description = "Launch UFO2 in interactive mode"
$shortcut.Save()

$lnkPath = Join-Path $desktop 'UFO2 Folder.lnk'
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = $InstallDir
$shortcut.Description = "Open UFO2 installation folder"
$shortcut.Save()

Write-Ok "Created ufo_interactive.bat, ufo_run.bat, and desktop shortcuts"

Pop-Location

# ──────────────────────────────────────────────────────────────
# Done!
# ──────────────────────────────────────────────────────────────
Write-Host '' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '   UFO2 is ready!' -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  Quick start:' -ForegroundColor Green
Write-Host '    Double-click UFO2 Interactive on Desktop' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host '  Or from terminal:' -ForegroundColor Green
Write-Host ('    cd ' + $InstallDir) -ForegroundColor Green
Write-Host '    .\ufo_interactive.bat' -ForegroundColor Green
Write-Host '    .\ufo_run.bat Open Notepad and type Hello World' -ForegroundColor Green
Write-Host '' -ForegroundColor Green
Write-Host ('  Logs saved to: ' + $InstallDir + '\logs') -ForegroundColor Green
Write-Host '  ============================================' -ForegroundColor Green
Write-Host ''

<#
.SYNOPSIS
    Package the current UFO installation into a portable ZIP for offline VMs.
.DESCRIPTION
    Creates a self-contained package with:
    - UFO source code
    - Pre-installed Python venv with all dependencies
    - Setup/launcher scripts
    - Config template (API key must be set on target VM)
    
    The output ZIP can be copied to any Windows 10/11 VM with matching
    Python version and architecture (x64).
    
    Usage:
        .\package_offline.ps1
        .\package_offline.ps1 -OutputPath "C:\ufo_demo_package.zip"
#>
param(
    [string]$SourceDir = "C:\UFO",
    [string]$OutputPath = "C:\ufo_portable.zip",
    [switch]$IncludeVenv
)

$ErrorActionPreference = "Stop"

Write-Host "`n  UFO2 Offline Packager" -ForegroundColor Cyan
Write-Host "  =====================`n"

$stagingDir = "$env:TEMP\ufo_package_$(Get-Random)"
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

Write-Host "[1/5] Copying UFO source..." -ForegroundColor Yellow
# Copy source, exclude large/unnecessary dirs
$excludeDirs = @(".git", ".venv", "__pycache__", "logs", "*.pyc", ".mypy_cache")
robocopy $SourceDir $stagingDir /E /XD .git .venv __pycache__ logs .mypy_cache node_modules /XF *.pyc requirements_vm.txt requirements_fixed.txt /NFL /NDL /NJH /NJS /NC /NS | Out-Null
Write-Host "    Done" -ForegroundColor Green

Write-Host "[2/5] Cleaning sensitive data..." -ForegroundColor Yellow
# Replace actual API key with placeholder in packaged config
$configFile = "$stagingDir\config\ufo\agents.yaml"
if (Test-Path $configFile) {
    $content = Get-Content $configFile -Raw
    # Remove any real API keys - replace anything that looks like an OpenAI key
    $content = $content -replace 'sk-[A-Za-z0-9_-]{20,}', 'YOUR_API_KEY_HERE'
    $content | Set-Content $configFile -Encoding UTF8
    Write-Host "    API keys stripped from config" -ForegroundColor Green
} else {
    Copy-Item "$stagingDir\config\ufo\agents.yaml.template" $configFile -ErrorAction SilentlyContinue
    Write-Host "    Using template config" -ForegroundColor Green
}

Write-Host "[3/5] Adding launcher scripts..." -ForegroundColor Yellow
# Ensure demo scripts are included
if (-not (Test-Path "$stagingDir\demo")) {
    New-Item -ItemType Directory -Path "$stagingDir\demo" -Force | Out-Null
}

# Create a simple first-run script for the target VM
@"
@echo off
title UFO2 - First Time Setup
echo.
echo  UFO2 Desktop AgentOS - First Time Setup
echo  =========================================
echo.

REM Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo  ERROR: Python 3.10+ is required but not found.
    echo  Please install Python from https://www.python.org/downloads/
    echo  Make sure to check "Add Python to PATH" during installation.
    pause
    exit /b 1
)

echo  [1/3] Creating virtual environment...
python -m venv .venv
if errorlevel 1 (
    echo  ERROR: Failed to create virtual environment.
    pause
    exit /b 1
)

echo  [2/3] Installing dependencies (this takes a few minutes)...
.venv\Scripts\pip.exe install --upgrade pip setuptools wheel >nul 2>&1

REM Fix pandas version for Python 3.11+
powershell -Command "(Get-Content requirements.txt) -replace 'pandas==1.4.3','pandas>=1.5.0' | Set-Content requirements_setup.txt"
.venv\Scripts\pip.exe install -r requirements_setup.txt
if errorlevel 1 (
    echo  ERROR: Failed to install dependencies.
    pause
    exit /b 1
)

echo  [3/3] Configuring API key...
if not exist config\ufo\agents.yaml (
    copy config\ufo\agents.yaml.template config\ufo\agents.yaml
)
echo.
echo  IMPORTANT: Edit config\ufo\agents.yaml and add your OpenAI API key.
echo  Replace 'YOUR_API_KEY_HERE' with your actual key (sk-...).
echo  Also change API_BASE to: https://api.openai.com/v1
echo.
echo  Setup complete! Run 'demo\run_demo.ps1' to start the demo.
echo.
pause
"@ | Set-Content "$stagingDir\FIRST_RUN.bat" -Encoding ASCII

# Create quick-run bat
@"
@echo off
title UFO2 Demo
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File demo\run_demo.ps1 -UfoDir "%~dp0"
"@ | Set-Content "$stagingDir\START_DEMO.bat" -Encoding ASCII

Write-Host "    Done" -ForegroundColor Green

if ($IncludeVenv) {
    Write-Host "[4/5] Including venv (offline mode)..." -ForegroundColor Yellow
    if (Test-Path "$SourceDir\.venv") {
        robocopy "$SourceDir\.venv" "$stagingDir\.venv" /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
        Write-Host "    Venv included (~2GB)" -ForegroundColor Green
    } else {
        Write-Host "    WARN: No .venv found at source, skipping" -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/5] Skipping venv (use -IncludeVenv for offline package)..." -ForegroundColor DarkGray
}

Write-Host "[5/5] Creating ZIP archive..." -ForegroundColor Yellow
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
Compress-Archive -Path "$stagingDir\*" -DestinationPath $OutputPath -CompressionLevel Optimal
$size = [math]::Round((Get-Item $OutputPath).Length / 1MB, 1)
Write-Host "    Created $OutputPath ($size MB)" -ForegroundColor Green

# Cleanup
Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host @"

  ============================================
   Package created: $OutputPath
  ============================================
  
  To use on a target VM:
    1. Copy the ZIP to the VM
    2. Extract to C:\UFO (or anywhere)
    3. Run FIRST_RUN.bat (installs deps)
    4. Edit config\ufo\agents.yaml (add API key)
    5. Run START_DEMO.bat
    
  For fully offline VM (no internet):
    Re-run with: .\package_offline.ps1 -IncludeVenv
    (includes pre-built venv, ~2GB package)
  ============================================

"@ -ForegroundColor Cyan

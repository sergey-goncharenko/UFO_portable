<#
.SYNOPSIS
    Start workflow recording — Steps Recorder + microphone simultaneously.
.DESCRIPTION
    Launches Windows Steps Recorder (psr.exe) and starts audio recording via
    FFmpeg. When you stop Steps Recorder, the audio also stops. Both files are
    saved and ready for the merge pipeline (merge_voice_recording.py).
    
    Usage:
        .\start_recording.ps1
        .\start_recording.ps1 -OutputDir C:\recordings -Name "check_movies"
#>
param(
    [string]$OutputDir = (Join-Path $env:USERPROFILE 'Desktop\recordings'),
    [string]$Name = ('workflow_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
)

$ErrorActionPreference = 'Continue'

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$psrZip = Join-Path $OutputDir ($Name + '.zip')
$audioFile = Join-Path $OutputDir ($Name + '_audio.wav')

Write-Host '' -ForegroundColor Cyan
Write-Host '  Workflow Recorder' -ForegroundColor Cyan
Write-Host '  =================' -ForegroundColor Cyan
Write-Host '' -ForegroundColor Cyan
Write-Host '  This will start:' -ForegroundColor White
Write-Host '    1. Windows Steps Recorder (screenshots + clicks)' -ForegroundColor White
Write-Host '    2. Audio recording (your voice narration)' -ForegroundColor White
Write-Host '' -ForegroundColor White
Write-Host '  Instructions:' -ForegroundColor Yellow
Write-Host '    - Click "Start Record" in Steps Recorder' -ForegroundColor Yellow
Write-Host '    - Perform your workflow while narrating what you do' -ForegroundColor Yellow
Write-Host '    - When done, click "Stop Record" in Steps Recorder' -ForegroundColor Yellow
Write-Host '    - Save the ZIP when prompted' -ForegroundColor Yellow
Write-Host '    - Then press Enter here to stop audio recording' -ForegroundColor Yellow
Write-Host '' -ForegroundColor White
Write-Host ('  Output: ' + $OutputDir) -ForegroundColor DarkGray
Write-Host ('  Files:  ' + $Name + '.zip (steps) + ' + $Name + '_audio.wav (voice)') -ForegroundColor DarkGray
Write-Host ''

# Check FFmpeg
$ffmpegAvailable = $false
$ffmpegCmd = 'ffmpeg'
try {
    $ffCheck = cmd /c 'ffmpeg -version 2>&1'
    if ($ffCheck -match 'ffmpeg version') { $ffmpegAvailable = $true }
} catch {}

if (-not $ffmpegAvailable) {
    # Try common install locations
    $ffmpegPaths = @(
        'C:\ffmpeg\bin\ffmpeg.exe',
        'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin\ffmpeg.exe')
    )
    foreach ($p in $ffmpegPaths) {
        if (Test-Path $p) {
            $ffmpegCmd = $p
            $ffmpegAvailable = $true
            break
        }
    }
}

if (-not $ffmpegAvailable) {
    Write-Host '  FFmpeg not found. Installing via winget...' -ForegroundColor Yellow
    try {
        cmd /c 'winget install Gyan.FFmpeg --accept-source-agreements --accept-package-agreements 2>&1' | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $ffmpegAvailable = $true
    } catch {
        Write-Host '  Could not install FFmpeg. Install manually: https://ffmpeg.org/download.html' -ForegroundColor Red
        Write-Host '  Continuing with Steps Recorder only (no voice recording).' -ForegroundColor Yellow
    }
}

# Record start time
$startTime = Get-Date

# Start Steps Recorder with auto-save path
Write-Host '  Starting Steps Recorder...' -ForegroundColor Green
$psrArgs = '/start /output "' + $psrZip + '" /maxsc 100 /gui 1'
Start-Process psr.exe -ArgumentList $psrArgs

# Start audio recording in background
$audioJob = $null
if ($ffmpegAvailable) {
    Write-Host '  Starting audio recording...' -ForegroundColor Green
    # Find audio device name
    $audioDevices = cmd /c ($ffmpegCmd + ' -list_devices true -f dshow -i dummy 2>&1')
    $micName = $null
    foreach ($line in $audioDevices) {
        if ($line -match '"(Microphone.*?|.*?[Mm]ic.*?)"') {
            $micName = $Matches[1]
            break
        }
    }
    
    if ($micName) {
        Write-Host ('  Microphone: ' + $micName) -ForegroundColor DarkGray
        # Start FFmpeg recording in background
        $ffmpegArgs = '-f dshow -i audio="' + $micName + '" -y "' + $audioFile + '"'
        $audioJob = Start-Process $ffmpegCmd -ArgumentList $ffmpegArgs -WindowStyle Hidden -PassThru
        Write-Host '  Audio recording started.' -ForegroundColor Green
    } else {
        Write-Host '  No microphone found. Voice recording skipped.' -ForegroundColor Yellow
        Write-Host '  Available devices:' -ForegroundColor DarkGray
        $audioDevices | Where-Object { $_ -match 'audio' } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
} else {
    Write-Host '  Audio recording skipped (no FFmpeg).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  ===========================================' -ForegroundColor Green
Write-Host '  Recording is ACTIVE' -ForegroundColor Green
Write-Host '  ===========================================' -ForegroundColor Green
Write-Host ''
Write-Host '  1. Click "Start Record" in the Steps Recorder window' -ForegroundColor Yellow
Write-Host '  2. Do your workflow while narrating out loud' -ForegroundColor Yellow
Write-Host '  3. Click "Stop Record" when done' -ForegroundColor Yellow
Write-Host '  4. Save as: ' -ForegroundColor Yellow -NoNewline
Write-Host $psrZip -ForegroundColor White
Write-Host ''
Read-Host '  Press ENTER here when you are done recording'

# Stop audio recording
if ($audioJob -and -not $audioJob.HasExited) {
    Write-Host '  Stopping audio recording...' -ForegroundColor Green
    Stop-Process -Id $audioJob.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

$endTime = Get-Date
$duration = [math]::Round(($endTime - $startTime).TotalSeconds, 0)

Write-Host ''
Write-Host '  ===========================================' -ForegroundColor Cyan
Write-Host '  Recording Complete' -ForegroundColor Cyan
Write-Host '  ===========================================' -ForegroundColor Cyan
Write-Host ('  Duration:     ' + $duration + ' seconds') -ForegroundColor Green
Write-Host ('  Steps file:   ' + $psrZip) -ForegroundColor Green
if (Test-Path $audioFile) {
    Write-Host ('  Audio file:   ' + $audioFile) -ForegroundColor Green
}
Write-Host ''
Write-Host '  Next step — merge voice with steps and feed to UFO:' -ForegroundColor Yellow
Write-Host ('    cd C:\UFO') -ForegroundColor White
Write-Host ('    .venv\Scripts\python.exe ..\UFO_portable\merge_voice_recording.py ^') -ForegroundColor White
Write-Host ('      --zip "' + $psrZip + '" ^') -ForegroundColor White
Write-Host ('      --audio "' + $audioFile + '" ^') -ForegroundColor White
Write-Host ('      --request "describe the workflow here"') -ForegroundColor White
Write-Host ''

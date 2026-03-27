<#
.SYNOPSIS
    Research benchmark — captures detailed metrics for VLM fine-tuning evaluation.
.DESCRIPTION
    Runs tasks against UFO2 and extracts per-step metrics:
    - Action prediction accuracy (did the agent pick the right control?)
    - Step efficiency (actual steps vs optimal)
    - Latency per LLM inference
    - Screenshot resolution effects
    
    Outputs a detailed CSV suitable for analysis in pandas/Excel.
    
    Usage:
        .\research_benchmark.ps1 -ApiKey "sk-proj-..." -ConfigName datacollect
        .\research_benchmark.ps1 -ApiKey "sk-proj-..." -ConfigName aggressive -Resolution "1280x720"
#>
param(
    [string]$ApiKey,
    [string]$UfoDir = 'C:\UFO',
    [string]$ConfigName = 'datacollect',
    [string]$Resolution,
    [int]$MaxSteps = 15,
    [string]$Model
)

$ErrorActionPreference = 'Continue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configSrc = Join-Path $scriptDir 'configs'
$venvPython = Join-Path $UfoDir '.venv\Scripts\python.exe'

# ──────────────────────────────────────────────────────────────
# Setup
# ──────────────────────────────────────────────────────────────
Write-Host '' -ForegroundColor Cyan
Write-Host '  UFO2 Research Benchmark' -ForegroundColor Cyan
Write-Host '  =======================' -ForegroundColor Cyan
Write-Host ''

# Apply config
$systemSrc = Join-Path $configSrc ('system_' + $ConfigName + '.yaml')
$systemDst = Join-Path $UfoDir 'config\ufo\system.yaml'
if (Test-Path $systemSrc) {
    $sysContent = Get-Content $systemSrc -Raw
    # Override MAX_STEP if specified
    if ($MaxSteps) {
        $sysContent = $sysContent -replace 'MAX_STEP:\s*\d+', ('MAX_STEP: ' + $MaxSteps)
    }
    $sysContent | Set-Content $systemDst -Encoding UTF8
    Write-Host ('  Config: ' + $ConfigName) -ForegroundColor Green
} else {
    Write-Host ('  WARNING: Config ' + $systemSrc + ' not found, using existing') -ForegroundColor Yellow
}

# Apply agent config with API key
$agentsSrc = Join-Path $configSrc ('agents_' + $ConfigName + '.yaml')
if (-not (Test-Path $agentsSrc)) {
    $agentsSrc = Join-Path $configSrc 'agents_conservative.yaml'
}
$agentsDst = Join-Path $UfoDir 'config\ufo\agents.yaml'
$agentsContent = Get-Content $agentsSrc -Raw
if ($ApiKey) {
    $agentsContent = $agentsContent -replace 'YOUR_API_KEY_HERE', $ApiKey
} elseif ($env:OPENAI_API_KEY) {
    $agentsContent = $agentsContent -replace 'YOUR_API_KEY_HERE', $env:OPENAI_API_KEY
}
# Override model if specified
if ($Model) {
    $agentsContent = $agentsContent -replace 'API_MODEL:\s*"[^"]*"', ('API_MODEL: "' + $Model + '"')
    Write-Host ('  Model: ' + $Model) -ForegroundColor Green
}
$agentsContent | Set-Content $agentsDst -Encoding UTF8

# Set resolution if specified
if ($Resolution) {
    Write-Host ('  Resolution: ' + $Resolution) -ForegroundColor Green
    $resParts = $Resolution -split 'x'
    if ($resParts.Count -eq 2) {
        $w = $resParts[0]; $h = $resParts[1]
        # Change display resolution via PowerShell (requires admin)
        try {
            cmd /c "powershell -Command `"Set-DisplayResolution -Width $w -Height $h -Force`" 2>&1" | Out-Null
        } catch {
            Write-Host '    Could not set resolution programmatically' -ForegroundColor Yellow
            Write-Host ('    Set it manually to ' + $Resolution + ' via Display Settings') -ForegroundColor Yellow
        }
    }
} else {
    # Capture current resolution
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $Resolution = $screen.Width.ToString() + 'x' + $screen.Height.ToString()
    } catch {
        $Resolution = 'unknown'
    }
    Write-Host ('  Resolution: ' + $Resolution + ' (current)') -ForegroundColor Green
}

Write-Host ('  MAX_STEP: ' + $MaxSteps) -ForegroundColor Green
Write-Host ''

# ──────────────────────────────────────────────────────────────
# Task definitions with optimal step counts
# ──────────────────────────────────────────────────────────────
$tasks = @(
    @{ Name = 'notepad_type';      Request = 'Open Notepad and type Hello World';                                     OptimalSteps = 3  },
    @{ Name = 'notepad_saveas';    Request = 'Open Notepad, type Test, save as test.txt on Desktop';                  OptimalSteps = 6  },
    @{ Name = 'calc_multiply';     Request = 'Open Calculator and compute 42 times 58';                               OptimalSteps = 3  },
    @{ Name = 'explorer_folder';   Request = 'Open File Explorer and create a new folder on Desktop called TestDir';  OptimalSteps = 5  },
    @{ Name = 'notepad_selectall'; Request = 'Open Notepad, type Hello, select all text, and copy it';                OptimalSteps = 5  }
)

# ──────────────────────────────────────────────────────────────
# Run tasks and collect per-step metrics
# ──────────────────────────────────────────────────────────────
$allMetrics = @()
$taskSummaries = @()

foreach ($task in $tasks) {
    $taskId = $ConfigName + '_' + $Resolution + '_' + $task.Name + '_' + (Get-Date -Format 'HHmmss')
    $request = $task.Request
    $logDir = Join-Path $UfoDir ('logs\' + $taskId)
    
    Write-Host ('  Task: ' + $task.Name) -ForegroundColor White
    Write-Host ('    Request: ' + $request) -ForegroundColor DarkGray
    Write-Host ('    Optimal: ' + $task.OptimalSteps + ' steps') -ForegroundColor DarkGray
    
    # Run UFO
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = cmd /c "cd /d $UfoDir && $venvPython -m ufo --task $taskId -r `"$request`" 2>&1"
    $exitCode = $LASTEXITCODE
    $sw.Stop()
    $totalTime = $sw.Elapsed.TotalSeconds
    
    # Parse output for step-level metrics
    $stepTimes = @()
    $stepActions = @()
    $prevTime = $null
    
    foreach ($line in $output) {
        # Extract step timestamps
        if ($line -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+') {
            $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
            if ($prevTime) {
                $stepTimes += ($ts - $prevTime).TotalSeconds
            }
            $prevTime = $ts
        }
        # Extract actions
        if ($line -match 'Action applied') {
            # Next line has the actual action
        }
        if ($line -match '(click_input|set_edit_text|type_keys|select_application_window|run_shell|set_text|scroll|press_keys|hotkey)') {
            $stepActions += $Matches[1]
        }
    }
    
    # Count actual steps from output
    $stepMatches = $output | Select-String -Pattern 'Step \d+' -AllMatches
    $actualSteps = if ($stepMatches) { ($stepMatches.Matches | ForEach-Object { $_.Value -replace 'Step ', '' } | Measure-Object -Maximum).Maximum } else { 0 }
    
    # Determine success
    $finished = ($output -match 'FINISH') -or ($output -match 'SUCCESS')
    $hitLimit = ($actualSteps -ge $MaxSteps)
    
    # Step efficiency ratio (lower is better, 1.0 = optimal)
    $efficiency = if ($task.OptimalSteps -gt 0 -and $actualSteps -gt 0) { [math]::Round($actualSteps / $task.OptimalSteps, 2) } else { 0 }
    
    # Average latency per step
    $avgLatency = if ($actualSteps -gt 0) { [math]::Round($totalTime / $actualSteps, 1) } else { 0 }
    
    # Count screenshots and UI trees saved
    $screenshotCount = 0; $uitreeCount = 0
    if (Test-Path $logDir) {
        $screenshotCount = (Get-ChildItem -Path $logDir -Filter '*.png' -Recurse -ErrorAction SilentlyContinue).Count
        $uitreeCount = (Get-ChildItem -Path $logDir -Filter '*ui_tree*' -Recurse -ErrorAction SilentlyContinue).Count
    }
    
    # Status color
    $statusText = if ($finished) { 'PASS' } elseif ($hitLimit) { 'LIMIT' } else { 'FAIL' }
    $statusColor = @{ 'PASS' = 'Green'; 'LIMIT' = 'Yellow'; 'FAIL' = 'Red' }[$statusText]
    
    Write-Host ('    Result: ') -NoNewline
    Write-Host $statusText -ForegroundColor $statusColor -NoNewline
    Write-Host (' | Steps: ' + $actualSteps + '/' + $task.OptimalSteps + ' (eff=' + $efficiency + 'x) | Time: ' + [math]::Round($totalTime, 1) + 's | Latency/step: ' + $avgLatency + 's')
    Write-Host ('    Data: ' + $screenshotCount + ' screenshots, ' + $uitreeCount + ' UI trees') -ForegroundColor DarkGray
    Write-Host ''
    
    $taskSummaries += [PSCustomObject]@{
        Config         = $ConfigName
        Resolution     = $Resolution
        Task           = $task.Name
        Status         = $statusText
        ActualSteps    = $actualSteps
        OptimalSteps   = $task.OptimalSteps
        Efficiency     = $efficiency
        TotalTime_Sec  = [math]::Round($totalTime, 1)
        AvgLatency_Sec = $avgLatency
        Screenshots    = $screenshotCount
        UITrees        = $uitreeCount
        ExitCode       = $exitCode
        LogDir         = $logDir
    }
    
    Start-Sleep -Seconds 3
}

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '  RESEARCH METRICS SUMMARY' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ''

$taskSummaries | Format-Table -Property Task, Status, ActualSteps, OptimalSteps, Efficiency, TotalTime_Sec, AvgLatency_Sec -AutoSize

$avgEfficiency = [math]::Round(($taskSummaries | Measure-Object -Property Efficiency -Average).Average, 2)
$avgLatency = [math]::Round(($taskSummaries | Measure-Object -Property AvgLatency_Sec -Average).Average, 1)
$passRate = [math]::Round(($taskSummaries | Where-Object { $_.Status -eq 'PASS' }).Count / $taskSummaries.Count * 100, 0)
$totalScreenshots = ($taskSummaries | Measure-Object -Property Screenshots -Sum).Sum
$totalUITrees = ($taskSummaries | Measure-Object -Property UITrees -Sum).Sum

Write-Host ('  Accuracy (pass rate):     ' + $passRate + '%') -ForegroundColor Yellow
Write-Host ('  Step efficiency (avg):    ' + $avgEfficiency + 'x optimal') -ForegroundColor Yellow
Write-Host ('  Avg latency per step:     ' + $avgLatency + 's') -ForegroundColor Yellow
Write-Host ('  Training data captured:   ' + $totalScreenshots + ' screenshots, ' + $totalUITrees + ' UI trees') -ForegroundColor Yellow
Write-Host ''

# Save CSV
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath = Join-Path $scriptDir ('research_' + $ConfigName + '_' + $Resolution + '_' + $timestamp + '.csv')
$taskSummaries | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ('  CSV: ' + $csvPath) -ForegroundColor Green

# Save detailed summary
$summaryPath = Join-Path $scriptDir ('research_summary_' + $ConfigName + '_' + $Resolution + '.txt')
$summaryLines = @()
$summaryLines += '=========================================='
$summaryLines += ' UFO2 Research Benchmark Results'
$summaryLines += '=========================================='
$summaryLines += ('Date:              ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$summaryLines += ('Config:            ' + $ConfigName)
$summaryLines += ('Resolution:        ' + $Resolution)
$summaryLines += ('MAX_STEP:          ' + $MaxSteps)
if ($Model) { $summaryLines += ('Model override:    ' + $Model) }
$summaryLines += ''
$summaryLines += '--- Aggregate Metrics ---'
$summaryLines += ('Accuracy (pass):   ' + $passRate + '%')
$summaryLines += ('Step efficiency:   ' + $avgEfficiency + 'x (1.0 = optimal)')
$summaryLines += ('Avg latency/step:  ' + $avgLatency + 's')
$summaryLines += ('Data captured:     ' + $totalScreenshots + ' screenshots, ' + $totalUITrees + ' UI trees')
$summaryLines += ''
$summaryLines += '--- Per-Task ---'
foreach ($ts in $taskSummaries) {
    $summaryLines += ('  ' + $ts.Task + ': ' + $ts.Status + ' | ' + $ts.ActualSteps + '/' + $ts.OptimalSteps + ' steps (eff=' + $ts.Efficiency + 'x) | ' + $ts.TotalTime_Sec + 's | ' + $ts.AvgLatency_Sec + 's/step')
}
$summaryLines += ''
$summaryLines += '--- Log Directories ---'
foreach ($ts in $taskSummaries) {
    $summaryLines += ('  ' + $ts.Task + ': ' + $ts.LogDir)
}
[IO.File]::WriteAllLines($summaryPath, $summaryLines)
Write-Host ('  Summary: ' + $summaryPath) -ForegroundColor Green
Write-Host ''

<#
.SYNOPSIS
    Continuous model evaluation pipeline — UFO2 (desktop) + Agent TARS (browser).
.DESCRIPTION
    Reads model_registry.yaml, runs each enabled model through desktop and/or
    browser task suites, collects metrics, and appends to a central CSV.
    
    Usage:
        .\eval_pipeline.ps1 -ApiKey "sk-proj-..."                    # Run all enabled (desktop + browser)
        .\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine ufo        # Desktop tasks only
        .\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine tars       # Browser tasks only
        .\eval_pipeline.ps1 -ApiKey "sk-proj-..." -RunModel "gpt-4o-mini"  # One model
        .\eval_pipeline.ps1 -ListModels                              # Show available models
        .\eval_pipeline.ps1 -ShowResults                             # Show results leaderboard
.NOTES
    Requires: model_registry.yaml in same directory
    Results appended to: eval_results/all_results.csv
#>
param(
    [string]$ApiKey,
    [string]$RunModel,
    [switch]$RunAll,
    [switch]$ListModels,
    [switch]$ShowResults,
    [ValidateSet('all', 'ufo', 'tars')]
    [string]$Engine = 'all',
    [string]$UfoDir = 'C:\UFO',
    [string]$RegistryFile
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RegistryFile) { $RegistryFile = Join-Path $scriptDir 'model_registry.yaml' }

# ──────────────────────────────────────────────────────────────
# Load registry
# ──────────────────────────────────────────────────────────────
$venvPython = Join-Path $UfoDir '.venv\Scripts\python.exe'

# Parse YAML using Python (avoids needing PowerShell YAML module)
$parseScript = @'
import yaml, json, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
'@
$parseScriptPath = Join-Path $env:TEMP 'parse_registry.py'
[IO.File]::WriteAllText($parseScriptPath, $parseScript)
$registryJson = cmd /c ($venvPython + ' ' + $parseScriptPath + ' "' + $RegistryFile + '" 2>&1')
Remove-Item $parseScriptPath -Force -ErrorAction SilentlyContinue

try {
    $registry = $registryJson | ConvertFrom-Json
} catch {
    Write-Host 'ERROR: Could not parse model_registry.yaml' -ForegroundColor Red
    Write-Host $registryJson -ForegroundColor Red
    exit 1
}

$models = $registry.models
# Merge all task lists
$allTasks = @()
if ($registry.desktop_tasks) { $allTasks += $registry.desktop_tasks }
if ($registry.browser_tasks) { $allTasks += $registry.browser_tasks }
if ($registry.auth_browser_tasks) { $allTasks += $registry.auth_browser_tasks }
if ($registry.cross_tasks)   { $allTasks += $registry.cross_tasks }
# Backward compat: if old 'tasks' key exists, use it
if ($registry.tasks -and $allTasks.Count -eq 0) { $allTasks = $registry.tasks }
$settings = $registry.settings
$resultsDir = Join-Path $scriptDir $settings.results_dir
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$allResultsCsv = Join-Path $resultsDir 'all_results.csv'

# Get screen resolution
try {
    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $resolution = $screen.Width.ToString() + 'x' + $screen.Height.ToString()
} catch { $resolution = 'unknown' }

# ──────────────────────────────────────────────────────────────
# List models
# ──────────────────────────────────────────────────────────────
if ($ListModels) {
    Write-Host ''
    Write-Host '  Available Models' -ForegroundColor Cyan
    Write-Host '  ================' -ForegroundColor Cyan
    Write-Host ''
    $modelNames = $models.PSObject.Properties.Name
    foreach ($name in $modelNames) {
        $m = $models.$name
        $status = if ($m.enabled) { '[ON] ' } else { '[OFF]' }
        $color = if ($m.enabled) { 'Green' } else { 'DarkGray' }
        Write-Host ('  ' + $status + ' ' + $name) -ForegroundColor $color -NoNewline
        Write-Host (' - ' + $m.description) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Enable/disable in model_registry.yaml' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ──────────────────────────────────────────────────────────────
# Show results leaderboard
# ──────────────────────────────────────────────────────────────
if ($ShowResults) {
    if (-not (Test-Path $allResultsCsv)) {
        Write-Host '  No results yet. Run the pipeline first.' -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host ''
    Write-Host '  Model Evaluation Leaderboard' -ForegroundColor Cyan
    Write-Host '  ============================' -ForegroundColor Cyan
    Write-Host ''
    
    $data = Import-Csv $allResultsCsv
    $grouped = $data | Group-Object ModelId
    
    $leaderboard = @()
    foreach ($g in $grouped) {
        $passCount = ($g.Group | Where-Object { $_.Status -eq 'PASS' }).Count
        $total = $g.Group.Count
        $avgEff = [math]::Round(($g.Group | Measure-Object -Property Efficiency -Average).Average, 2)
        $avgLat = [math]::Round(($g.Group | Measure-Object -Property AvgLatency_Sec -Average).Average, 1)
        $avgTime = [math]::Round(($g.Group | Measure-Object -Property TotalTime_Sec -Average).Average, 1)
        $lastRun = ($g.Group | Sort-Object Timestamp | Select-Object -Last 1).Timestamp
        
        $leaderboard += [PSCustomObject]@{
            Model      = $g.Name
            PassRate   = [math]::Round($passCount / $total * 100, 0).ToString() + '%'
            AvgStepEff = $avgEff.ToString() + 'x'
            AvgLatency = $avgLat.ToString() + 's'
            AvgTotal   = $avgTime.ToString() + 's'
            Runs       = $total
            LastRun    = $lastRun
        }
    }
    
    $leaderboard | Sort-Object { [double]($_.PassRate -replace '%','') } -Descending | Format-Table -AutoSize
    exit 0
}

# ──────────────────────────────────────────────────────────────
# Determine which models to run
# ──────────────────────────────────────────────────────────────
$modelsToRun = @()
$modelNames = $models.PSObject.Properties.Name

if ($RunModel) {
    if ($modelNames -contains $RunModel) {
        $modelsToRun += $RunModel
    } else {
        Write-Host ('  ERROR: Model "' + $RunModel + '" not found in registry') -ForegroundColor Red
        Write-Host ('  Available: ' + ($modelNames -join ', ')) -ForegroundColor DarkGray
        exit 1
    }
} elseif ($RunAll) {
    $modelsToRun = $modelNames
} else {
    foreach ($name in $modelNames) {
        if ($models.$name.enabled) { $modelsToRun += $name }
    }
}

if ($modelsToRun.Count -eq 0) {
    Write-Host '  No models to run. Enable models in model_registry.yaml or use -RunModel' -ForegroundColor Yellow
    exit 0
}

# Check API key
if (-not $ApiKey -and $env:OPENAI_API_KEY) { $ApiKey = $env:OPENAI_API_KEY }
if (-not $ApiKey) {
    Write-Host '  ERROR: No API key. Use -ApiKey or set OPENAI_API_KEY' -ForegroundColor Red
    exit 1
}

# ──────────────────────────────────────────────────────────────
# Run evaluation
# ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  UFO2 + Agent TARS Evaluation Pipeline' -ForegroundColor Cyan
Write-Host '  ======================================' -ForegroundColor Cyan
Write-Host ('  Models:     ' + ($modelsToRun -join ', ')) -ForegroundColor Green
Write-Host ('  Engine:     ' + $Engine) -ForegroundColor Green
Write-Host ('  Resolution: ' + $resolution) -ForegroundColor Green
Write-Host ('  Max steps:  ' + $settings.max_steps) -ForegroundColor Green

# Filter tasks by engine
$tasksToRun = @()
foreach ($t in $allTasks) {
    $eng = if ($t.engine) { $t.engine } else { 'ufo' }
    if ($Engine -eq 'all' -or $eng -eq $Engine -or $eng -eq 'both') {
        $tasksToRun += $t
    }
}
Write-Host ('  Tasks:      ' + $tasksToRun.Count + ' (' + $Engine + ')') -ForegroundColor Green
Write-Host ''

# Check if TARS is available
$tarsAvailable = $false
if ($Engine -eq 'all' -or $Engine -eq 'tars') {
    $tarsCheck = cmd /c 'agent-tars --version 2>&1'
    if ($tarsCheck -match '\d+\.\d+') {
        $tarsAvailable = $true
        Write-Host ('  Agent TARS: v' + $tarsCheck.Trim()) -ForegroundColor Green
    } else {
        Write-Host '  Agent TARS: not installed (run setup_tars.ps1)' -ForegroundColor Yellow
        if ($Engine -eq 'tars') { exit 1 }
    }
}

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$runId = Get-Date -Format 'yyyyMMdd_HHmmss'

foreach ($modelName in $modelsToRun) {
    $m = $models.$modelName
    
    Write-Host ('  -- Model: ' + $modelName + ' --') -ForegroundColor Yellow
    Write-Host ('     ' + $m.description) -ForegroundColor DarkGray
    
    # Generate UFO agents.yaml for this model
    $agentYaml = @()
    $agentYaml += 'HOST_AGENT:'
    $agentYaml += '  VISUAL_MODE: ' + $m.visual_mode.ToString()
    if ($m.reasoning_model) { $agentYaml += '  REASONING_MODEL: true' } else { $agentYaml += '  REASONING_MODEL: false' }
    $agentYaml += '  API_TYPE: "' + $m.provider + '"'
    $agentYaml += '  API_BASE: "' + $m.api_base + '"'
    $agentYaml += '  API_KEY: "' + $ApiKey + '"'
    $agentYaml += '  API_VERSION: "2025-02-01-preview"'
    $agentYaml += '  API_MODEL: "' + $m.model_id + '"'
    $agentYaml += '  PROMPT: "ufo/prompts/share/base/host_agent.yaml"'
    $agentYaml += '  EXAMPLE_PROMPT: "ufo/prompts/examples/{mode}/host_agent_example.yaml"'
    $agentYaml += ''
    $agentYaml += 'APP_AGENT:'
    $agentYaml += '  VISUAL_MODE: ' + $m.visual_mode.ToString()
    if ($m.reasoning_model) { $agentYaml += '  REASONING_MODEL: true' } else { $agentYaml += '  REASONING_MODEL: false' }
    $agentYaml += '  API_TYPE: "' + $m.provider + '"'
    $agentYaml += '  API_BASE: "' + $m.api_base + '"'
    $agentYaml += '  API_KEY: "' + $ApiKey + '"'
    $agentYaml += '  API_VERSION: "2025-02-01-preview"'
    $agentYaml += '  API_MODEL: "' + $m.model_id + '"'
    $agentYaml += '  PROMPT: "ufo/prompts/share/base/app_agent.yaml"'
    $agentYaml += '  EXAMPLE_PROMPT: "ufo/prompts/examples/{mode}/app_agent_example.yaml"'
    $agentYaml += '  EXAMPLE_PROMPT_AS: "ufo/prompts/examples/{mode}/app_agent_example_as.yaml"'
    $agentYaml += ''
    $agentYaml += 'BACKUP_AGENT:'
    $agentYaml += '  VISUAL_MODE: ' + $m.visual_mode.ToString()
    $agentYaml += '  API_TYPE: "' + $m.provider + '"'
    $agentYaml += '  API_BASE: "' + $m.api_base + '"'
    $agentYaml += '  API_KEY: "' + $ApiKey + '"'
    $agentYaml += '  API_VERSION: "2025-02-01-preview"'
    $agentYaml += '  API_MODEL: "' + $m.model_id + '"'
    
    $agentsDst = Join-Path $UfoDir 'config\ufo\agents.yaml'
    [IO.File]::WriteAllLines($agentsDst, $agentYaml)
    
    # Apply data collection system config
    $sysSrc = Join-Path $scriptDir 'configs\system_datacollect.yaml'
    $sysDst = Join-Path $UfoDir 'config\ufo\system.yaml'
    if (Test-Path $sysSrc) {
        $sysContent = Get-Content $sysSrc -Raw
        $sysContent = $sysContent -replace 'MAX_STEP:\s*\d+', ('MAX_STEP: ' + $settings.max_steps)
        $sysContent = $sysContent -replace 'EVA_SESSION:\s*\w+', 'EVA_SESSION: False'
        $sysContent | Set-Content $sysDst -Encoding UTF8
    }
    
    # Run each task
    foreach ($task in $tasksToRun) {
        $taskEngine = if ($task.engine) { $task.engine } else { 'ufo' }
        $taskId = $runId + '_' + $modelName + '_' + $task.name
        $logDir = Join-Path $UfoDir ('logs\' + $taskId)
        
        # Decide which engine to use
        $useEngine = 'ufo'
        if ($taskEngine -eq 'tars' -and $tarsAvailable) {
            $useEngine = 'tars'
        } elseif ($taskEngine -eq 'both') {
            # cross-engine tasks: run with TARS if available, else UFO
            $useEngine = if ($tarsAvailable) { 'tars' } else { 'ufo' }
        } elseif ($taskEngine -eq 'tars' -and -not $tarsAvailable) {
            Write-Host ('     Task: ' + $task.name + ' -> SKIP (TARS not installed)') -ForegroundColor DarkGray
            continue
        }
        
        $engineLabel = if ($useEngine -eq 'tars') { '[TARS]' } else { '[UFO] ' }
        Write-Host ('     ' + $engineLabel + ' ' + $task.name) -ForegroundColor White -NoNewline
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        
        if ($useEngine -eq 'tars') {
            # Run via Agent TARS CLI
            $tarsCmd = 'agent-tars run --input "' + $task.request + '" --format json --model.provider ' + $m.provider + ' --model.id ' + $m.model_id + ' --model.apiKey ' + $ApiKey + ' --quiet'
            if ($m.api_base -and $m.api_base -ne 'https://api.openai.com/v1') {
                $tarsCmd += ' --model.baseURL ' + $m.api_base
            }
            # Use auth config for tasks that need login
            if ($task.auth_required) {
                $authCfg = Join-Path $scriptDir $settings.tars_auth_config
                if (Test-Path $authCfg) {
                    $tarsCmd += ' --config "' + $authCfg + '"'
                } else {
                    Write-Host ' -> SKIP (auth config not found)' -ForegroundColor DarkGray
                    continue
                }
            }
            $output = cmd /c "$tarsCmd 2>&1"
            $exitCode = $LASTEXITCODE
        } else {
            # Run via UFO
            $output = cmd /c "cd /d $UfoDir && $venvPython -m ufo --task $taskId -r `"$($task.request)`" 2>&1"
            $exitCode = $LASTEXITCODE
        }
        
        $sw.Stop()
        $totalTime = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        
        # Parse step count
        $actualSteps = 0
        if ($useEngine -eq 'tars') {
            # TARS: count tool_call occurrences in output
            $tarsSteps = ($output | Select-String -Pattern 'tool_call|action|navigate|click|type' -AllMatches)
            $actualSteps = if ($tarsSteps) { [math]::Max(1, $tarsSteps.Matches.Count) } else { 1 }
        } else {
            # UFO: count Step N from output
            $stepMatches = $output | Select-String -Pattern 'Step (\d+)' -AllMatches
            if ($stepMatches) {
                $nums = $stepMatches.Matches | ForEach-Object { [int]$_.Groups[1].Value }
                $actualSteps = ($nums | Measure-Object -Maximum).Maximum
            }
        }
        
        # Determine status
        $finished = ($output -match 'FINISH') -or ($output -match 'SUCCESS') -or ($exitCode -eq 0 -and $useEngine -eq 'tars')
        $hitLimit = ($actualSteps -ge $settings.max_steps)
        $statusText = if ($finished) { 'PASS' } elseif ($hitLimit) { 'LIMIT' } else { 'FAIL' }
        
        # Efficiency
        $optSteps = $task.optimal_steps
        $efficiency = if ($optSteps -gt 0 -and $actualSteps -gt 0) { [math]::Round($actualSteps / $optSteps, 2) } else { 0 }
        $avgLatency = if ($actualSteps -gt 0) { [math]::Round($totalTime / $actualSteps, 1) } else { 0 }
        
        # Count data collected (UFO only)
        $screenshots = 0; $uitrees = 0
        if ($useEngine -eq 'ufo' -and (Test-Path $logDir)) {
            $screenshots = (Get-ChildItem -Path $logDir -Filter '*.png' -Recurse -ErrorAction SilentlyContinue).Count
            $uitrees = (Get-ChildItem -Path $logDir -Filter '*ui_tree*' -Recurse -ErrorAction SilentlyContinue).Count
        }
        
        # Print result
        $statusColor = @{ 'PASS' = 'Green'; 'LIMIT' = 'Yellow'; 'FAIL' = 'Red' }[$statusText]
        Write-Host (' -> ') -NoNewline
        Write-Host $statusText -ForegroundColor $statusColor -NoNewline
        Write-Host (' ' + $actualSteps + '/' + $optSteps + ' steps, ' + $totalTime + 's, ' + $avgLatency + 's/step')
        
        # Append to central CSV
        $row = [PSCustomObject]@{
            Timestamp      = $timestamp
            RunId          = $runId
            ModelId        = $m.model_id
            ModelName      = $modelName
            Provider       = $m.provider
            VisualMode     = $m.visual_mode
            Task           = $task.name
            Request        = $task.request
            Status         = $statusText
            ActualSteps    = $actualSteps
            OptimalSteps   = $optSteps
            Efficiency     = $efficiency
            TotalTime_Sec  = $totalTime
            AvgLatency_Sec = $avgLatency
            Engine         = $useEngine
            Screenshots    = $screenshots
            UITrees        = $uitrees
            Resolution     = $resolution
            MaxSteps       = $settings.max_steps
            ExitCode       = $exitCode
            LogDir         = $logDir
        }
        
        # Append to CSV (create header if first row)
        $csvExists = Test-Path $allResultsCsv
        if ($csvExists) {
            $row | Export-Csv -Path $allResultsCsv -Append -NoTypeInformation
        } else {
            $row | Export-Csv -Path $allResultsCsv -NoTypeInformation
        }
        
        Start-Sleep -Seconds $settings.sleep_between_tasks
    }
    
    Write-Host ''
    Start-Sleep -Seconds $settings.sleep_between_models
}

# ──────────────────────────────────────────────────────────────
# Print summary
# ──────────────────────────────────────────────────────────────
Write-Host '  ===============================' -ForegroundColor Cyan
Write-Host '  Evaluation Complete' -ForegroundColor Cyan
Write-Host '  ===============================' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  Results: ' + $allResultsCsv) -ForegroundColor Green
Write-Host ''
Write-Host '  View leaderboard:  .\eval_pipeline.ps1 -ShowResults' -ForegroundColor DarkGray
Write-Host '  List models:       .\eval_pipeline.ps1 -ListModels' -ForegroundColor DarkGray
Write-Host ''

# Show quick leaderboard for this run
$thisRun = Import-Csv $allResultsCsv | Where-Object { $_.RunId -eq $runId }
if ($thisRun) {
    $grouped = $thisRun | Group-Object ModelName
    foreach ($g in $grouped) {
        $passCount = ($g.Group | Where-Object { $_.Status -eq 'PASS' }).Count
        $total = $g.Group.Count
        $avgLat = [math]::Round(($g.Group | Measure-Object -Property AvgLatency_Sec -Average).Average, 1)
        $avgEff = [math]::Round(($g.Group | Measure-Object -Property Efficiency -Average).Average, 2)
        Write-Host ('  ' + $g.Name + ': ' + $passCount + '/' + $total + ' passed, ' + $avgEff + 'x efficiency, ' + $avgLat + 's/step') -ForegroundColor Yellow
    }
    Write-Host ''
}

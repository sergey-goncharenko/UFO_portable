<#
.SYNOPSIS
    Benchmark runner for UFO2 A/B config comparison.
.DESCRIPTION
    Runs a set of test tasks against UFO2, measures wall-clock time and success.
    Use on two VMs with different configs to compare.
    
    Usage:
        .\benchmark.ps1 -ConfigName "conservative" -ApiKey "sk-proj-..."
        .\benchmark.ps1 -ConfigName "aggressive" -ApiKey "sk-proj-..."
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('conservative', 'aggressive')]
    [string]$ConfigName,
    
    [string]$ApiKey,
    [string]$UfoDir = 'C:\UFO',
    [int]$Runs = 1
)

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------
# Setup: copy the chosen config into UFO
# ------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configSrc = Join-Path $scriptDir 'configs'

$systemSrc = Join-Path $configSrc ('system_' + $ConfigName + '.yaml')
$agentsSrc = Join-Path $configSrc ('agents_' + $ConfigName + '.yaml')

$systemDst = Join-Path $UfoDir 'config\ufo\system.yaml'
$agentsDst = Join-Path $UfoDir 'config\ufo\agents.yaml'

Write-Host ''
Write-Host ('  UFO2 Benchmark - ' + $ConfigName.ToUpper() + ' config') -ForegroundColor Cyan
Write-Host '  ===========================================' -ForegroundColor Cyan
Write-Host ''

# Copy system config
Copy-Item $systemSrc $systemDst -Force
Write-Host ('  Applied: ' + $systemSrc) -ForegroundColor Green

# Copy agents config and inject API key
$agentsContent = Get-Content $agentsSrc -Raw
if ($ApiKey) {
    $agentsContent = $agentsContent -replace 'YOUR_API_KEY_HERE', $ApiKey
} elseif ($env:OPENAI_API_KEY) {
    $agentsContent = $agentsContent -replace 'YOUR_API_KEY_HERE', $env:OPENAI_API_KEY
} else {
    Write-Host '  ERROR: No API key. Use -ApiKey or set OPENAI_API_KEY' -ForegroundColor Red
    exit 1
}
$agentsContent | Set-Content $agentsDst -Encoding UTF8
Write-Host ('  Applied: ' + $agentsSrc + ' (key injected)') -ForegroundColor Green
Write-Host ''

# ------------------------------------------------------------------
# Test tasks
# ------------------------------------------------------------------
$tasks = @(
    @{ Name = 'notepad_type';    Request = 'Open Notepad and type Hello World' },
    @{ Name = 'notepad_save';    Request = 'Open Notepad, type Benchmark Test, then save the file to Desktop as benchmark_test.txt' },
    @{ Name = 'calculator';      Request = 'Open Calculator and compute 42 times 58' },
    @{ Name = 'explorer_folder'; Request = 'Open File Explorer and create a new folder called BenchmarkTest on the Desktop' }
)

$venvPython = Join-Path $UfoDir '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    $venvPython = 'python'
}

# ------------------------------------------------------------------
# Run benchmark
# ------------------------------------------------------------------
$results = @()

foreach ($run in 1..$Runs) {
    Write-Host ('  === Run ' + $run + ' of ' + $Runs + ' ===') -ForegroundColor Yellow
    Write-Host ''
    
    foreach ($task in $tasks) {
        $taskName = $ConfigName + '_' + $task.Name + '_run' + $run
        $request = $task.Request
        
        Write-Host ('  Task: ' + $task.Name) -ForegroundColor White -NoNewline
        Write-Host (' - ' + $request) -ForegroundColor DarkGray
        
        # Measure execution time
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        
        $output = cmd /c ($venvPython + ' -m ufo --task ' + $taskName + ' -r "' + $request + '" 2>&1')
        $exitCode = $LASTEXITCODE
        
        $sw.Stop()
        $elapsed = $sw.Elapsed.TotalSeconds
        
        # Check for success markers in output
        $success = ($output -match 'FINISH') -or ($output -match 'SUCCESS')
        $statusText = if ($success) { 'PASS' } else { 'FAIL' }
        $statusColor = if ($success) { 'Green' } else { 'Red' }
        
        # Count LLM calls (look for "Round" or "Step" markers)
        $steps = ($output | Select-String -Pattern 'Step \d+' -AllMatches).Matches.Count
        
        Write-Host ('    Result: ') -NoNewline
        Write-Host $statusText -ForegroundColor $statusColor -NoNewline
        Write-Host (' | Time: ' + [math]::Round($elapsed, 1) + 's | Steps: ' + $steps)
        
        $results += [PSCustomObject]@{
            Config   = $ConfigName
            Run      = $run
            Task     = $task.Name
            Status   = $statusText
            Time_Sec = [math]::Round($elapsed, 1)
            Steps    = $steps
            ExitCode = $exitCode
        }
        
        # Brief pause between tasks
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host ''
Write-Host '  ===========================================' -ForegroundColor Cyan
Write-Host ('  RESULTS SUMMARY - ' + $ConfigName.ToUpper()) -ForegroundColor Cyan
Write-Host '  ===========================================' -ForegroundColor Cyan
Write-Host ''

$results | Format-Table -AutoSize

# Calculate averages
$avgTime = ($results | Measure-Object -Property Time_Sec -Average).Average
$passRate = ($results | Where-Object { $_.Status -eq 'PASS' }).Count / $results.Count * 100

Write-Host ('  Average time: ' + [math]::Round($avgTime, 1) + ' seconds') -ForegroundColor Yellow
Write-Host ('  Pass rate:    ' + [math]::Round($passRate, 0) + '%') -ForegroundColor Yellow
Write-Host ''

# Save results to CSV for comparison
$csvPath = Join-Path $scriptDir ('benchmark_' + $ConfigName + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ('  Results saved to: ' + $csvPath) -ForegroundColor Green

# Also save a quick summary
$summaryPath = Join-Path $scriptDir ('summary_' + $ConfigName + '.txt')
$summary = @(
    ('Config: ' + $ConfigName),
    ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('Tasks: ' + $results.Count),
    ('Average time: ' + [math]::Round($avgTime, 1) + 's'),
    ('Pass rate: ' + [math]::Round($passRate, 0) + '%'),
    '',
    'Per-task breakdown:'
)
foreach ($task in $tasks) {
    $taskResults = $results | Where-Object { $_.Task -eq $task.Name }
    $taskAvg = ($taskResults | Measure-Object -Property Time_Sec -Average).Average
    $taskPass = ($taskResults | Where-Object { $_.Status -eq 'PASS' }).Count
    $summary += ('  ' + $task.Name + ': avg ' + [math]::Round($taskAvg, 1) + 's, ' + $taskPass + '/' + $taskResults.Count + ' passed')
}
$summary | Set-Content $summaryPath
Write-Host ('  Summary saved to: ' + $summaryPath) -ForegroundColor Green
Write-Host ''

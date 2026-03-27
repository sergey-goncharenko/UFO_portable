<#
.SYNOPSIS
    Compare benchmark results from two VMs side-by-side.
.DESCRIPTION
    After running benchmark.ps1 on both VMs, copy the CSV files here
    and run this script to see a comparison.
    
    Usage:
        .\compare_results.ps1
#>
param(
    [string]$ScriptDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

Write-Host ''
Write-Host '  UFO2 A/B Benchmark Comparison' -ForegroundColor Cyan
Write-Host '  =============================' -ForegroundColor Cyan
Write-Host ''

# Find summary files
$conSummary = Join-Path $ScriptDir 'summary_conservative.txt'
$aggSummary = Join-Path $ScriptDir 'summary_aggressive.txt'

if ((Test-Path $conSummary) -and (Test-Path $aggSummary)) {
    Write-Host '  --- CONSERVATIVE (VM A) ---' -ForegroundColor Green
    Get-Content $conSummary | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host '  --- AGGRESSIVE (VM B) ---' -ForegroundColor Yellow
    Get-Content $aggSummary | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
} else {
    Write-Host '  Summary files not found. Looking for CSVs...' -ForegroundColor DarkGray
}

# Find CSV files
$csvFiles = Get-ChildItem -Path $ScriptDir -Filter 'benchmark_*.csv' | Sort-Object Name
if ($csvFiles.Count -eq 0) {
    Write-Host '  No benchmark CSVs found. Run benchmark.ps1 on both VMs first.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  VM A (conservative): .\benchmark.ps1 -ConfigName conservative -ApiKey sk-...' -ForegroundColor DarkGray
    Write-Host '  VM B (aggressive):   .\benchmark.ps1 -ConfigName aggressive -ApiKey sk-...' -ForegroundColor DarkGray
    exit 0
}

Write-Host '  Found CSV files:' -ForegroundColor DarkGray
$csvFiles | ForEach-Object { Write-Host ('    ' + $_.Name) -ForegroundColor DarkGray }
Write-Host ''

# Load and compare
$allResults = @()
foreach ($csv in $csvFiles) {
    $data = Import-Csv $csv.FullName
    $allResults += $data
}

# Group by config
$configs = $allResults | Group-Object Config

Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '  SIDE-BY-SIDE COMPARISON' -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host ''

$taskNames = $allResults | Select-Object -ExpandProperty Task -Unique

Write-Host ('  {0,-20} {1,>15} {2,>15} {3,>10}' -f 'Task', 'Conservative', 'Aggressive', 'Speedup')
Write-Host ('  {0,-20} {1,>15} {2,>15} {3,>10}' -f '----', '------------', '----------', '-------')

foreach ($task in $taskNames) {
    $conResults = $allResults | Where-Object { $_.Config -eq 'conservative' -and $_.Task -eq $task }
    $aggResults = $allResults | Where-Object { $_.Config -eq 'aggressive' -and $_.Task -eq $task }
    
    $conAvg = if ($conResults) { [math]::Round(($conResults | Measure-Object -Property Time_Sec -Average).Average, 1) } else { '-' }
    $aggAvg = if ($aggResults) { [math]::Round(($aggResults | Measure-Object -Property Time_Sec -Average).Average, 1) } else { '-' }
    
    $speedup = '-'
    if ($conResults -and $aggResults -and $conAvg -gt 0) {
        $speedup = [math]::Round(($conAvg - $aggAvg) / $conAvg * 100, 0).ToString() + '%'
    }
    
    Write-Host ('  {0,-20} {1,>12}s {2,>12}s {3,>10}' -f $task, $conAvg, $aggAvg, $speedup)
}

Write-Host ''

# Overall
foreach ($cfg in $configs) {
    $avg = [math]::Round(($cfg.Group | Measure-Object -Property Time_Sec -Average).Average, 1)
    $passCount = ($cfg.Group | Where-Object { $_.Status -eq 'PASS' }).Count
    $total = $cfg.Group.Count
    Write-Host ('  ' + $cfg.Name.ToUpper() + ': avg ' + $avg + 's, pass rate ' + $passCount + '/' + $total) -ForegroundColor Yellow
}
Write-Host ''

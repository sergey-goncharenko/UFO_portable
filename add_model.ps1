<#
.SYNOPSIS
    Quick-add a new model to the evaluation pipeline.
.DESCRIPTION
    Adds a model entry to model_registry.yaml and optionally runs it immediately.
    
    Usage:
        .\add_model.ps1 -Name "gpt-5" -ModelId "gpt-5" -Description "GPT-5 flagship"
        .\add_model.ps1 -Name "my-local" -ModelId "my-model" -ApiBase "http://localhost:8000/v1" -RunNow
#>
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$ModelId,
    [string]$Provider = 'openai',
    [string]$ApiBase = 'https://api.openai.com/v1',
    [string]$Description = '',
    [switch]$Visual = $true,
    [switch]$Reasoning,
    [switch]$RunNow,
    [string]$ApiKey
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$regFile = Join-Path $scriptDir 'model_registry.yaml'

if (-not $Description) { $Description = $ModelId }

# Build YAML entry
$entry = @()
$entry += ''
$entry += ('  ' + $Name + ':')
$entry += ('    provider: ' + $Provider)
$entry += ('    api_base: "' + $ApiBase + '"')
$entry += ('    model_id: "' + $ModelId + '"')
$entry += ('    visual_mode: ' + $Visual.ToString().ToLower())
if ($Reasoning) { $entry += '    reasoning_model: true' }
$entry += ('    description: "' + $Description + '"')
$entry += '    enabled: true'

# Find the line after the last model entry (before "tasks:" section)
$content = Get-Content $regFile
$insertIndex = -1
for ($i = 0; $i -lt $content.Count; $i++) {
    if ($content[$i] -match '^tasks:') {
        $insertIndex = $i
        break
    }
}

if ($insertIndex -gt 0) {
    $newContent = @()
    $newContent += $content[0..($insertIndex - 1)]
    $newContent += $entry
    $newContent += ''
    $newContent += $content[$insertIndex..($content.Count - 1)]
    $newContent | Set-Content $regFile -Encoding UTF8
    Write-Host ('  Added model: ' + $Name + ' (' + $ModelId + ')') -ForegroundColor Green
    Write-Host ('  Registry: ' + $regFile) -ForegroundColor DarkGray
} else {
    Write-Host '  ERROR: Could not find insertion point in model_registry.yaml' -ForegroundColor Red
    exit 1
}

if ($RunNow) {
    Write-Host '  Running evaluation...' -ForegroundColor Yellow
    $evalScript = Join-Path $scriptDir 'eval_pipeline.ps1'
    $evalArgs = '-RunModel "' + $Name + '"'
    if ($ApiKey) { $evalArgs += ' -ApiKey "' + $ApiKey + '"' }
    powershell -ExecutionPolicy Bypass -File $evalScript $evalArgs
}

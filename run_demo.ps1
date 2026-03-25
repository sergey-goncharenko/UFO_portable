<#
.SYNOPSIS
    Guided UFO² demo with pre-built scenarios.
.DESCRIPTION
    Interactive demo launcher with curated tasks that showcase UFO2 capabilities.
    Run on the target VM after setup_ufo.ps1 has been executed.
#>
param(
    [string]$UfoDir = "C:\UFO"
)

$venvPython = "$UfoDir\.venv\Scripts\python.exe"

if (-not (Test-Path $venvPython)) {
    Write-Host "ERROR: UFO not installed. Run setup_ufo.ps1 first." -ForegroundColor Red
    exit 1
}

function Run-UfoTask {
    param([string]$TaskName, [string]$Request)
    Write-Host "`n  Running: $Request" -ForegroundColor Yellow
    Write-Host "  (Watch your desktop - UFO is working!)`n" -ForegroundColor DarkGray
    Push-Location $UfoDir
    & $venvPython -m ufo --task $TaskName -r $Request
    Pop-Location
}

while ($true) {
    Write-Host @"

  ╔══════════════════════════════════════════════════╗
  ║          UFO2 Desktop AgentOS - Demo             ║
  ╠══════════════════════════════════════════════════╣
  ║                                                  ║
  ║  1. Notepad Magic                                ║
  ║     Open Notepad and type a message              ║
  ║                                                  ║
  ║  2. VS Code Settings                             ║
  ║     Change a VS Code setting via natural lang    ║
  ║                                                  ║
  ║  3. Web Search                                   ║
  ║     Open browser and search for something        ║
  ║                                                  ║
  ║  4. File Explorer                                ║
  ║     Create a folder on the Desktop               ║
  ║                                                  ║
  ║  5. Calculator                                   ║
  ║     Open Calculator and perform a calculation    ║
  ║                                                  ║
  ║  6. Custom Command                               ║
  ║     Type your own natural language request       ║
  ║                                                  ║
  ║  7. Interactive Mode                             ║
  ║     Multi-turn conversation with UFO             ║
  ║                                                  ║
  ║  Q. Quit                                         ║
  ║                                                  ║
  ╚══════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

    $choice = Read-Host "  Select a demo (1-7, Q to quit)"

    switch ($choice.Trim().ToLower()) {
        "1" {
            Run-UfoTask "demo_notepad" "Open Notepad and type 'Hello from UFO! AI is controlling this desktop right now.'"
        }
        "2" {
            Run-UfoTask "demo_vscode" "Open VS Code settings and enable word wrap"
        }
        "3" {
            $query = Read-Host "  What to search for? (default: 'Microsoft UFO desktop agent')"
            if (-not $query) { $query = "Microsoft UFO desktop agent" }
            Run-UfoTask "demo_web" "Open Microsoft Edge and search for '$query'"
        }
        "4" {
            Run-UfoTask "demo_files" "Open File Explorer and create a new folder called 'UFO_Demo' on the Desktop"
        }
        "5" {
            Run-UfoTask "demo_calc" "Open Calculator and compute 42 times 58"
        }
        "6" {
            $custom = Read-Host "  Enter your command"
            if ($custom) {
                Run-UfoTask "demo_custom_$(Get-Random)" $custom
            }
        }
        "7" {
            Write-Host "`n  Starting interactive mode. Type 'quit' to return to this menu." -ForegroundColor Yellow
            Push-Location $UfoDir
            & $venvPython -m ufo --task demo_interactive
            Pop-Location
        }
        { $_ -in "q", "quit", "exit" } {
            Write-Host "`n  Bye!" -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "  Invalid choice. Try 1-7 or Q." -ForegroundColor Red
        }
    }

    Write-Host "`n  Press Enter to continue..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

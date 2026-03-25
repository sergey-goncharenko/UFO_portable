# UFO² Portable Demo Kit

One-click scripts to install, package, and demo [Microsoft UFO²](https://github.com/microsoft/UFO) (Desktop AgentOS) on any Windows VM.

UFO² is an LLM-powered desktop automation agent that takes natural language commands and executes them via Windows UI Automation — mouse clicks, keyboard input, and native API calls.

## What's Inside

| Script | Purpose |
|---|---|
| `setup_ufo.ps1` | **One-click install** on a fresh Windows VM — installs Python, clones UFO, creates venv, installs deps, configures API key, creates desktop shortcuts |
| `run_demo.ps1` | **Interactive demo menu** with 7 curated scenarios (Notepad, VS Code, web search, file management, calculator, custom, interactive) |
| `package_offline.ps1` | **Package builder** — creates a portable ZIP you can transfer to air-gapped or restricted VMs |
| `VM_SETUP.md` | Detailed VM requirements, troubleshooting, and step-by-step guide |

## Quick Start

### On a VM with internet

```powershell
# Download and run the setup script
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1 -ApiKey "sk-proj-YOUR_KEY"

# Or use environment variable
$env:OPENAI_API_KEY = "sk-proj-..."
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1

# Or let it prompt you
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1
```

Then launch the demo:
```powershell
powershell -ExecutionPolicy Bypass -File run_demo.ps1
```

### For offline VMs

On your machine (with UFO already installed at C:\UFO):
```powershell
# Lightweight package (~50 MB, VM needs internet for pip install)
powershell -ExecutionPolicy Bypass -File package_offline.ps1

# Fully offline package (~2 GB, includes pre-built venv)
powershell -ExecutionPolicy Bypass -File package_offline.ps1 -IncludeVenv
```

Copy the ZIP to the target VM, extract, run `FIRST_RUN.bat`, add your API key, run `START_DEMO.bat`.

## VM Requirements

- **OS:** Windows 10/11 (x64)
- **RAM:** 8 GB min (16 GB recommended)
- **Disk:** 10 GB free
- **Display:** 1920×1080 recommended (UFO uses screenshots)
- **Network:** Required for OpenAI API calls
- **Session:** Interactive desktop (RDP works, but keep the window open and unlocked)

## Demo Scenarios

The `run_demo.ps1` menu offers:

1. **Notepad Magic** — Opens Notepad and types text via natural language
2. **VS Code Settings** — Changes VS Code configuration
3. **Web Search** — Opens Edge and searches the web
4. **File Explorer** — Creates folders on the Desktop
5. **Calculator** — Opens Calculator and performs math
6. **Custom Command** — Type your own natural language request
7. **Interactive Mode** — Multi-turn conversation with UFO

## How It Works

```
You say: "Open Notepad and type Hello World"
         │
         ▼
   ┌─────────────┐    screenshot    ┌──────────┐
   │  HostAgent  │ ◄──────────────► │ GPT-4o   │
   │ (orchestrator)│    + UIA tree   │ (vision) │
   └──────┬──────┘                  └──────────┘
          │ delegates
          ▼
   ┌─────────────┐    set_edit_text  ┌──────────┐
   │  AppAgent   │ ────────────────► │ Notepad  │
   │ (notepad.exe)│                  │          │
   └─────────────┘                  └──────────┘
```

UFO² uses Windows UI Automation to identify controls, GPT-4o (with vision) to plan actions, and a hybrid GUI+API execution strategy for reliability.

## Credits

- **UFO²** by Microsoft Research — [github.com/microsoft/UFO](https://github.com/microsoft/UFO)
- Paper: [UFO2: The Desktop AgentOS](https://arxiv.org/abs/2504.14603)

## License

Demo scripts in this repo: MIT  
UFO² itself: [MIT License](https://github.com/microsoft/UFO/blob/main/LICENSE)

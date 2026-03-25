# UFO² Demo VM Setup Guide

## VM Requirements

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 (x64) |
| **RAM** | 8 GB minimum (16 GB recommended) |
| **Disk** | 10 GB free space |
| **Display** | 1920x1080 recommended (UFO uses screenshots) |
| **Network** | Required for OpenAI API calls |
| **Python** | 3.10+ (installer included in setup script) |
| **Apps to demo** | Notepad, Edge, File Explorer, Calculator (all pre-installed on Windows) |

> **Important:** UFO needs an interactive desktop session. RDP works fine, but make sure the
> VM display resolution is set and the desktop is visible (not locked/minimized).

---

## Option A: One-Click Setup (VM has internet)

Copy `demo\setup_ufo.ps1` to the VM and run:

```powershell
# With API key as parameter
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1 -ApiKey "sk-proj-..."

# Or using environment variable
$env:OPENAI_API_KEY = "sk-proj-..."
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1

# Or it will prompt you to enter the key
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1
```

This automatically:
1. Installs Python 3.11 (if missing)
2. Clones UFO from GitHub
3. Creates a venv and installs all dependencies
4. Configures the API key
5. Creates desktop shortcuts and launcher scripts

Then run: `START_DEMO.bat` or `demo\run_demo.ps1`

---

## Option B: Portable ZIP Package (minimal VM internet)

Build the package on your current machine:

```powershell
# Lightweight package (~50 MB) — VM needs internet for pip install
cd C:\UFO
powershell -ExecutionPolicy Bypass -File demo\package_offline.ps1

# Full offline package (~2 GB) — VM needs NO internet for deps
powershell -ExecutionPolicy Bypass -File demo\package_offline.ps1 -IncludeVenv
```

On the target VM:
1. Copy `ufo_portable.zip` to the VM
2. Extract to `C:\UFO`
3. Run `FIRST_RUN.bat` (skipped if you used `-IncludeVenv`)
4. Edit `config\ufo\agents.yaml` — add your OpenAI API key
5. Run `START_DEMO.bat`

---

## Option C: Pre-baked VM Image (best for repeated demos)

1. Create a Windows VM (Hyper-V, VMware, VirtualBox)
2. Run Option A setup
3. Verify demos work
4. Snapshot / export the VM
5. Duplicate for each demo session

---

## Running the Demo

### Interactive Demo Menu
```powershell
.\START_DEMO.bat
# or
powershell -ExecutionPolicy Bypass -File demo\run_demo.ps1
```

Offers curated demos:
1. **Notepad Magic** — Opens Notepad and types text
2. **VS Code Settings** — Changes a VS Code setting
3. **Web Search** — Opens Edge and searches
4. **File Explorer** — Creates folders
5. **Calculator** — Performs calculations
6. **Custom Command** — Your own request
7. **Interactive Mode** — Free-form conversation

### Direct Commands
```powershell
cd C:\UFO
.venv\Scripts\python.exe -m ufo --task my_demo -r "Open Notepad and type Hello"
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `404 /v1/chat/completions/chat/completions` | Change `API_BASE` in agents.yaml to `https://api.openai.com/v1` (remove `/chat/completions`) |
| `pandas won't build` | Use `requirements_vm.txt` or change `pandas==1.4.3` to `pandas>=1.5.0` |
| UFO can't see UI elements | Ensure you're in an interactive desktop session (not a service), try a higher resolution |
| RDP session is locked | UFO needs the desktop visible — keep the RDP window open and active |
| `pywinauto` import fails | Only works on Windows — this is expected |
| Screenshots are black | VM display adapter must be active, not using "basic display" |

## API Key Security

- **Never** hardcode keys in scripts committed to git
- Use `$env:OPENAI_API_KEY` or enter at runtime via `Read-Host -AsSecureString`
- The `package_offline.ps1` script automatically strips keys from packaged configs

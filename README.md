# UFO Portable — Desktop & Browser AI Agent Toolkit

One-click deployment, benchmarking, and workflow recording for AI desktop/browser automation on Windows VMs.

Combines [Microsoft UFO2](https://github.com/microsoft/UFO) (desktop automation) and [Agent TARS](https://github.com/bytedance/UI-TARS-desktop) (browser automation) into a unified evaluation and deployment platform.

## What This Does

- **Deploy** UFO2 + Agent TARS on any Windows VM in one command
- **Benchmark** different LLM models (GPT-4o, GPT-4o-mini, Claude, local models) against a task suite
- **Record** business workflows with voice narration and convert to replayable automation
- **Compare** desktop (UFO) vs browser (TARS) engines side-by-side
- **Monitor** the agent working via AnyDesk view-only mode

## Quick Start

```powershell
git clone https://github.com/sergey-goncharenko/UFO_portable.git
cd UFO_portable

# One-click setup (installs UFO2 + Agent TARS + AnyDesk + Python)
powershell -ExecutionPolicy Bypass -File setup_ufo.ps1 -ApiKey "sk-proj-YOUR_KEY"

# Run a desktop task
C:\UFO\ufo_run.bat "Open Notepad and type Hello World"

# Run a browser task
agent-tars run --input "Search Google for best CRM for small business"

# Run the full evaluation pipeline
.\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine all
```

## Repository Structure

### Setup & Deployment

| File | Description |
|---|---|
| `setup_ufo.ps1` | **Main installer** — Python 3.11, UFO2, Agent TARS, AnyDesk, config, desktop shortcuts. One command does everything. |
| `setup_tars.ps1` | Standalone Agent TARS installer (Node.js 22, Chrome check, browser profile setup) |
| `package_offline.ps1` | Package the install into a portable ZIP for offline/air-gapped VMs |
| `run_demo.ps1` | Interactive demo menu with 7 curated scenarios |

### Benchmarking & Evaluation

| File | Description |
|---|---|
| `eval_pipeline.ps1` | **Main evaluation pipeline** — runs models through task suites, collects metrics to CSV, shows leaderboard |
| `model_registry.yaml` | Central config for all models (OpenAI, Anthropic, Azure, local) + task definitions |
| `add_model.ps1` | Quick-add a new model to the registry |
| `benchmark.ps1` | A/B config comparison (conservative vs aggressive) |
| `compare_results.ps1` | Side-by-side results viewer |
| `research_benchmark.ps1` | Detailed per-step metrics for VLM research (accuracy, efficiency, latency) |

### Workflow Recording

| File | Description |
|---|---|
| `start_recording.ps1` | Launches Steps Recorder + microphone recording simultaneously. Falls back to FFmpeg screen capture if PSR is deprecated. |
| `merge_voice_recording.py` | Transcribes voice (Whisper), matches to steps, outputs universal `workflow.json` + UFO-ready ZIP + TARS replay script |

### Configs

| File | Description |
|---|---|
| `configs/system_conservative.yaml` | Safe speed optimizations for UFO |
| `configs/system_aggressive.yaml` | Maximum speed, some accuracy tradeoff |
| `configs/system_datacollect.yaml` | Full data capture for training/research |
| `configs/agents_*.yaml` | Agent configs for each profile (model, vision mode, etc.) |

## Evaluation Pipeline

### Add models to test

Edit `model_registry.yaml` or use the quick-add script:

```powershell
# Add a new model
.\add_model.ps1 -Name "gpt-5" -ModelId "gpt-5" -Description "GPT-5 flagship"

# Add a local model
.\add_model.ps1 -Name "qwen-vl" -ModelId "Qwen2-VL-7B" -ApiBase "http://localhost:8000/v1"
```

Pre-configured models: `gpt-4o`, `gpt-4o-mini`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`, `o4-mini`, `claude-sonnet-4`

### Run evaluations

```powershell
# All enabled models, all tasks (desktop + browser)
.\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine all

# Desktop tasks only (UFO)
.\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine ufo

# Browser tasks only (Agent TARS)
.\eval_pipeline.ps1 -ApiKey "sk-proj-..." -Engine tars

# Single model
.\eval_pipeline.ps1 -ApiKey "sk-proj-..." -RunModel "gpt-4o-mini"

# View leaderboard
.\eval_pipeline.ps1 -ShowResults
```

### Task suite (16 tasks)

| Engine | Tasks | What they test |
|---|---|---|
| **UFO** (desktop) | 5 tasks | Notepad, Calculator, File Explorer, keyboard shortcuts |
| **TARS** (browser, public) | 5 tasks | Google search, Wikipedia, GitHub, form fill, multi-tab research |
| **TARS** (browser, authenticated) | 5 tasks | Outlook email, Google Drive, Calendar, Teams, SharePoint |
| **Cross-engine** | 1 task | Same task on both engines for comparison |

### Metrics collected

- **Pass rate** — did the model complete the task?
- **Step efficiency** — actual steps / optimal steps (1.0x = perfect)
- **Latency per step** — LLM inference time
- **Training data** — screenshots + UI trees captured per run

All results accumulate in `eval_results/all_results.csv` for trend tracking.

## Workflow Recording

Record a business owner demonstrating a workflow, then convert it to automation:

```powershell
# 1. Start recording (Steps Recorder + microphone)
.\start_recording.ps1 -Name "check_invoices"

# 2. Business owner does the workflow while narrating
#    "I'm opening QuickBooks... clicking on Invoices... filtering by unpaid..."

# 3. Convert voice + steps to universal workflow format
cd C:\UFO
.venv\Scripts\python.exe ..\UFO_portable\merge_voice_recording.py ^
    --zip C:\recordings\check_invoices.zip ^
    --audio C:\recordings\check_invoices_audio.wav ^
    --request "Check unpaid invoices in QuickBooks" ^
    --feed-ufo --feed-tars
```

**Outputs:**
- `workflow.json` — universal format, tool-agnostic
- `_enriched.zip` — UFO-ready (feeds into UFO's RAG demonstration system)
- `_tars_replay.bat` — Agent TARS CLI replay commands
- `_transcript.txt` — full voice transcript

The recorder auto-detects browser vs desktop workflows and recommends the right engine.

## VM Requirements

| Requirement | Details |
|---|---|
| OS | Windows 10/11 (x64) |
| RAM | 8 GB minimum |
| Display | 1920x1080 recommended |
| Python | 3.10-3.12 (auto-installed) |
| Node.js | 22+ (auto-installed for TARS) |
| Network | Required for LLM API calls |

For view-only monitoring, the setup auto-installs AnyDesk. Connect with "View Only" to watch the agent work without interfering with mouse/keyboard.

## Architecture

```
Voice Command / Text Request
         |
    Intent Router
    /          \
   v            v
UFO2           Agent TARS
(Desktop)      (Browser)
   |              |
   v              v
Windows UIA    DOM + Visual
pyautogui      Playwright
pywinauto      Chromium
   |              |
   v              v
eval_results/all_results.csv  <-- unified metrics
```

## Credits

- **UFO2** by Microsoft Research — [github.com/microsoft/UFO](https://github.com/microsoft/UFO) ([paper](https://arxiv.org/abs/2504.14603))
- **Agent TARS** by ByteDance — [github.com/bytedance/UI-TARS-desktop](https://github.com/bytedance/UI-TARS-desktop) ([paper](https://arxiv.org/abs/2501.12326))

## License

Scripts in this repo: MIT
UFO2: [MIT](https://github.com/microsoft/UFO/blob/main/LICENSE) | Agent TARS: [Apache 2.0](https://github.com/bytedance/UI-TARS-desktop/blob/main/LICENSE)

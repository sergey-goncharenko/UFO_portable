"""
Workflow Recorder - merge voice narration with Windows Steps Recorder.

Produces a tool-agnostic workflow.json that can be consumed by:
  - UFO (desktop automation via record_processor)
  - Agent TARS (browser automation via CLI)
  - Any future automation tool

Usage:
    python merge_voice_recording.py --zip rec.zip --audio rec_audio.wav -r "Check movie times at AMC"
    python merge_voice_recording.py --zip rec.zip --audio rec_audio.wav -r "Check movie times" --feed-ufo
    python merge_voice_recording.py --zip rec.zip --audio rec_audio.wav -r "Check movie times" --feed-tars
    python merge_voice_recording.py --zip rec.zip --audio rec_audio.wav -r "Check movie times" --feed-ufo --feed-tars
"""

import argparse
import json
import os
import re
import subprocess
import sys
import zipfile
from datetime import datetime


def transcribe_audio(audio_path, api_key=None):
    """Transcribe audio using OpenAI Whisper API. Returns timestamped segments."""
    from openai import OpenAI
    client = OpenAI(api_key=api_key) if api_key else OpenAI()
    with open(audio_path, "rb") as f:
        response = client.audio.transcriptions.create(
            model="whisper-1", file=f,
            response_format="verbose_json",
            timestamp_granularities=["segment"],
        )
    return [{"start": s.start, "end": s.end, "text": s.text.strip()} for s in response.segments]


def parse_psr_zip(zip_path):
    """Parse PSR ZIP. Returns (mhtml_content, list of step dicts)."""
    import xml.etree.ElementTree as ET
    with zipfile.ZipFile(zip_path, "r") as zf:
        mht_files = [n for n in zf.namelist() if n.lower().endswith((".mht", ".mhtml"))]
        if not mht_files:
            raise ValueError("No .mht file found in ZIP")
        mhtml = zf.read(mht_files[0]).decode("utf-8", errors="replace")

    steps = []
    match = re.search(r"<UserActionData>(.*?)</UserActionData>", mhtml, re.DOTALL)
    if not match:
        return mhtml, steps

    root = ET.fromstring(match.group(1))
    for action in root.findall("EachAction"):
        num = int(action.get("ActionNumber", 0))
        ts_str = action.get("TimeStamp", "")
        app = action.get("FileName", "")
        desc_el = action.find("Description")
        desc = desc_el.text if desc_el is not None and desc_el.text else ""
        act_el = action.find("Action")
        act = act_el.text if act_el is not None and act_el.text else ""
        ts = None
        if ts_str:
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", ""))
            except ValueError:
                pass
        steps.append({"step_number": num, "timestamp": ts, "application": app, "description": desc, "action": act})
    return mhtml, steps


def match_voice_to_steps(segments, steps):
    """Match transcript segments to steps. Returns {step_number: narration}."""
    if not steps or not segments:
        return {}
    # Try timestamp matching
    if steps[0]["timestamp"]:
        start = steps[0]["timestamp"]
        comments = {}
        for step in steps:
            if not step["timestamp"]:
                continue
            offset = (step["timestamp"] - start).total_seconds()
            texts = [s["text"] for s in segments if s["start"] - 3 <= offset <= s["end"] + 5]
            if texts:
                comments[step["step_number"]] = " ".join(texts)
        if len(comments) >= len(steps) // 2:
            return comments
    # Fallback: distribute evenly
    comments = {}
    per = max(1, len(segments) // len(steps))
    for i, step in enumerate(steps):
        si = i * per
        ei = min(si + per, len(segments)) if i < len(steps) - 1 else len(segments)
        texts = [s["text"] for s in segments[si:ei]]
        if texts:
            comments[step["step_number"]] = " ".join(texts)
    return comments


def build_workflow_json(request, steps, voice_comments, segments, audio_path, zip_path):
    """Build a tool-agnostic workflow JSON."""
    ws = []
    for step in steps:
        w = {
            "step_number": step["step_number"],
            "description": step["description"],
            "action": step["action"],
            "application": step["application"],
            "voice_narration": voice_comments.get(step["step_number"], ""),
        }
        if step["timestamp"]:
            w["timestamp"] = step["timestamp"].isoformat()
        ws.append(w)

    browser_apps = {"chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe"}
    apps = {s["application"].lower() for s in steps if s["application"]}
    is_browser = bool(apps & browser_apps)
    all_text = " ".join([s["description"] for s in steps] + list(voice_comments.values()))
    urls = sorted(set(re.findall(r'https?://[^\s<>"]+', all_text)))

    return {
        "version": "1.0",
        "request": request,
        "recorded_at": datetime.now().isoformat(),
        "source_files": {"psr_zip": os.path.abspath(zip_path), "audio": os.path.abspath(audio_path)},
        "metadata": {
            "total_steps": len(ws),
            "applications": sorted(apps),
            "is_browser_workflow": is_browser,
            "urls_detected": urls,
            "recommended_engine": "tars" if is_browser else "ufo",
        },
        "full_transcript": [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in segments],
        "steps": ws,
    }


def inject_comments_into_mhtml(mhtml, comments):
    """Inject voice as comments into PSR MHTML for UFO."""
    for num, text in comments.items():
        safe = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        sid = "Step%d" % num
        if ('id="%s"' % sid) in mhtml:
            pattern = '(id="%s".*?)(</div>)' % sid
            replacement = "\\1<br/><b>Comment: </b>%s\\2" % safe
            mhtml = re.sub(pattern, replacement, mhtml, count=1, flags=re.DOTALL)
    return mhtml


def generate_tars_commands(workflow):
    """Generate Agent TARS CLI commands from workflow."""
    cmds = []
    if workflow["metadata"]["is_browser_workflow"]:
        descs = []
        for s in workflow["steps"]:
            t = s.get("voice_narration") or s.get("description", "")
            if t:
                descs.append(t)
        if descs:
            compound = ". Then, ".join(descs[:10])
            cmds.append('agent-tars run --input "%s" --format json' % compound)
    if not cmds:
        cmds.append('agent-tars run --input "%s" --format json' % workflow["request"])
    return cmds


def main():
    p = argparse.ArgumentParser(description="Workflow Recorder: voice + Steps Recorder -> universal format")
    p.add_argument("--zip", "-z", required=True, help="PSR ZIP file")
    p.add_argument("--audio", "-a", required=True, help="Audio WAV file")
    p.add_argument("--request", "-r", required=True, help="Workflow description")
    p.add_argument("--output-dir", "-o", help="Output directory")
    p.add_argument("--api-key", help="OpenAI API key")
    p.add_argument("--feed-ufo", action="store_true", help="Feed to UFO")
    p.add_argument("--feed-tars", action="store_true", help="Run via TARS")
    p.add_argument("--ufo-dir", default="C:\\UFO", help="UFO path")
    args = p.parse_args()

    for f in [args.zip, args.audio]:
        if not os.path.exists(f):
            print("ERROR: Not found: " + f)
            sys.exit(1)

    out_dir = args.output_dir or os.path.dirname(os.path.abspath(args.zip))
    base = os.path.splitext(os.path.basename(args.zip))[0]
    os.makedirs(out_dir, exist_ok=True)

    # 1. Transcribe
    print("\n[1/5] Transcribing audio...")
    segments = transcribe_audio(args.audio, args.api_key)
    print("      %d segments" % len(segments))

    # 2. Parse PSR
    print("\n[2/5] Parsing Steps Recorder...")
    mhtml, psr_steps = parse_psr_zip(args.zip)
    print("      %d steps" % len(psr_steps))

    # 3. Match
    print("\n[3/5] Matching voice to steps...")
    comments = match_voice_to_steps(segments, psr_steps)
    print("      %d/%d matched" % (len(comments), len(psr_steps)))

    # 4. Workflow JSON (universal)
    print("\n[4/5] Building workflow.json...")
    workflow = build_workflow_json(args.request, psr_steps, comments, segments, args.audio, args.zip)
    wf_path = os.path.join(out_dir, base + "_workflow.json")
    with open(wf_path, "w", encoding="utf-8") as f:
        json.dump(workflow, f, indent=2, ensure_ascii=False)
    engine = workflow["metadata"]["recommended_engine"]
    print("      Saved: " + wf_path)
    print("      Recommended engine: " + engine.upper())

    # 5. Engine-specific outputs
    print("\n[5/5] Generating engine outputs...")

    # UFO: enriched PSR ZIP
    enriched = inject_comments_into_mhtml(mhtml, comments)
    ez_path = os.path.join(out_dir, base + "_enriched.zip")
    with zipfile.ZipFile(args.zip, "r") as orig:
        with zipfile.ZipFile(ez_path, "w", zipfile.ZIP_DEFLATED) as nz:
            for item in orig.namelist():
                if item.lower().endswith((".mht", ".mhtml")):
                    nz.writestr(item, enriched)
                else:
                    nz.writestr(item, orig.read(item))
    print("      UFO:  " + ez_path)

    # TARS: replay script
    tars_cmds = generate_tars_commands(workflow)
    tars_path = os.path.join(out_dir, base + "_tars_replay.bat")
    with open(tars_path, "w") as f:
        f.write("@echo off\nREM Replay: %s\n\n" % args.request)
        for c in tars_cmds:
            f.write(c + "\n")
    print("      TARS: " + tars_path)

    # Transcript
    tx_path = os.path.join(out_dir, base + "_transcript.txt")
    with open(tx_path, "w", encoding="utf-8") as f:
        f.write("Request: %s\n\n" % args.request)
        for s in segments:
            f.write("[%.1fs] %s\n" % (s["start"], s["text"]))
    print("      Text: " + tx_path)

    # Feed UFO
    if args.feed_ufo:
        print("\n[*] Feeding to UFO...")
        ufo_py = os.path.join(args.ufo_dir, ".venv", "Scripts", "python.exe")
        if not os.path.exists(ufo_py):
            ufo_py = "python"
        subprocess.run([ufo_py, "-m", "record_processor", "-r", args.request, "-p", ez_path], cwd=args.ufo_dir)

    # Feed TARS
    if args.feed_tars:
        print("\n[*] Running via Agent TARS...")
        for c in tars_cmds:
            subprocess.run(c, shell=True)

    # Summary
    print("\n  ============================================")
    print("  Workflow Recording Complete")
    print("  ============================================")
    print("  Request:     " + args.request)
    print("  Steps:       %d" % len(psr_steps))
    print("  Engine:      %s recommended" % engine.upper())
    print("")
    print("  Universal:   " + wf_path)
    print("  UFO format:  " + ez_path)
    print("  TARS format: " + tars_path)
    print("  Transcript:  " + tx_path)
    print("")


if __name__ == "__main__":
    main()

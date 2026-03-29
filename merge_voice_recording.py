"""
Merge voice narration with Windows Steps Recorder output.

Takes a PSR ZIP file + audio WAV file, transcribes the voice with Whisper,
matches transcript segments to PSR steps by timestamp, and injects them
as comments into the MHTML. The enriched ZIP can then be fed to UFO's
record_processor.

Usage:
    python merge_voice_recording.py --zip recording.zip --audio recording_audio.wav --request "Check movies at AMC"
    python merge_voice_recording.py --zip recording.zip --audio recording_audio.wav --request "Check movies" --feed-ufo
"""

import argparse
import io
import os
import re
import sys
import zipfile
import tempfile
import shutil
from datetime import datetime


def transcribe_audio(audio_path: str, api_key: str = None) -> list[dict]:
    """Transcribe audio using OpenAI Whisper API. Returns timestamped segments."""
    from openai import OpenAI

    client = OpenAI(api_key=api_key) if api_key else OpenAI()

    with open(audio_path, "rb") as f:
        response = client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
            response_format="verbose_json",
            timestamp_granularities=["segment"],
        )

    segments = []
    for seg in response.segments:
        segments.append(
            {
                "start": seg.start,
                "end": seg.end,
                "text": seg.text.strip(),
            }
        )

    return segments


def parse_psr_step_times(mhtml_content: str) -> list[dict]:
    """Extract step timestamps from PSR MHTML content."""
    # PSR stores steps in UserActionData XML with TimeStamp attribute
    import xml.etree.ElementTree as ET

    steps = []

    # Find UserActionData
    match = re.search(
        r"<UserActionData>(.*?)</UserActionData>", mhtml_content, re.DOTALL
    )
    if not match:
        print("WARNING: No UserActionData found in PSR file")
        return steps

    root = ET.fromstring(match.group(1))
    for action in root.findall("EachAction"):
        action_num = int(action.get("ActionNumber", 0))
        timestamp_str = action.get("TimeStamp", "")
        description = ""
        desc_elem = action.find("Description")
        if desc_elem is not None and desc_elem.text:
            description = desc_elem.text

        # Parse timestamp (PSR format: "2026-03-29T10:15:30.123")
        step_time = None
        if timestamp_str:
            try:
                step_time = datetime.fromisoformat(timestamp_str.replace("Z", ""))
            except ValueError:
                pass

        steps.append(
            {
                "action_number": action_num,
                "timestamp": step_time,
                "description": description,
            }
        )

    return steps


def match_segments_to_steps(
    segments: list[dict], steps: list[dict], recording_start: datetime
) -> dict[int, str]:
    """Match voice transcript segments to PSR steps by timestamp proximity."""
    step_comments = {}

    if not steps or not segments:
        return step_comments

    for step in steps:
        if step["timestamp"] is None:
            continue

        # Calculate offset of this step from recording start
        step_offset = (step["timestamp"] - recording_start).total_seconds()

        # Find the transcript segment(s) closest to this step's time
        matching_texts = []
        for seg in segments:
            # Match if the segment overlaps with a window around the step
            # (voice usually comes slightly before or during the action)
            if seg["start"] - 3 <= step_offset <= seg["end"] + 5:
                matching_texts.append(seg["text"])

        if matching_texts:
            step_comments[step["action_number"]] = " ".join(matching_texts)

    return step_comments


def fallback_distribute_segments(
    segments: list[dict], step_count: int
) -> dict[int, str]:
    """If timestamps don't work, distribute segments evenly across steps."""
    step_comments = {}
    if not segments or step_count == 0:
        return step_comments

    # Group segments into step_count buckets
    segs_per_step = max(1, len(segments) // step_count)
    for i in range(step_count):
        start_idx = i * segs_per_step
        end_idx = min(start_idx + segs_per_step, len(segments))
        if i == step_count - 1:
            end_idx = len(segments)
        texts = [s["text"] for s in segments[start_idx:end_idx]]
        if texts:
            step_comments[i + 1] = " ".join(texts)

    return step_comments


def inject_comments_into_mhtml(
    mhtml_content: str, step_comments: dict[int, str]
) -> str:
    """Inject voice transcript as comments into the PSR MHTML content."""
    # PSR MHTML has step divs like: <div id="Step1">
    # We inject comment text after the step description

    for step_num, comment_text in step_comments.items():
        # Clean the comment text for HTML
        safe_comment = (
            comment_text.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

        # Pattern: find the step div and add comment after description
        # PSR format: <div id="StepN">...<br/>...<br/>
        step_id = f"Step{step_num}"

        # Check if comment already exists for this step
        if f'id="{step_id}"' in mhtml_content:
            # Find the step div closing </div> and inject before it
            pattern = f'(id="{step_id}".*?)(</div>)'
            replacement = f"\\1<br/><b>Comment: </b>{safe_comment}\\2"
            mhtml_content = re.sub(pattern, replacement, mhtml_content, count=1, flags=re.DOTALL)

    return mhtml_content


def create_enriched_zip(
    original_zip_path: str, modified_mhtml: str, output_zip_path: str
):
    """Create a new ZIP with the modified MHTML content."""
    with zipfile.ZipFile(original_zip_path, "r") as original:
        with zipfile.ZipFile(output_zip_path, "w", zipfile.ZIP_DEFLATED) as new_zip:
            for item in original.namelist():
                if item.lower().endswith(".mht") or item.lower().endswith(".mhtml"):
                    new_zip.writestr(item, modified_mhtml)
                else:
                    new_zip.writestr(item, original.read(item))


def main():
    parser = argparse.ArgumentParser(
        description="Merge voice narration with Windows Steps Recorder output"
    )
    parser.add_argument(
        "--zip", "-z", required=True, help="Path to PSR ZIP file"
    )
    parser.add_argument(
        "--audio", "-a", required=True, help="Path to audio WAV file"
    )
    parser.add_argument(
        "--request", "-r", required=True, help="Description of the workflow"
    )
    parser.add_argument(
        "--output", "-o", help="Output enriched ZIP path (default: adds _enriched)"
    )
    parser.add_argument(
        "--api-key", help="OpenAI API key (or set OPENAI_API_KEY env var)"
    )
    parser.add_argument(
        "--feed-ufo",
        action="store_true",
        help="Automatically feed the enriched recording to UFO record_processor",
    )
    parser.add_argument(
        "--ufo-dir", default="C:\\UFO", help="Path to UFO installation"
    )

    args = parser.parse_args()

    if not os.path.exists(args.zip):
        print(f"ERROR: ZIP file not found: {args.zip}")
        sys.exit(1)
    if not os.path.exists(args.audio):
        print(f"ERROR: Audio file not found: {args.audio}")
        sys.exit(1)

    output_path = args.output
    if not output_path:
        base = os.path.splitext(args.zip)[0]
        output_path = base + "_enriched.zip"

    # Step 1: Transcribe audio
    print(f"\n[1/4] Transcribing audio: {args.audio}")
    segments = transcribe_audio(args.audio, args.api_key)
    print(f"      Found {len(segments)} transcript segments")
    for seg in segments[:5]:
        print(f"      [{seg['start']:.1f}s] {seg['text'][:80]}")
    if len(segments) > 5:
        print(f"      ... and {len(segments) - 5} more")

    # Step 2: Read PSR ZIP
    print(f"\n[2/4] Reading Steps Recorder file: {args.zip}")
    with zipfile.ZipFile(args.zip, "r") as zf:
        mht_files = [n for n in zf.namelist() if n.lower().endswith((".mht", ".mhtml"))]
        if not mht_files:
            print("ERROR: No .mht file found in ZIP")
            sys.exit(1)
        mhtml_content = zf.read(mht_files[0]).decode("utf-8", errors="replace")

    psr_steps = parse_psr_step_times(mhtml_content)
    print(f"      Found {len(psr_steps)} steps in PSR recording")

    # Step 3: Match voice to steps
    print("\n[3/4] Matching voice to steps...")
    step_comments = {}

    if psr_steps and psr_steps[0]["timestamp"]:
        recording_start = psr_steps[0]["timestamp"]
        step_comments = match_segments_to_steps(segments, psr_steps, recording_start)
        print(f"      Matched {len(step_comments)} steps by timestamp")
    
    # Fallback: if timestamp matching got few results, distribute evenly
    if len(step_comments) < len(psr_steps) // 2:
        print("      Timestamp matching insufficient, distributing segments evenly...")
        step_comments = fallback_distribute_segments(segments, len(psr_steps))
        print(f"      Distributed to {len(step_comments)} steps")

    # Show matches
    for step_num, text in sorted(step_comments.items()):
        print(f"      Step {step_num}: {text[:80]}...")

    # Step 4: Inject comments and save
    print(f"\n[4/4] Injecting voice comments into PSR file...")
    modified_mhtml = inject_comments_into_mhtml(mhtml_content, step_comments)
    create_enriched_zip(args.zip, modified_mhtml, output_path)
    print(f"      Saved enriched recording: {output_path}")

    # Full transcript saved separately for reference
    transcript_path = os.path.splitext(output_path)[0] + "_transcript.txt"
    with open(transcript_path, "w", encoding="utf-8") as f:
        f.write(f"Request: {args.request}\n")
        f.write(f"Audio: {args.audio}\n")
        f.write(f"Steps: {args.zip}\n\n")
        f.write("Full Transcript:\n")
        for seg in segments:
            f.write(f"[{seg['start']:.1f}s - {seg['end']:.1f}s] {seg['text']}\n")
        f.write(f"\nStep-Comment Mapping:\n")
        for step_num, text in sorted(step_comments.items()):
            f.write(f"  Step {step_num}: {text}\n")
    print(f"      Transcript saved: {transcript_path}")

    # Optionally feed to UFO
    if args.feed_ufo:
        print(f"\n[*] Feeding to UFO record_processor...")
        ufo_python = os.path.join(args.ufo_dir, ".venv", "Scripts", "python.exe")
        if not os.path.exists(ufo_python):
            ufo_python = "python"
        
        import subprocess
        cmd = [
            ufo_python, "-m", "record_processor",
            "-r", args.request,
            "-p", output_path,
        ]
        print(f"    Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, cwd=args.ufo_dir)
        if result.returncode != 0:
            print(f"    WARNING: record_processor exited with code {result.returncode}")

    print("\n  Done!")
    print(f"  Enriched ZIP: {output_path}")
    print(f"  Transcript:   {transcript_path}")
    if not args.feed_ufo:
        print(f"\n  To feed to UFO:")
        print(f"    cd {args.ufo_dir}")
        venv_py = os.path.join(args.ufo_dir, ".venv", "Scripts", "python.exe")
        print(f"    {venv_py} -m record_processor -r \"{args.request}\" -p \"{output_path}\"")
    print()


if __name__ == "__main__":
    main()

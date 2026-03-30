"""
UFO Result Extractor — wraps UFO execution and outputs a clean result.

Runs UFO in one-shot mode, captures the output, extracts the task result,
and prints a clean [RESULT] line. Also saves result to a text file.

Usage:
    python ufo_run_clean.py -r "Open Notepad and type Hello" --task demo1
    python ufo_run_clean.py -r "What is the weather?" --task weather --result-file result.txt
"""

import argparse
import os
import re
import subprocess
import sys


def extract_result(output_lines):
    """Extract the task result from UFO's output."""
    result_text = ""

    # Look for "Current Task Results" block
    in_results = False
    for line in output_lines:
        stripped = line.strip()

        # UFO prints results in a box after the task
        if "Current Task Results" in stripped or "Task Results" in stripped:
            in_results = True
            continue
        if in_results:
            # Skip box drawing characters and empty lines
            clean = re.sub(r'[│╭╰╮╯─┌┐└┘\s]*', '', stripped)
            if clean and not stripped.startswith(('╭', '╰', '─', '│')):
                # Remove ANSI escape codes
                clean_text = re.sub(r'\x1b\[[0-9;]*m', '', stripped).strip()
                clean_text = re.sub(r'^[│\s]+', '', clean_text).strip()
                clean_text = re.sub(r'[│\s]+$', '', clean_text).strip()
                if clean_text:
                    result_text = clean_text
            if stripped.startswith('╰') or stripped.startswith('└'):
                in_results = False

    # Fallback: look for Agent Comment
    if not result_text:
        in_comment = False
        for line in output_lines:
            if "Agent Comment" in line:
                in_comment = True
                continue
            if in_comment:
                clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
                clean = re.sub(r'^[│\s]+', '', clean).strip()
                clean = re.sub(r'[│\s]+$', '', clean).strip()
                if clean and not clean.startswith(('╭', '╰', '─')):
                    result_text = clean
                    break
                if line.strip().startswith('╰') or line.strip().startswith('└'):
                    in_comment = False

    # Fallback: look for FINISH status context
    if not result_text:
        for line in output_lines:
            if "FINISH" in line:
                clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
                if clean:
                    result_text = clean
                    break

    return result_text or "Task completed (no summary available)"


def main():
    parser = argparse.ArgumentParser(description="Run UFO with clean result output")
    parser.add_argument("--request", "-r", required=True, help="Task request")
    parser.add_argument("--task", "-t", default="task", help="Task name")
    parser.add_argument("--ufo-dir", default="C:\\UFO", help="UFO install path")
    parser.add_argument("--result-file", help="Save result to this file")
    parser.add_argument("--show-full", action="store_true", help="Also print full UFO output")
    args = parser.parse_args()

    ufo_python = os.path.join(args.ufo_dir, ".venv", "Scripts", "python.exe")
    if not os.path.exists(ufo_python):
        ufo_python = "python"

    cmd = [ufo_python, "-m", "ufo", "--task", args.task, "-r", args.request]

    # Run UFO
    proc = subprocess.run(
        cmd,
        cwd=args.ufo_dir,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    output_lines = (proc.stdout + proc.stderr).splitlines()

    if args.show_full:
        for line in output_lines:
            print(line)
        print()

    # Extract clean result
    result = extract_result(output_lines)

    # Print clean result line
    print("[RESULT] " + result)

    # Save to file if requested
    if args.result_file:
        with open(args.result_file, "w", encoding="utf-8") as f:
            f.write(result + "\n")
        print("[SAVED] " + args.result_file)

    # Also save to log dir
    log_dir = os.path.join(args.ufo_dir, "logs", args.task)
    if os.path.isdir(log_dir):
        result_path = os.path.join(log_dir, "result.txt")
        with open(result_path, "w", encoding="utf-8") as f:
            f.write(result + "\n")

    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()

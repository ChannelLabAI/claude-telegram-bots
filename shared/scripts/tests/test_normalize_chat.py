#!/usr/bin/env python3
"""Test normalize_chat.py against 5 sample fixtures + one real Claude Code transcript."""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "normalize_chat.py"
FIX = HERE / "fixtures"

CASES = [
    ("claude_code.jsonl", "claude-code-jsonl", ["hello claude code", "hi there"]),
    ("claude_ai.json", "claude-ai-json", ["what is 2+2", "equals 4"]),
    ("chatgpt.json", "chatgpt-json", ["hi gpt", "hello human"]),
    ("codex.jsonl", "codex-cli-jsonl", ["refactor this function", "refactored version"]),
    ("slack.json", "slack-json", ["deploy status", "green across"]),
]


def run(path):
    r = subprocess.run(
        [sys.executable, str(SCRIPT), str(path)],
        capture_output=True, text=True, check=True,
    )
    return r.stdout


def main():
    failures = 0
    for fname, expected_tag, must_contain in CASES:
        path = FIX / fname
        out = run(path)
        ok = True
        reasons = []
        if f"source: {expected_tag}" not in out:
            ok = False
            reasons.append(f"missing source tag {expected_tag}")
        for needle in must_contain:
            if needle not in out:
                ok = False
                reasons.append(f"missing content '{needle}'")
        if "> " not in out:
            ok = False
            reasons.append("no '>' user markers")
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {fname} ({expected_tag})")
        if not ok:
            failures += 1
            for r in reasons:
                print(f"       - {r}")

    # Real Claude Code transcript smoke test
    proj = Path.home() / ".claude/projects/-home-oldrabbit--claude-bots-bots-ron-builder"
    real = None
    if proj.exists():
        jsonls = sorted(proj.glob("*.jsonl"), key=lambda p: p.stat().st_size, reverse=True)
        if jsonls:
            real = jsonls[0]
    if real:
        out = run(real)
        lines = out.split("\n")
        user_markers = sum(1 for ln in lines if ln.startswith("> "))
        has_tag = "source: claude-code-jsonl" in out
        ok = has_tag and user_markers >= 1
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] real-transcript {real.name}: tag={has_tag} user_turns={user_markers} chars={len(out)}")
        if not ok:
            failures += 1
    else:
        print("[SKIP] no real Claude Code transcript found")

    print()
    if failures:
        print(f"FAILED: {failures}")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()

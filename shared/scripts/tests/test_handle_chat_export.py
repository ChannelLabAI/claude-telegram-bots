#!/usr/bin/env python3
"""
test_handle_chat_export.py — E2E tests for inbox_sorter.handle_chat_export()

Covers all 5 supported chat export formats + fallback unknown case.

For each valid format:
  - Creates a minimal valid sample in a temp dir
  - Monkeypatches inbox_sorter.NORMALIZED_DIR to temp dir
  - Calls handle_chat_export(src, archived_name)
  - Asserts result["type"] == "chat_export"
  - Asserts normalized .md file exists at result["normalized_to"]
  - Asserts normalized file contains frontmatter with 'source:'

Fallback case:
  - Feeds {"foo":"bar"} plain JSON
  - Asserts result["type"] == "unknown"
  - Asserts no normalized .md was written
"""
from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

# Reach inbox_sorter.py — lives at ~/.claude-bots/scripts/
_HERE = Path(__file__).resolve().parent
_SCRIPTS_DIR = Path.home() / ".claude-bots" / "scripts"
sys.path.insert(0, str(_SCRIPTS_DIR))

import inbox_sorter  # noqa: E402
from inbox_sorter import handle_chat_export  # noqa: E402


def _ts() -> str:
    return f"test-{int(time.time() * 1000)}"


# ---------- format samples ----------

def _write_claude_code_jsonl(path: Path):
    """Format 1: Claude Code JSONL (session file)."""
    lines = [
        json.dumps({"uuid": "a1", "type": "human", "message": {"role": "user", "content": "hello claude code"}}),
        json.dumps({"uuid": "a2", "type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "hi from claude code"}]}}),
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def _write_claude_ai_json(path: Path):
    """Format 2: Claude.ai JSON export (flat messages list)."""
    data = {
        "messages": [
            {"sender": "human", "role": "user", "content": [{"type": "text", "text": "what is 2+2"}]},
            {"sender": "assistant", "role": "assistant", "content": [{"type": "text", "text": "it equals 4"}]},
        ]
    }
    path.write_text(json.dumps(data), encoding="utf-8")


def _write_chatgpt_json(path: Path):
    """Format 3: ChatGPT conversations.json (mapping tree with root node)."""
    data = {
        "title": "test chat",
        "mapping": {
            "root": {
                "id": "root",
                "parent": None,
                "children": ["n1"],
                "message": None,
            },
            "n1": {
                "id": "n1",
                "parent": "root",
                "children": ["n2"],
                "message": {
                    "author": {"role": "user"},
                    "content": {"parts": ["hi gpt"]},
                },
            },
            "n2": {
                "id": "n2",
                "parent": "n1",
                "children": [],
                "message": {
                    "author": {"role": "assistant"},
                    "content": {"parts": ["hello human"]},
                },
            },
        },
    }
    path.write_text(json.dumps(data), encoding="utf-8")


def _write_codex_cli_jsonl(path: Path):
    """Format 4: OpenAI Codex CLI JSONL (session_meta + event_msg format)."""
    lines = [
        json.dumps({"type": "session_meta", "payload": {"id": "sess-1", "timestamp": "2026-04-09T00:00:00Z"}}),
        json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": "refactor this function"}}),
        json.dumps({"type": "event_msg", "payload": {"type": "agent_message", "message": "sure, here is the refactored version"}}),
        json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": "add tests please"}}),
        json.dumps({"type": "event_msg", "payload": {"type": "agent_message", "message": "added three unit tests"}}),
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def _write_slack_json(path: Path):
    """Format 5: Slack channel JSON export."""
    data = [
        {"type": "message", "user": "U001", "text": "deploy status?", "ts": "1234567890.000001"},
        {"type": "message", "user": "U002", "text": "green across the board", "ts": "1234567890.000002"},
    ]
    path.write_text(json.dumps(data), encoding="utf-8")


FORMATS = [
    ("claude_code.jsonl", _write_claude_code_jsonl, "Format 1: Claude Code JSONL"),
    ("claude_ai.json",    _write_claude_ai_json,    "Format 2: Claude.ai JSON"),
    ("chatgpt.json",      _write_chatgpt_json,      "Format 3: ChatGPT JSON"),
    ("codex_cli.jsonl",   _write_codex_cli_jsonl,   "Format 4: Codex CLI JSONL"),
    ("slack.json",        _write_slack_json,         "Format 5: Slack JSON"),
]


# ---------- test helpers ----------

def _run_format_test(fname: str, writer_fn, label: str, inbox_dir: Path, norm_dir: Path) -> None:
    """Create sample, call handle_chat_export, assert expectations."""
    # Patch NORMALIZED_DIR
    inbox_sorter.NORMALIZED_DIR = norm_dir

    src = inbox_dir / fname
    writer_fn(src)
    archived_name = f"2026-04-09-0000-{fname}"

    result = handle_chat_export(src, archived_name)

    assert result.get("type") == "chat_export", \
        f"{label}: expected type='chat_export', got {result.get('type')!r}. Full result: {result}"

    norm_path = Path(result["normalized_to"])
    assert norm_path.exists(), \
        f"{label}: normalized file not found at {norm_path}"

    norm_text = norm_path.read_text(encoding="utf-8")
    assert "---\nsource:" in norm_text, \
        f"{label}: normalized file missing frontmatter '---\\nsource:'. First 300 chars:\n{norm_text[:300]}"

    print(f"[PASS] {label}")


def test_all_formats():
    with tempfile.TemporaryDirectory() as tmpdir:
        inbox_dir = Path(tmpdir) / "inbox"
        norm_dir = Path(tmpdir) / "normalized"
        inbox_dir.mkdir()
        norm_dir.mkdir()

        for fname, writer_fn, label in FORMATS:
            _run_format_test(fname, writer_fn, label, inbox_dir, norm_dir)


def test_fallback_unknown():
    """Feed plain {"foo":"bar"} JSON → assert type='unknown', no normalized file."""
    with tempfile.TemporaryDirectory() as tmpdir:
        inbox_dir = Path(tmpdir) / "inbox"
        norm_dir = Path(tmpdir) / "normalized"
        inbox_dir.mkdir()
        norm_dir.mkdir()

        inbox_sorter.NORMALIZED_DIR = norm_dir

        src = inbox_dir / "unknown.json"
        src.write_text(json.dumps({"foo": "bar"}), encoding="utf-8")
        archived_name = "2026-04-09-0000-unknown.json"

        result = handle_chat_export(src, archived_name)

        assert result.get("type") == "unknown", \
            f"Expected type='unknown' for unrecognized JSON, got {result.get('type')!r}"

        # No normalized file should have been written for unknown type
        norm_files = list(norm_dir.iterdir())
        assert len(norm_files) == 0, \
            f"Expected no normalized files for unknown type, found: {[f.name for f in norm_files]}"

    print("[PASS] Fallback: plain JSON → unknown (no normalized file)")


# ---------- main ----------

def main():
    failures = 0
    all_tests = [test_all_formats, test_fallback_unknown]
    for test_fn in all_tests:
        try:
            test_fn()
        except AssertionError as e:
            print(f"[FAIL] {test_fn.__name__}: {e}")
            failures += 1
        except Exception as e:
            print(f"[ERROR] {test_fn.__name__}: {type(e).__name__}: {e}")
            failures += 1

    total_tests = len(FORMATS) + 1  # 5 formats + 1 fallback
    print()
    if failures:
        print(f"FAILED: {failures}/{total_tests}")
        sys.exit(1)
    print(f"ALL PASS ({total_tests}/{total_tests})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
test_ingest.py — Unit tests for clsc/ingest.py

Covers:
  1. Frontmatter round-trip: parse a known frontmatter string, verify fields
  2. FTS5 ingest dedup: first call returns fts5_inserted=True, second returns False
  3. Radar read-back: after ingest, slug appears in wiki-chats.clsc
"""
from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

# Resolve paths relative to this file
_HERE = Path(__file__).resolve().parent
_SCRIPTS_DIR = _HERE.parent
_CLSC_DIR = _HERE.parent.parent / "clsc"
_FTS5_DIR = _HERE.parent.parent / "fts5"
_CLSC_V07_DIR = _CLSC_DIR / "v0.7"

sys.path.insert(0, str(_CLSC_DIR))
sys.path.insert(0, str(_FTS5_DIR))
sys.path.insert(0, str(_CLSC_V07_DIR))

from ingest import _parse_frontmatter, ingest  # noqa: E402
from radar import RADAR_DIR  # noqa: E402

# ---------- helpers ----------

SAMPLE_MD = """\
---
source: claude-code-jsonl
normalized_at: 2026-04-09T00:00:00Z
origin: test_session.jsonl
---

> hello world

hi there
"""


def _unique_stem() -> str:
    """Generate a unique stem so parallel test runs don't collide in FTS5."""
    return f"test-ingest-{int(time.time() * 1000)}"


# ---------- test 1: frontmatter round-trip ----------

def test_frontmatter_roundtrip():
    fm, body = _parse_frontmatter(SAMPLE_MD)
    assert fm.get("source") == "claude-code-jsonl", f"source wrong: {fm}"
    assert fm.get("normalized_at") == "2026-04-09T00:00:00Z", f"normalized_at wrong: {fm}"
    assert fm.get("origin") == "test_session.jsonl", f"origin wrong: {fm}"
    assert "> hello world" in body, f"body missing expected content: {body!r}"
    print("[PASS] test_frontmatter_roundtrip")


# ---------- test 2: FTS5 ingest dedup ----------

def test_fts5_dedup():
    stem = _unique_stem()
    content = f"""\
---
source: claude-code-jsonl
normalized_at: 2026-04-09T00:00:00Z
origin: {stem}.jsonl
---

> dedup test message

assistant reply
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        md_path = Path(tmpdir) / f"{stem}.md"
        md_path.write_text(content, encoding="utf-8")

        result1 = ingest(md_path)
        assert result1["fts5_inserted"] is True, \
            f"Expected fts5_inserted=True on first call, got: {result1}"

        result2 = ingest(md_path)
        assert result2["fts5_inserted"] is False, \
            f"Expected fts5_inserted=False on second call (dedup), got: {result2}"

    print("[PASS] test_fts5_dedup")


# ---------- test 3: radar read-back ----------

def test_radar_readback():
    stem = _unique_stem() + "-radar"
    content = f"""\
---
source: slack-json
normalized_at: 2026-04-09T00:00:00Z
origin: {stem}.json
---

> radar test message

radar assistant reply
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        md_path = Path(tmpdir) / f"{stem}.md"
        md_path.write_text(content, encoding="utf-8")

        result = ingest(md_path)
        assert result["radar_group"] == "chats", \
            f"Expected radar_group='chats', got: {result}"
        assert result["slug"] == stem, \
            f"Expected slug='{stem}', got: {result['slug']}"

        radar_file = RADAR_DIR / "wiki-chats.clsc.md"
        assert radar_file.exists(), \
            f"Radar file not found: {radar_file}"

        radar_text = radar_file.read_text(encoding="utf-8")
        assert stem in radar_text, \
            f"Slug '{stem}' not found in radar file. Content:\n{radar_text[:500]}"

    print("[PASS] test_radar_readback")


# ---------- main ----------

def main():
    failures = 0
    tests = [test_frontmatter_roundtrip, test_fts5_dedup, test_radar_readback]
    for test_fn in tests:
        try:
            test_fn()
        except Exception as e:
            print(f"[FAIL] {test_fn.__name__}: {e}")
            failures += 1
    print()
    if failures:
        print(f"FAILED: {failures}/{len(tests)}")
        sys.exit(1)
    print(f"ALL PASS ({len(tests)}/{len(tests)})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Tests for l2_loader.py — L2 On-Demand Block Trigger Matcher
"""

import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add parent dir to path so we can import l2_loader
sys.path.insert(0, str(Path(__file__).parent.parent))
from l2_loader import L2Loader, _parse_frontmatter


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_block(tmp_dir: Path, name: str, content: str) -> Path:
    """Write a block file to tmp_dir and return its path."""
    p = tmp_dir / f"block-{name}.md"
    p.write_text(content, encoding="utf-8")
    return p


# ---------------------------------------------------------------------------
# _parse_frontmatter unit tests
# ---------------------------------------------------------------------------

class TestParseFrontmatter:
    def test_inline_triggers(self):
        content = '---\ntriggers: ["VPS", "GCP", "ssh"]\ndescription: "test"\n---\n# Body'
        result = _parse_frontmatter(content)
        assert result["triggers"] == ["VPS", "GCP", "ssh"]
        assert result["description"] == "test"

    def test_multiline_triggers(self):
        content = "---\ntriggers:\n  - VPS\n  - GCP\ndescription: infra\n---\n# Body"
        result = _parse_frontmatter(content)
        assert "VPS" in result["triggers"]
        assert "GCP" in result["triggers"]

    def test_no_frontmatter(self):
        content = "# Just a markdown file\nNo frontmatter here."
        result = _parse_frontmatter(content)
        assert result == {}

    def test_empty_triggers(self):
        content = "---\ntriggers: []\ndescription: empty\n---\n# Body"
        result = _parse_frontmatter(content)
        assert result["triggers"] == []


# ---------------------------------------------------------------------------
# L2Loader.match() tests
# ---------------------------------------------------------------------------

class TestL2LoaderMatch:
    def test_parse_error_block_always_included(self, tmp_path):
        """A block that can't be read → fail-safe include."""
        # Create a block file that has unreadable frontmatter (binary content)
        bad_block = tmp_path / "block-bad.md"
        bad_block.write_bytes(b"\xff\xfe bad binary content")

        loader = L2Loader(str(tmp_path))
        # Even though block can't be parsed, it should be included (fail-safe)
        matched = loader.match("hello world")
        assert str(bad_block) in matched

    def test_empty_triggers_always_included(self, tmp_path):
        """Block with empty triggers list → always included (fail-safe)."""
        make_block(tmp_path, "always", '---\ntriggers: []\ndescription: "always on"\n---\n# Always')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("completely unrelated text about cats")
        assert len(matched) == 1
        assert "block-always.md" in matched[0]

    def test_no_triggers_key_always_included(self, tmp_path):
        """Block with no triggers key at all → always included (fail-safe)."""
        make_block(tmp_path, "notriggers", '---\ndescription: "no triggers key"\n---\n# Content')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("something completely unrelated")
        assert len(matched) == 1

    def test_case_insensitive_matching_vps(self, tmp_path):
        """'vps' in query matches 'VPS' trigger (case-insensitive)."""
        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS", "GCP"]\ndescription: "VPS ops"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        # lowercase query should match uppercase trigger
        matched = loader.match("I need to restart the vps server")
        assert len(matched) == 1
        assert "block-vps-ops.md" in matched[0]

    def test_case_insensitive_matching_uppercase_query(self, tmp_path):
        """'VPS' in query matches 'vps' trigger (case-insensitive, other direction)."""
        make_block(tmp_path, "vps2", '---\ntriggers: ["vps"]\ndescription: "lowercase trigger"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("VPS is having issues")
        assert len(matched) == 1

    def test_multi_block_multiple_matches(self, tmp_path):
        """Query matching 2+ different triggers returns 2+ blocks."""
        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS", "GCP"]\ndescription: "VPS ops"\n---\n# VPS')
        make_block(tmp_path, "task-queue", '---\ntriggers: ["task queue", "pending task"]\ndescription: "task queue"\n---\n# Tasks')
        make_block(tmp_path, "sub-agent", '---\ntriggers: ["sub-agent", "background agent"]\ndescription: "sub-agent routing"\n---\n# Sub')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("restart the VPS and check the task queue")
        assert len(matched) == 2
        names = [Path(p).name for p in matched]
        assert "block-vps-ops.md" in names
        assert "block-task-queue.md" in names
        assert "block-sub-agent.md" not in names

    def test_no_match_returns_empty(self, tmp_path):
        """'hello world' against specific triggers returns empty list."""
        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS", "GCP", "ssh"]\ndescription: "VPS ops"\n---\n# VPS')
        make_block(tmp_path, "cron", '---\ntriggers: ["cron", "09:00", "daily briefing"]\ndescription: "daily cron"\n---\n# Cron')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("hello world, how are you today")
        assert matched == []

    def test_or_matching_any_trigger_loads_block(self, tmp_path):
        """OR logic: any single trigger match is enough to load the block."""
        make_block(tmp_path, "multi-trigger", '---\ntriggers: ["alpha", "beta", "gamma"]\ndescription: "multi"\n---\n# Multi')

        loader = L2Loader(str(tmp_path))
        # Only "beta" appears in query, but that's enough
        matched = loader.match("I need beta testing")
        assert len(matched) == 1

    def test_empty_blocks_dir(self, tmp_path):
        """Empty blocks dir → empty match list."""
        loader = L2Loader(str(tmp_path))
        matched = loader.match("VPS restart GCP ssh")
        assert matched == []

    def test_nonexistent_blocks_dir(self, tmp_path):
        """Non-existent dir → empty match list (no crash)."""
        loader = L2Loader(str(tmp_path / "does_not_exist"))
        matched = loader.match("VPS")
        assert matched == []

    def test_only_block_prefix_files_scanned(self, tmp_path):
        """Files not starting with 'block-' are ignored."""
        # This should be ignored
        other = tmp_path / "README.md"
        other.write_text("# Readme\nsome content")

        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS"]\ndescription: "VPS ops"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        matched = loader.match("VPS restart")
        assert len(matched) == 1
        assert "block-vps-ops.md" in matched[0]


# ---------------------------------------------------------------------------
# L2Loader.match_with_reasons() tests
# ---------------------------------------------------------------------------

class TestMatchWithReasons:
    def test_returns_dict_with_trigger_info(self, tmp_path):
        """match_with_reasons returns list of dicts with path, trigger_matched, description."""
        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS", "GCP"]\ndescription: "VPS infrastructure"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        results = loader.match_with_reasons("restart the VPS now")

        assert len(results) == 1
        r = results[0]
        assert "path" in r
        assert "trigger_matched" in r
        assert "description" in r
        assert "block-vps-ops.md" in r["path"]
        assert r["trigger_matched"] == "VPS"
        assert r["description"] == "VPS infrastructure"

    def test_parse_error_trigger_label(self, tmp_path):
        """Parse error blocks show '(parse_error — fail-safe include)' as trigger."""
        bad_block = tmp_path / "block-bad.md"
        bad_block.write_bytes(b"\xff\xfe binary garbage")

        loader = L2Loader(str(tmp_path))
        results = loader.match_with_reasons("hello")

        assert len(results) == 1
        assert "parse_error" in results[0]["trigger_matched"]

    def test_no_triggers_label(self, tmp_path):
        """Empty triggers → trigger_matched shows '(no triggers — fail-safe include)'."""
        make_block(tmp_path, "empty-triggers", '---\ntriggers: []\ndescription: "always on"\n---\n# Always')

        loader = L2Loader(str(tmp_path))
        results = loader.match_with_reasons("unrelated text")

        assert len(results) == 1
        assert "no triggers" in results[0]["trigger_matched"]

    def test_no_match_returns_empty_list(self, tmp_path):
        """No match → empty list (not None, not error)."""
        make_block(tmp_path, "vps-ops", '---\ntriggers: ["VPS"]\ndescription: "VPS"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        results = loader.match_with_reasons("hello world")
        assert results == []

    def test_multiple_blocks_matched_returns_all(self, tmp_path):
        """Multiple blocks matching → all returned in results."""
        make_block(tmp_path, "vps", '---\ntriggers: ["VPS"]\ndescription: "VPS"\n---\n# VPS')
        make_block(tmp_path, "cron", '---\ntriggers: ["cron", "briefing"]\ndescription: "Daily cron"\n---\n# Cron')

        loader = L2Loader(str(tmp_path))
        results = loader.match_with_reasons("check VPS and run briefing")
        assert len(results) == 2
        paths = [r["path"] for r in results]
        assert any("block-vps.md" in p for p in paths)
        assert any("block-cron.md" in p for p in paths)


# ---------------------------------------------------------------------------
# L2Loader.list_all() tests
# ---------------------------------------------------------------------------

class TestListAll:
    def test_lists_all_blocks(self, tmp_path):
        """list_all() returns all blocks regardless of query."""
        make_block(tmp_path, "a", '---\ntriggers: ["alpha"]\ndescription: "A"\n---\n# A')
        make_block(tmp_path, "b", '---\ntriggers: ["beta"]\ndescription: "B"\n---\n# B')

        loader = L2Loader(str(tmp_path))
        all_blocks = loader.list_all()
        assert len(all_blocks) == 2
        names = [Path(b["path"]).name for b in all_blocks]
        assert "block-a.md" in names
        assert "block-b.md" in names

    def test_list_all_returns_triggers_and_description(self, tmp_path):
        """list_all() entries contain triggers and description fields."""
        make_block(tmp_path, "vps", '---\ntriggers: ["VPS", "GCP"]\ndescription: "VPS ops"\n---\n# VPS')

        loader = L2Loader(str(tmp_path))
        all_blocks = loader.list_all()
        assert len(all_blocks) == 1
        b = all_blocks[0]
        assert "triggers" in b
        assert "description" in b
        assert "VPS" in b["triggers"]
        assert b["description"] == "VPS ops"


# ---------------------------------------------------------------------------
# log_session() tests
# ---------------------------------------------------------------------------

class TestLogSession:
    def test_log_session_creates_session_entry(self, tmp_path):
        """log_session() appends a session entry to l2_stats.json."""
        from l2_loader import log_session

        stats_file = tmp_path / "l2_stats.json"
        stats_file.write_text(json.dumps({
            "dogfood_start": "2026-04-08",
            "sessions": [],
            "block_hit_counts": {
                "block-vps-ops": 0,
                "block-task-queue": 0,
            }
        }))

        log_session("restart the VPS", ["block-vps-ops"], stats_path=str(stats_file))

        data = json.loads(stats_file.read_text())
        assert len(data["sessions"]) == 1
        session = data["sessions"][0]
        assert "ts" in session
        assert "vps" in session["query_snippet"].lower()
        assert "block-vps-ops" in session["blocks_loaded"]

    def test_log_session_increments_hit_counts(self, tmp_path):
        """log_session() increments block_hit_counts for matched blocks."""
        from l2_loader import log_session

        stats_file = tmp_path / "l2_stats.json"
        stats_file.write_text(json.dumps({
            "sessions": [],
            "block_hit_counts": {
                "block-vps-ops": 3,
                "block-task-queue": 0,
            }
        }))

        log_session("VPS issue", ["block-vps-ops"], stats_path=str(stats_file))

        data = json.loads(stats_file.read_text())
        assert data["block_hit_counts"]["block-vps-ops"] == 4
        assert data["block_hit_counts"]["block-task-queue"] == 0

    def test_log_session_missing_stats_file_is_graceful(self, tmp_path):
        """log_session() doesn't crash if stats file doesn't exist yet."""
        from l2_loader import log_session

        stats_file = tmp_path / "nonexistent_stats.json"
        # Should not raise
        log_session("hello", ["block-vps-ops"], stats_path=str(stats_file))

    def test_log_session_multiple_blocks(self, tmp_path):
        """log_session() handles multiple matched blocks correctly."""
        from l2_loader import log_session

        stats_file = tmp_path / "l2_stats.json"
        stats_file.write_text(json.dumps({
            "sessions": [],
            "block_hit_counts": {
                "block-vps-ops": 0,
                "block-task-queue": 0,
            }
        }))

        log_session("VPS and task queue", ["block-vps-ops", "block-task-queue"], stats_path=str(stats_file))

        data = json.loads(stats_file.read_text())
        assert data["block_hit_counts"]["block-vps-ops"] == 1
        assert data["block_hit_counts"]["block-task-queue"] == 1
        assert len(data["sessions"][0]["blocks_loaded"]) == 2

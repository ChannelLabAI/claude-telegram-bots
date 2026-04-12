"""
Tests for dream_cycle.py — Dream Cycle Phase 2: Pearl Generation (Step 5.5).
"""
import json
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Ensure dream_cycle module is importable
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
sys.path.insert(0, str(Path(__file__).parent.parent))

import dream_cycle
from dream_cycle import (
    _migrate_phase2_schema,
    call_haiku_extract_insights,
    call_haiku_judge_evolution,
    create_pearl_draft,
    ensure_schema,
    fts5_search_pearl,
    get_processed_block_hashes,
    parse_pearl_sections,
    record_processed_blocks,
    slugify,
    step_5_5_pearl_generation,
    update_existing_pearl,
    update_pearl_fts_index,
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_in_memory_db():
    """Create an in-memory SQLite database with full schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    _migrate_phase2_schema(conn)
    return conn


def make_file_db(tmp_path: Path) -> Path:
    """Create a file-backed SQLite database with full schema; return path."""
    db_path = tmp_path / "memory.db"
    conn = sqlite3.connect(str(db_path))
    ensure_schema(conn)
    _migrate_phase2_schema(conn)
    conn.close()
    return db_path


# ── 1. slugify ────────────────────────────────────────────────────────────────

def test_slugify_basic():
    """Spaces become hyphens; result is lowercase."""
    assert slugify("Hello World") == "hello-world"


def test_slugify_cjk_preserved():
    """CJK characters are preserved in slug."""
    result = slugify("知識管理系統")
    assert "知識管理系統" in result


def test_slugify_special_chars():
    """Special characters are stripped/replaced with hyphens."""
    result = slugify("Hello! @World#2025")
    assert "!" not in result
    assert "@" not in result
    assert "#" not in result
    # Should not start or end with hyphen
    assert not result.startswith("-")
    assert not result.endswith("-")
    assert "hello" in result
    assert "world" in result


# ── 2. parse_pearl_sections ───────────────────────────────────────────────────

NEW_FORMAT_CARD = """\
---
type: card
source_bot: assistant
created: 2026-04-05
updated: 2026-04-11
source: Dream Cycle
status: draft
---

# 卡片標題

核心觀點第一句。核心觀點第二句。

---
連結：
- [[概念A]]
- [[概念B]]

---
演化記錄：
- 2026-04-05：初始建立
"""

OLD_FORMAT_CARD = """\
---
type: card
source_bot: assistant
created: 2026-01-01
source: Dream Cycle
status: draft
---

# 舊格式標題

這是舊格式卡片內容，沒有演化記錄區塊。
"""

NO_FRONTMATTER_CARD = """\
# 沒有 frontmatter 的卡片

直接從標題開始。
"""


def test_parse_pearl_sections_new_format():
    """New format card parses into all four sections."""
    fm, body, links, evo = parse_pearl_sections(NEW_FORMAT_CARD)
    assert "type: card" in fm
    assert "卡片標題" in body
    assert "概念A" in links
    assert "初始建立" in evo


def test_parse_pearl_sections_old_format():
    """Old format (no 演化記錄) returns empty evolution_log."""
    fm, body, links, evo = parse_pearl_sections(OLD_FORMAT_CARD)
    assert "type: card" in fm
    assert "舊格式" in body
    assert evo == ""


def test_parse_pearl_sections_no_frontmatter():
    """Missing frontmatter generates default with required fields."""
    fm, body, links, evo = parse_pearl_sections(NO_FRONTMATTER_CARD)
    assert "type: card" in fm
    assert "status: draft" in fm
    assert "source: Dream Cycle" in fm
    assert "沒有 frontmatter" in body


# ── 3. update_pearl_fts_index ─────────────────────────────────────────────────

def test_update_pearl_fts_index(tmp_path, monkeypatch):
    """Insert, verify presence, then upsert (update) with new content."""
    db_path = make_file_db(tmp_path)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)

    update_pearl_fts_index("test-slug", "Test Title", "Initial content")

    conn = sqlite3.connect(str(db_path))
    row = conn.execute("SELECT slug, title, content FROM pearl_fts WHERE slug='test-slug'").fetchone()
    assert row is not None
    assert row[0] == "test-slug"
    assert row[1] == "Test Title"
    assert "Initial" in row[2]

    # Upsert: update content
    update_pearl_fts_index("test-slug", "Test Title", "Updated content")
    row2 = conn.execute("SELECT content FROM pearl_fts WHERE slug='test-slug'").fetchone()
    assert row2 is not None
    assert "Updated" in row2[0]
    # Only one row for that slug
    count = conn.execute("SELECT COUNT(*) FROM pearl_fts WHERE slug='test-slug'").fetchone()[0]
    assert count == 1
    conn.close()


# ── 4. fts5_search_pearl ──────────────────────────────────────────────────────

def test_fts5_search_pearl_empty(tmp_path, monkeypatch):
    """No match returns empty list."""
    db_path = make_file_db(tmp_path)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)
    # No files on disk, no FTS entries
    result = fts5_search_pearl("nonexistent query xyz", scope="all", limit=3)
    assert result == []


# ── 5. get_processed_block_hashes ────────────────────────────────────────────

def test_get_processed_block_hashes_empty(tmp_path, monkeypatch):
    """Returns empty set when no completed runs exist."""
    db_path = make_file_db(tmp_path)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)
    result = get_processed_block_hashes("2026-04-11")
    assert isinstance(result, set)
    assert len(result) == 0


# ── 6. record_processed_blocks ───────────────────────────────────────────────

def test_record_processed_blocks(tmp_path, monkeypatch):
    """Stores hashes and retrieves them via get_processed_block_hashes."""
    db_path = make_file_db(tmp_path)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)

    conn = sqlite3.connect(str(db_path))
    run_id = "test-run-001"
    started_at = "2026-04-11T00:00:00"
    conn.execute(
        "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status, content_hash) "
        "VALUES (?, ?, ?, ?, ?)",
        (run_id, started_at, "dry-run", "complete", "abc"),
    )
    conn.commit()

    blocks = [
        {"text": "block1", "content_hash": "hash-aaa"},
        {"text": "block2", "content_hash": "hash-bbb"},
    ]
    record_processed_blocks(conn, "2026-04-11", blocks)
    conn.close()

    hashes = get_processed_block_hashes("2026-04-11")
    assert "hash-aaa" in hashes
    assert "hash-bbb" in hashes


# ── 7. call_haiku_extract_insights (no API key) ───────────────────────────────

def test_call_haiku_extract_insights_no_api_key(monkeypatch):
    """Returns [] when ANTHROPIC_API_KEY not set."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    result = call_haiku_extract_insights("Some conversation text")
    assert result == []


# ── 8. call_haiku_judge_evolution (no API key) ────────────────────────────────

def test_call_haiku_judge_evolution_no_api_key(monkeypatch):
    """Returns 'SKIP' (safe default) when no API key."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    result = call_haiku_judge_evolution("existing card content", "new insight text")
    assert result == "SKIP"


# ── 9. create_pearl_draft (dry run with tmp_path) ─────────────────────────────

def test_create_pearl_draft_dry_run(tmp_path, monkeypatch):
    """Creates a pearl draft file with correct frontmatter and body."""
    drafts_dir = tmp_path / "_drafts"
    monkeypatch.setattr(dream_cycle, "DRAFTS_DIR", drafts_dir)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", tmp_path / "memory.db")

    # Patch update_pearl_fts_index to avoid DB dependency
    monkeypatch.setattr(dream_cycle, "update_pearl_fts_index", lambda *a, **kw: None)

    candidate = {
        "title": "測試洞見",
        "insight_text": "這是一個測試洞見的內容，說明某個重要原則。",
        "source_quote": "原文引用",
    }

    path_str = create_pearl_draft(candidate)
    path = Path(path_str)

    assert path.exists()
    content = path.read_text(encoding="utf-8")
    assert "type: card" in content
    assert "status: draft" in content
    assert "測試洞見" in content
    assert "演化記錄：" in content
    assert "初始建立" in content


# ── 10. update_existing_pearl safety check ───────────────────────────────────

def test_update_existing_pearl_safety_check():
    """Raises ValueError for non-_drafts path."""
    with pytest.raises(ValueError):
        update_existing_pearl("/Ocean/Pearl/some-card.md", {"title": "x", "insight_text": "y"})


# ── 11. step_5_5_pearl_generation — empty blocks ─────────────────────────────

def test_step_5_5_empty_blocks(tmp_path, monkeypatch):
    """Empty input returns zeros."""
    db_path = make_file_db(tmp_path)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    _migrate_phase2_schema(conn)

    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)

    result = step_5_5_pearl_generation(
        conversation_blocks=[],
        run_date="2026-04-11",
        conn=conn,
        mode="dry-run",
    )
    conn.close()

    assert result["pearls_created"] == 0
    assert result["pearls_updated"] == 0
    assert result["pearls_skipped"] == 0
    assert result["pearl_details"] == []


# ── 12. step_5_5_pearl_generation — dry-run doesn't write files ──────────────

def test_step_5_5_dry_run_no_files(tmp_path, monkeypatch):
    """Dry-run mode doesn't create files even when Haiku returns candidates."""
    db_path = make_file_db(tmp_path)
    drafts_dir = tmp_path / "_drafts"
    drafts_dir.mkdir(parents=True)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)
    monkeypatch.setattr(dream_cycle, "DRAFTS_DIR", drafts_dir)

    # Mock Haiku to return one candidate
    fake_candidates = [
        {
            "title": "Dry Run Test",
            "insight_text": "Some insight text for testing purposes.",
            "source_quote": "test quote",
        }
    ]
    monkeypatch.setattr(dream_cycle, "call_haiku_extract_insights", lambda *a, **kw: fake_candidates)
    monkeypatch.setattr(dream_cycle, "fts5_search_pearl", lambda *a, **kw: [])

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    _migrate_phase2_schema(conn)

    result = step_5_5_pearl_generation(
        conversation_blocks=[{"text": "some text", "content_hash": "xyz123"}],
        run_date="2026-04-11",
        conn=conn,
        mode="dry-run",
    )
    conn.close()

    # In dry-run, no actual files should be created
    files = list(drafts_dir.glob("*.md"))
    assert len(files) == 0
    # But should report what would happen
    assert result["pearls_created"] == 1
    assert result["pearls_updated"] == 0


# ── 13. step_5_5_pearl_generation — idempotency ──────────────────────────────

def test_step_5_5_idempotent(tmp_path, monkeypatch):
    """Already processed blocks are skipped in a second run."""
    db_path = make_file_db(tmp_path)
    monkeypatch.setattr(dream_cycle, "MEMORY_DB_PATH", db_path)

    # Mock Haiku (should not be called on second run)
    call_count = {"n": 0}
    def fake_extract(blob):
        call_count["n"] += 1
        return []
    monkeypatch.setattr(dream_cycle, "call_haiku_extract_insights", fake_extract)

    block = {"text": "test text", "content_hash": "idempotent-hash-001"}

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    _migrate_phase2_schema(conn)

    # Insert a completed run for today so hashes can be stored
    run_date = "2026-04-11"
    conn.execute(
        "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status, content_hash) "
        "VALUES (?, ?, ?, ?, ?)",
        ("idempotent-run", f"{run_date}T00:00:00", "live", "complete", "content-hash-x"),
    )
    conn.commit()

    # First call in live mode: will process and record
    result1 = step_5_5_pearl_generation(
        conversation_blocks=[block],
        run_date=run_date,
        conn=conn,
        mode="live",
    )

    # Second call: all blocks already processed → should skip immediately
    result2 = step_5_5_pearl_generation(
        conversation_blocks=[block],
        run_date=run_date,
        conn=conn,
        mode="live",
    )
    conn.close()

    # Second run should return zeros without calling Haiku a second time
    assert result2["pearls_created"] == 0
    assert result2["pearls_updated"] == 0
    assert result2["pearls_skipped"] == 0
    # Haiku was called at most once (first run)
    assert call_count["n"] <= 1


# ── 14. _migrate_phase2_schema idempotency ────────────────────────────────────

def test_migrate_phase2_schema_idempotent():
    """Running migration twice raises no error."""
    conn = sqlite3.connect(":memory:")
    ensure_schema(conn)

    # Run twice — should not raise
    _migrate_phase2_schema(conn)
    _migrate_phase2_schema(conn)

    # Verify pearl_fts exists
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE name='pearl_fts'"
    ).fetchone()
    assert row is not None

    # Verify column exists
    cols = {r[1] for r in conn.execute("PRAGMA table_info(dream_cycle_runs)")}
    assert "pearl_blocks_processed" in cols

    conn.close()

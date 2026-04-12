"""
Tests for dream_cycle.py — Dream Cycle Phase 1 pipeline.
"""
import json
import os
import sqlite3
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Ensure dream_cycle module is importable
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
sys.path.insert(0, str(Path(__file__).parent.parent))

from dream_cycle import (
    LockFile,
    check_incomplete_run,
    collect_messages,
    ensure_schema,
    group_into_blocks,
    load_alias_table,
    load_alias_table_full,
    normalize_entities,
    normalize_entity,
    normalize_triples,
    resume_from_step,
    step1_collect_messages,
    update_run_status,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def alias_table_path(tmp_path):
    """Create a temporary alias_table.yaml for testing."""
    content = """# Test alias table
entities:
  - canonical: owner
    aliases: [laotu]
    type: person
  - canonical: ChannelLab
    aliases: [CHL, channellab, Channel Lab]
    type: company
  - canonical: builder
    aliases: [builder-bot, builder-alias]
    type: bot
  - canonical: Dream Cycle
    aliases: [dream cycle, dreamcycle, 夢境週期]
    type: feature
"""
    p = tmp_path / "alias_table.yaml"
    p.write_text(content, encoding="utf-8")
    return p


@pytest.fixture
def in_memory_db():
    """Create an in-memory SQLite database with schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    return conn


@pytest.fixture
def memory_db_with_messages(tmp_path):
    """Create a temp memory.db with messages table and sample data."""
    db_path = tmp_path / "memory.db"
    conn = sqlite3.connect(str(db_path))
    conn.execute("""
        CREATE TABLE messages (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            bot_name TEXT,
            ts TEXT,
            source TEXT,
            chat_id INTEGER,
            user TEXT,
            message_id INTEGER,
            text TEXT
        )
    """)
    # Add some messages within last 24h
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO messages (text, ts, chat_id, user) VALUES (?, ?, ?, ?)",
        ("owner is the CEO of ChannelLab", now, -1001234567, "owner"),
    )
    conn.execute(
        "INSERT INTO messages (text, ts, chat_id, user) VALUES (?, ?, ?, ?)",
        ("builder is working on MemOcean project", now, -1001234567, "builder"),
    )
    conn.commit()
    conn.close()
    return db_path


# ── load_alias_table() ────────────────────────────────────────────────────────

class TestLoadAliasTable:
    def test_returns_dict(self, alias_table_path):
        result = load_alias_table(alias_table_path)
        assert isinstance(result, dict)

    def test_canonical_maps_to_itself(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        assert alias_map.get("owner") == "owner"
        assert alias_map.get("channellab") == "ChannelLab"
        assert alias_map.get("builder") == "builder"

    def test_aliases_map_to_canonical(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        assert alias_map.get("laotu") == "owner"
        assert alias_map.get("chl") == "ChannelLab"
        assert alias_map.get("builder-alias") == "builder"

    def test_case_insensitive_keys(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        # Keys are stored lowercase
        assert "laotu" in alias_map
        assert "chl" in alias_map
        assert "channel lab" in alias_map

    def test_missing_file_returns_empty(self, tmp_path):
        result = load_alias_table(tmp_path / "nonexistent.yaml")
        assert result == {}

    def test_multi_word_alias(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        assert alias_map.get("dream cycle") == "Dream Cycle"
        assert alias_map.get("dreamcycle") == "Dream Cycle"


# ── normalize_entities() ─────────────────────────────────────────────────────

class TestNormalizeEntities:
    def test_merges_aliases_to_canonical(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        result = normalize_entities(["laotu", "owner"], alias_map)
        assert result == ["owner"]

    def test_deduplicates(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        result = normalize_entities(["builder", "builder-alias", "builder-bot"], alias_map)
        assert result == ["builder"]

    def test_preserves_unknown_entities(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        result = normalize_entities(["SomeUnknownPerson"], alias_map)
        assert result == ["SomeUnknownPerson"]

    def test_empty_list(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        assert normalize_entities([], alias_map) == []

    def test_preserves_order_of_first_occurrence(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        result = normalize_entities(["builder", "owner", "ChannelLab"], alias_map)
        assert result == ["builder", "owner", "ChannelLab"]


# ── normalize_triples() ──────────────────────────────────────────────────────

class TestNormalizeTriples:
    def test_normalizes_subject_and_object(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        triples = [("laotu", "is_ceo_of", "CHL", 0.95)]
        result = normalize_triples(triples, alias_map)
        assert result == [("owner", "is_ceo_of", "ChannelLab", 0.95)]

    def test_deduplicates_after_normalization(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        triples = [
            ("laotu", "role", "CEO", 0.9),
            ("owner", "role", "CEO", 0.85),  # duplicate after normalization
        ]
        result = normalize_triples(triples, alias_map)
        assert len(result) == 1
        assert result[0][0] == "owner"

    def test_preserves_unknown_entities(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        triples = [("Mystery Person", "knows", "owner", 0.7)]
        result = normalize_triples(triples, alias_map)
        assert result[0][0] == "Mystery Person"
        assert result[0][2] == "owner"

    def test_default_confidence(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        triples = [("builder", "works_on", "MemOcean")]  # no confidence
        result = normalize_triples(triples, alias_map)
        assert result[0][3] == 0.8  # default

    def test_empty_triples(self, alias_table_path):
        alias_map = load_alias_table(alias_table_path)
        assert normalize_triples([], alias_map) == []


# ── ensure_schema() ───────────────────────────────────────────────────────────

class TestEnsureSchema:
    def test_creates_tables(self, in_memory_db):
        tables = in_memory_db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        table_names = {row[0] for row in tables}
        assert "dream_cycle_runs" in table_names
        assert "dream_cycle_changes" in table_names

    def test_idempotent(self, in_memory_db):
        # Should not raise if called twice
        ensure_schema(in_memory_db)
        ensure_schema(in_memory_db)
        tables = in_memory_db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        assert len([t for t in tables if t[0] in ("dream_cycle_runs", "dream_cycle_changes")]) == 2

    def test_runs_table_columns(self, in_memory_db):
        info = in_memory_db.execute("PRAGMA table_info(dream_cycle_runs)").fetchall()
        col_names = {row[1] for row in info}
        assert "run_id" in col_names
        assert "started_at" in col_names
        assert "finished_at" in col_names
        assert "mode" in col_names
        assert "status" in col_names
        assert "report_json" in col_names

    def test_changes_table_columns(self, in_memory_db):
        info = in_memory_db.execute("PRAGMA table_info(dream_cycle_changes)").fetchall()
        col_names = {row[1] for row in info}
        assert "run_id" in col_names
        assert "change_type" in col_names
        assert "target_id" in col_names
        assert "confidence" in col_names


# ── check_incomplete_run() ────────────────────────────────────────────────────

class TestCheckIncompleteRun:
    def test_returns_none_when_no_runs(self, in_memory_db):
        result = check_incomplete_run(in_memory_db)
        assert result is None

    def test_returns_none_when_all_complete(self, in_memory_db):
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()
        in_memory_db.execute(
            "INSERT INTO dream_cycle_runs (run_id, started_at, finished_at, mode) VALUES (?, ?, ?, ?)",
            ("run-1", now, now, "dry-run"),
        )
        in_memory_db.commit()
        result = check_incomplete_run(in_memory_db)
        assert result is None

    def test_returns_incomplete_run(self, in_memory_db):
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()
        in_memory_db.execute(
            "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status) VALUES (?, ?, ?, ?)",
            ("run-incomplete", now, "live", "running_step3"),
        )
        in_memory_db.commit()
        result = check_incomplete_run(in_memory_db)
        assert result is not None
        assert result["run_id"] == "run-incomplete"
        assert result["status"] == "running_step3"

    def test_handles_missing_table(self):
        conn = sqlite3.connect(":memory:")
        # No schema created — should return None gracefully
        result = check_incomplete_run(conn)
        assert result is None
        conn.close()


# ── LockFile ─────────────────────────────────────────────────────────────────

class TestLockFile:
    def test_creates_lock_file(self, tmp_path):
        lock_path = tmp_path / "test.lock"
        with LockFile(lock_path):
            assert lock_path.exists()

    def test_removes_lock_file_on_exit(self, tmp_path):
        lock_path = tmp_path / "test.lock"
        with LockFile(lock_path):
            pass
        assert not lock_path.exists()

    def test_removes_lock_file_on_exception(self, tmp_path):
        lock_path = tmp_path / "test.lock"
        try:
            with LockFile(lock_path):
                raise ValueError("test error")
        except ValueError:
            pass
        assert not lock_path.exists()

    def test_raises_if_already_locked(self, tmp_path):
        lock_path = tmp_path / "test.lock"
        with LockFile(lock_path):
            with pytest.raises(RuntimeError, match="already running"):
                with LockFile(lock_path):
                    pass


# ── Dry-run mode ──────────────────────────────────────────────────────────────

class TestDryRunMode:
    def test_dry_run_exits_zero(self, tmp_path, monkeypatch):
        """dry-run must exit 0 and create report JSON."""
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE messages (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_name TEXT, ts TEXT, source TEXT,
                chat_id INTEGER, user TEXT, message_id INTEGER, text TEXT
            )
        """)
        conn.commit()
        conn.close()

        log_dir = tmp_path / "logs" / "dream-cycle"

        monkeypatch.setattr("dream_cycle.MEMORY_DB", db_path)
        monkeypatch.setattr("dream_cycle.LOG_DIR", log_dir)
        monkeypatch.setattr("dream_cycle.LOCK_FILE", tmp_path / "dream-cycle.lock")
        # Disable TG send
        monkeypatch.setattr("dream_cycle.step6_send_tg_report", lambda r: None)

        from dream_cycle import run_pipeline
        exit_code = run_pipeline("dry-run")
        assert exit_code == 0

        # Report JSON should exist
        from datetime import datetime, timezone
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        report_file = log_dir / f"{today}.json"
        assert report_file.exists(), f"Report file {report_file} not found"

        report = json.loads(report_file.read_text(encoding="utf-8"))
        assert report["mode"] == "dry-run"
        assert report["status"] == "complete"

    def test_dry_run_does_not_write_kg(self, tmp_path, monkeypatch):
        """dry-run must not call kg_add."""
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE messages (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_name TEXT, ts TEXT, source TEXT,
                chat_id INTEGER, user TEXT, message_id INTEGER, text TEXT
            )
        """)
        conn.commit()
        conn.close()

        log_dir = tmp_path / "logs" / "dream-cycle"
        monkeypatch.setattr("dream_cycle.MEMORY_DB", db_path)
        monkeypatch.setattr("dream_cycle.LOG_DIR", log_dir)
        monkeypatch.setattr("dream_cycle.LOCK_FILE", tmp_path / "dream-cycle.lock")
        monkeypatch.setattr("dream_cycle.step6_send_tg_report", lambda r: None)

        kg_add_calls = []

        # Mock step4_write_kg to track calls
        import dream_cycle
        original = dream_cycle.step4_write_kg

        def mock_write_kg(diff, run_id, conn, mode):
            assert mode == "dry-run", "KG write called in dry-run mode!"
            return original(diff, run_id, conn, mode)

        monkeypatch.setattr("dream_cycle.step4_write_kg", mock_write_kg)

        from dream_cycle import run_pipeline
        exit_code = run_pipeline("dry-run")
        assert exit_code == 0


# ── group_into_blocks() ───────────────────────────────────────────────────────

class TestGroupIntoBlocks:
    def test_groups_by_chat_id(self):
        messages = [
            {"text": "Hello owner", "chat_id": 111, "ts": "2026-01-01T00:00:00", "bot_name": "builder"},
            {"text": "World message", "chat_id": 222, "ts": "2026-01-01T00:01:00", "bot_name": "reviewer"},
            {"text": "Another 111", "chat_id": 111, "ts": "2026-01-01T00:02:00", "bot_name": "builder"},
        ]
        blocks = group_into_blocks(messages)
        assert len(blocks) == 2
        chat_ids = {b["chat_id"] for b in blocks}
        assert 111 in chat_ids
        assert 222 in chat_ids

    def test_filters_bot_commands(self):
        messages = [
            {"text": "/start", "chat_id": 111, "ts": "2026-01-01T00:00:00", "bot_name": "builder"},
            {"text": "/qa", "chat_id": 111, "ts": "2026-01-01T00:01:00", "bot_name": "reviewer"},
            {"text": "Real message", "chat_id": 111, "ts": "2026-01-01T00:02:00", "bot_name": "builder"},
        ]
        blocks = group_into_blocks(messages)
        assert len(blocks) == 1
        assert "/start" not in blocks[0]["text"]
        assert "Real message" in blocks[0]["text"]

    def test_allows_long_slash_messages(self):
        """Messages starting with / but over 50 chars should NOT be filtered."""
        long_cmd = "/plan-eng-review This is a detailed plan review request that is long"
        messages = [
            {"text": long_cmd, "chat_id": 111, "ts": "2026-01-01T00:00:00", "bot_name": "builder"},
        ]
        blocks = group_into_blocks(messages)
        assert len(blocks) == 1

    def test_caps_at_50_blocks(self):
        messages = [
            {"text": f"msg {i}", "chat_id": i, "ts": "2026-01-01T00:00:00", "bot_name": "builder"}
            for i in range(100)
        ]
        blocks = group_into_blocks(messages)
        assert len(blocks) <= 50

    def test_truncates_text_to_3000(self):
        long_text = "x" * 5000
        messages = [
            {"text": long_text, "chat_id": 111, "ts": "2026-01-01T00:00:00", "bot_name": "builder"},
        ]
        blocks = group_into_blocks(messages)
        assert len(blocks[0]["text"]) <= 3100  # allow for prefix


# ── Idempotency (content_hash) ────────────────────────────────────────────────

class TestIdempotency:
    def _make_db(self, tmp_path):
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE messages (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_name TEXT, ts TEXT, source TEXT,
                chat_id INTEGER, user TEXT, message_id INTEGER, text TEXT
            )
        """)
        conn.commit()
        conn.close()
        return db_path

    def test_second_run_same_content_is_skipped(self, tmp_path, monkeypatch):
        """Running with same message content twice should skip second run."""
        db_path = self._make_db(tmp_path)
        log_dir = tmp_path / "logs" / "dream-cycle"

        monkeypatch.setattr("dream_cycle.MEMORY_DB", db_path)
        monkeypatch.setattr("dream_cycle.LOG_DIR", log_dir)
        monkeypatch.setattr("dream_cycle.LOCK_FILE", tmp_path / "dream-cycle.lock")
        monkeypatch.setattr("dream_cycle.step6_send_tg_report", lambda r: None)

        from dream_cycle import run_pipeline
        # First run — should complete
        exit_code = run_pipeline("dry-run")
        assert exit_code == 0

        # Read first report
        from datetime import datetime, timezone
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        report1 = json.loads((log_dir / f"{today}.json").read_text())
        assert report1["status"] == "complete"

        # Second run — same content, should skip
        exit_code2 = run_pipeline("dry-run")
        assert exit_code2 == 0
        report2 = json.loads((log_dir / f"{today}.json").read_text())
        assert report2["status"] == "skipped"
        assert report2["reason"] == "idempotent"


# ── Crash recovery ────────────────────────────────────────────────────────────

class TestCrashRecovery:
    def test_resume_from_step_parses_step_number(self, in_memory_db):
        """resume_from_step should detect step number from status string."""
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()

        # Insert an incomplete run at step 3
        in_memory_db.execute(
            "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status) VALUES (?, ?, ?, ?)",
            ("resume-test", now, "dry-run", "running_step3"),
        )
        in_memory_db.commit()

        # Resume should not raise and should attempt to call step pipeline
        import dream_cycle
        captured = {}

        original_run_steps = dream_cycle._run_steps

        def mock_run_steps(run_id, messages, blocks, conn, mode, start_from_step=1):
            captured["start_from_step"] = start_from_step
            captured["run_id"] = run_id
            return 0

        dream_cycle._run_steps = mock_run_steps
        try:
            original_collect = dream_cycle.collect_messages
            dream_cycle.collect_messages = lambda conn: []
            try:
                result = resume_from_step("resume-test", "running_step3", in_memory_db, "dry-run")
            finally:
                dream_cycle.collect_messages = original_collect
        finally:
            dream_cycle._run_steps = original_run_steps

        assert captured.get("start_from_step") == 3
        assert captured.get("run_id") == "resume-test"

    def test_update_run_status(self, in_memory_db):
        """update_run_status should update the status column."""
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()
        in_memory_db.execute(
            "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status) VALUES (?, ?, ?, ?)",
            ("status-test", now, "dry-run", "running_step1"),
        )
        in_memory_db.commit()
        update_run_status("status-test", "running_step3", in_memory_db)
        row = in_memory_db.execute(
            "SELECT status FROM dream_cycle_runs WHERE run_id=?", ("status-test",)
        ).fetchone()
        assert row[0] == "running_step3"


# ── Dry-run content_hash in report ───────────────────────────────────────────

class TestContentHashInReport:
    def test_report_includes_content_hash(self, tmp_path, monkeypatch):
        """Report JSON should contain content_hash field after a run."""
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE messages (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_name TEXT, ts TEXT, source TEXT,
                chat_id INTEGER, user TEXT, message_id INTEGER, text TEXT
            )
        """)
        conn.commit()
        conn.close()

        log_dir = tmp_path / "logs" / "dream-cycle"
        monkeypatch.setattr("dream_cycle.MEMORY_DB", db_path)
        monkeypatch.setattr("dream_cycle.LOG_DIR", log_dir)
        monkeypatch.setattr("dream_cycle.LOCK_FILE", tmp_path / "dream-cycle.lock")
        monkeypatch.setattr("dream_cycle.step6_send_tg_report", lambda r: None)

        from dream_cycle import run_pipeline
        exit_code = run_pipeline("dry-run")
        assert exit_code == 0

        from datetime import datetime, timezone
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        report = json.loads((log_dir / f"{today}.json").read_text())
        assert "content_hash" in report
        assert report["content_hash"] is not None
        assert len(report["content_hash"]) == 64  # sha256 hex digest

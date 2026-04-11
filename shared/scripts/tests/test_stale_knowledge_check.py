"""
Tests for stale_knowledge_check.py — MemOcean P4: Stale Knowledge Detection.
"""
import datetime
import json
import os
import sqlite3
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Ensure stale_knowledge_check is importable
sys.path.insert(0, str(Path(__file__).parent.parent))

from stale_knowledge_check import (
    detect_cold_entries,
    detect_contradictions,
    generate_report,
    migrate_schema,
    run_health_check,
    write_stale_candidates,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────

def _make_conn(tmp_path, with_radar: bool = True) -> sqlite3.Connection:
    """Create a fresh in-memory-like SQLite connection for tests."""
    db_path = tmp_path / "test_memory.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    if with_radar:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS radar (
                slug TEXT PRIMARY KEY,
                clsc TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                drawer_path TEXT,
                source_hash TEXT NOT NULL,
                encoded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        conn.commit()
    return conn


def _now_minus(days: int) -> str:
    """Return ISO timestamp for `days` ago in UTC."""
    dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    return dt.strftime('%Y-%m-%dT%H:%M:%SZ')


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


# ── migrate_schema ────────────────────────────────────────────────────────────

class TestMigrateSchema:
    def test_migrate_schema_idempotent(self, tmp_path):
        """Running migrate_schema twice should not raise."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)
        migrate_schema(conn)  # second call should be idempotent

        # last_accessed column should exist
        cols = {row[1] for row in conn.execute("PRAGMA table_info(radar)")}
        assert "last_accessed" in cols

        # stale_candidates table should exist
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert "stale_candidates" in tables
        conn.close()

    def test_migrate_schema_creates_stale_candidates(self, tmp_path):
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        cols_info = conn.execute("PRAGMA table_info(stale_candidates)").fetchall()
        col_names = {row[1] for row in cols_info}
        assert "id" in col_names
        assert "slug" in col_names
        assert "reason" in col_names
        assert "detail" in col_names
        assert "detected_at" in col_names
        assert "status" in col_names
        assert "confirmed_by" in col_names
        conn.close()


# ── detect_cold_entries ───────────────────────────────────────────────────────

class TestDetectColdEntries:
    def test_detect_cold_entries_empty_db(self, tmp_path):
        """Empty closet returns []."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)
        result = detect_cold_entries(conn, days=30)
        assert result == []
        conn.close()

    def test_detect_cold_entries_fresh_excluded(self, tmp_path):
        """Entry encoded < 30 days ago should NOT be cold."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)
        # Entry encoded 5 days ago
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at) VALUES (?, ?, ?, ?, ?)",
            ("fresh-entry", "test content", 10, "abc123", _now_minus(5)),
        )
        conn.commit()

        result = detect_cold_entries(conn, days=30)
        assert result == []
        conn.close()

    def test_detect_cold_entries_old_never_accessed(self, tmp_path):
        """Entry encoded > 30 days ago with no last_accessed should be cold."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)
        # Entry encoded 45 days ago, never accessed
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("old-entry", "old content", 20, "def456", _now_minus(45), None),
        )
        conn.commit()

        result = detect_cold_entries(conn, days=30)
        assert len(result) == 1
        assert result[0]["slug"] == "old-entry"
        assert result[0]["last_accessed"] is None
        conn.close()

    def test_detect_cold_entries_recently_accessed(self, tmp_path):
        """Old entry but last_accessed < 30 days should NOT be cold."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)
        # Entry encoded 60 days ago but accessed 5 days ago
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("active-entry", "active content", 15, "ghi789", _now_minus(60), _now_minus(5)),
        )
        conn.commit()

        result = detect_cold_entries(conn, days=30)
        assert result == []
        conn.close()

    def test_detect_cold_entries_multiple(self, tmp_path):
        """Multiple old entries, mix of cold and active."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        # Cold: old encoded, never accessed
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("cold-1", "cold content 1", 10, "h1", _now_minus(50), None),
        )
        # Cold: old encoded, old last_accessed
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("cold-2", "cold content 2", 10, "h2", _now_minus(40), _now_minus(35)),
        )
        # Not cold: recently accessed
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("warm", "warm content", 10, "h3", _now_minus(60), _now_minus(2)),
        )
        # Not cold: fresh entry
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at, last_accessed) VALUES (?, ?, ?, ?, ?, ?)",
            ("fresh", "fresh content", 10, "h4", _now_minus(3), None),
        )
        conn.commit()

        result = detect_cold_entries(conn, days=30)
        slugs = {r["slug"] for r in result}
        assert "cold-1" in slugs
        assert "cold-2" in slugs
        assert "warm" not in slugs
        assert "fresh" not in slugs
        conn.close()


# ── write_stale_candidates ────────────────────────────────────────────────────

class TestWriteStaleCandidates:
    def test_write_stale_candidates_basic(self, tmp_path):
        """Insert candidates and verify count."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        candidates = [
            {"slug": "entry-1", "reason": "cold", "detail": None},
            {"slug": "entry-2", "reason": "cold", "detail": None},
        ]
        count = write_stale_candidates(conn, candidates)
        assert count == 2

        rows = conn.execute("SELECT * FROM stale_candidates").fetchall()
        assert len(rows) == 2
        conn.close()

    def test_write_stale_candidates_dedup(self, tmp_path):
        """Same slug+reason → INSERT OR IGNORE, count stays 1."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        candidates = [{"slug": "dup-entry", "reason": "cold", "detail": None}]

        count1 = write_stale_candidates(conn, candidates)
        assert count1 == 1

        count2 = write_stale_candidates(conn, candidates)
        assert count2 == 0  # already exists, not inserted

        rows = conn.execute("SELECT * FROM stale_candidates WHERE slug='dup-entry'").fetchall()
        assert len(rows) == 1  # still only one row
        conn.close()

    def test_write_stale_candidates_empty(self, tmp_path):
        """Empty candidates list returns 0."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        count = write_stale_candidates(conn, [])
        assert count == 0
        conn.close()

    def test_write_stale_candidates_status_default(self, tmp_path):
        """Default status should be 'pending'."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        write_stale_candidates(conn, [{"slug": "test", "reason": "cold", "detail": None}])
        row = conn.execute("SELECT status FROM stale_candidates WHERE slug='test'").fetchone()
        assert row[0] == "pending"
        conn.close()


# ── generate_report ───────────────────────────────────────────────────────────

class TestGenerateReport:
    def test_generate_report_empty(self, tmp_path):
        """Empty stale_candidates → all zeros."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        report = generate_report(conn)
        assert report["cold_count"] == 0
        assert report["contradiction_count"] == 0
        assert report["pending_total"] == 0
        assert report["sample_cold"] == []
        conn.close()

    def test_generate_report_with_data(self, tmp_path):
        """Insert some rows, verify report counts."""
        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        now = _now()
        # Insert 3 cold candidates
        for i in range(3):
            conn.execute(
                "INSERT INTO stale_candidates (slug, reason, detail, detected_at, status) VALUES (?, ?, ?, ?, ?)",
                (f"cold-{i}", "cold", None, now, "pending"),
            )
        # Insert 2 contradiction candidates
        for i in range(2):
            conn.execute(
                "INSERT INTO stale_candidates (slug, reason, detail, detected_at, status) VALUES (?, ?, ?, ?, ?)",
                (f"contra-{i}", "contradiction", "some conflict", now, "pending"),
            )
        # Insert 1 confirmed (should NOT count toward pending_total)
        conn.execute(
            "INSERT INTO stale_candidates (slug, reason, detail, detected_at, status) VALUES (?, ?, ?, ?, ?)",
            ("confirmed-1", "cold", None, now, "confirmed"),
        )
        conn.commit()

        report = generate_report(conn)
        assert report["cold_count"] == 4  # 3 pending + 1 confirmed, all reason=cold
        assert report["contradiction_count"] == 2
        assert report["pending_total"] == 5  # 3 + 2 pending
        assert len(report["sample_cold"]) <= 5
        conn.close()


# ── detect_contradictions ─────────────────────────────────────────────────────

class TestDetectContradictions:
    def test_detect_contradictions_no_api_key(self, tmp_path, monkeypatch):
        """Monkeypatch removes ANTHROPIC_API_KEY → returns []."""
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

        conn = _make_conn(tmp_path)
        migrate_schema(conn)

        result = detect_contradictions(conn)
        assert result == []
        conn.close()


# ── run_health_check ──────────────────────────────────────────────────────────

class TestRunHealthCheck:
    def test_run_health_check_dry_run(self, tmp_path, monkeypatch):
        """dry_run=True → report returned, stale_candidates not written."""
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE radar (
                slug TEXT PRIMARY KEY,
                clsc TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                drawer_path TEXT,
                source_hash TEXT NOT NULL,
                encoded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        # Insert a cold entry
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at) VALUES (?, ?, ?, ?, ?)",
            ("stale-slug", "stale content", 10, "abc", _now_minus(60)),
        )
        conn.commit()
        conn.close()

        # Ensure no API key
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("TELEGRAM_BOT_TOKEN", raising=False)

        report = run_health_check(db_path, dry_run=True)

        # Report should be returned
        assert isinstance(report, dict)
        assert "cold_count" in report
        assert report["cold_count"] >= 1  # the cold entry we inserted

        # stale_candidates should NOT have any rows (dry_run skips write)
        conn2 = sqlite3.connect(str(db_path))
        try:
            count = conn2.execute("SELECT COUNT(*) FROM stale_candidates").fetchone()[0]
            assert count == 0, f"dry_run should not write stale_candidates, but found {count} rows"
        except sqlite3.OperationalError:
            # Table doesn't exist — that's fine, migrate_schema was called but no rows written
            pass
        finally:
            conn2.close()

    def test_run_health_check_db_not_found(self, tmp_path):
        """Non-existent DB returns empty report without crashing."""
        db_path = tmp_path / "nonexistent.db"
        report = run_health_check(db_path, dry_run=True)

        assert report["cold_count"] == 0
        assert report["contradiction_count"] == 0
        assert report["pending_total"] == 0

    def test_run_health_check_live_writes_candidates(self, tmp_path, monkeypatch):
        """dry_run=False → stale_candidates written to DB."""
        db_path = tmp_path / "memory.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("""
            CREATE TABLE radar (
                slug TEXT PRIMARY KEY,
                clsc TEXT NOT NULL,
                tokens INTEGER NOT NULL,
                drawer_path TEXT,
                source_hash TEXT NOT NULL,
                encoded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        # Insert a cold entry
        conn.execute(
            "INSERT INTO radar (slug, clsc, tokens, source_hash, encoded_at) VALUES (?, ?, ?, ?, ?)",
            ("stale-live", "stale content live", 10, "xyz", _now_minus(90)),
        )
        conn.commit()
        conn.close()

        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("TELEGRAM_BOT_TOKEN", raising=False)

        report = run_health_check(db_path, dry_run=False)

        assert report["cold_count"] >= 1

        # stale_candidates should have rows now
        conn2 = sqlite3.connect(str(db_path))
        count = conn2.execute("SELECT COUNT(*) FROM stale_candidates").fetchone()[0]
        assert count >= 1
        conn2.close()

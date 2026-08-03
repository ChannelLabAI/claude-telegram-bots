#!/usr/bin/env python3
"""Regression coverage for CLSC line repair and writer normalization."""
from __future__ import annotations

import importlib.util
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


repair_module = load("repair_chats_clsc", ROOT / "repair-chats-clsc.py")
lint_module = load("clsc_line_lint", ROOT / "clsc-line-lint.py")
ingest_module = load("tg_daily_ingest", ROOT / "tg_daily_ingest.py")


def test_writer_normalizes_all_newline_forms() -> None:
    for newline in ("\n", "\r\n", "\r"):
        _, record = ingest_module.build_clsc_skeleton(
            {"date": "2026-08-03T00:00:00+00:00", "chat_id": 1, "message_id": 2,
             "text": f"first{newline}second"},
            1,
        )
        assert newline not in record
        assert lint_module.is_valid_clsc_line(record)


def test_repair_consumes_continuations_and_is_idempotent() -> None:
    valid = '[tg-20260803-1-2|entity|chat|"first second"|1|neutral|tg]'
    malformed = '[tg-20260803-1-2|entity|chat|"first\nsecond"|1|neutral|tg]'
    unrecoverable = '[tg-20260803-1-3|entity|chat|\n"legacy"|1|neutral|tg]'
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        chats, database, quarantine = root / "chats.md", root / "memory.db", root / "quarantine.md"
        chats.write_text(malformed + "\n" + unrecoverable, encoding="utf-8")
        legacy = '[tg-20260801-1-1|entity|chat|"preserved evidence"|1|neutral|tg]'
        quarantine.write_text(
            "# Unrecoverable malformed CLSC records\n\n"
            "# original_line=999 radar_matches=0\n" + legacy + "\n",
            encoding="utf-8",
        )
        conn = sqlite3.connect(database)
        conn.execute("CREATE TABLE radar (clsc TEXT)")
        conn.execute("INSERT INTO radar VALUES (?)", (valid,))
        conn.commit()
        conn.close()

        first = repair_module.repair(chats, database, quarantine, apply=True)
        after_first = chats.read_bytes()
        quarantine_after_first = quarantine.read_bytes()
        repair_module.merge_quarantine(
            quarantine,
            ["# original_line=123 radar_matches=0\n" + unrecoverable + "\n"],
        )
        assert quarantine.read_bytes() == quarantine_after_first
        second = repair_module.repair(chats, database, quarantine, apply=True)
        assert first == {"restored": 1, "quarantined": 1, "total": 2}
        assert second == {"restored": 0, "quarantined": 0, "total": 0}
        assert chats.read_bytes() == after_first
        assert quarantine.read_bytes() == quarantine_after_first
        assert chats.read_text(encoding="utf-8") == valid + "\n"
        assert unrecoverable in quarantine.read_text(encoding="utf-8")
        assert legacy in quarantine.read_text(encoding="utf-8")
        assert lint_module.lint(chats) == 0


def test_conservation_guard_aborts_before_writes() -> None:
    valid = '[tg-20260803-1-2|entity|chat|"safe"|1|neutral|tg]'
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        chats, database, quarantine = root / "chats.md", root / "memory.db", root / "quarantine.md"
        chats.write_text(valid + "\n", encoding="utf-8")
        quarantine.write_text("preserved\n", encoding="utf-8")
        conn = sqlite3.connect(database)
        conn.execute("CREATE TABLE radar (clsc TEXT)")
        conn.commit()
        conn.close()
        chats_before, quarantine_before = chats.read_bytes(), quarantine.read_bytes()
        try:
            repair_module.assert_conservation(1, 0, 0, 2)
            raise AssertionError("conservation mismatch must abort")
        except RuntimeError as error:
            assert "conservation check failed" in str(error)
        original_guard = repair_module.assert_conservation
        try:
            def abort_before_writes(*_args):
                raise RuntimeError("forced conservation abort")
            repair_module.assert_conservation = abort_before_writes
            repair_module.repair(chats, database, quarantine, apply=True)
            raise AssertionError("repair should have propagated the guard failure")
        except RuntimeError as error:
            assert "forced conservation abort" in str(error)
        finally:
            repair_module.assert_conservation = original_guard
        assert chats.read_bytes() == chats_before
        assert quarantine.read_bytes() == quarantine_before
        assert not chats.with_suffix(chats.suffix + ".pre-29a5.bak").exists()


def test_conservation_guard_survives_python_optimized_mode() -> None:
    script = (
        "import importlib.util; "
        f"spec = importlib.util.spec_from_file_location('repair', {str(ROOT / 'repair-chats-clsc.py')!r}); "
        "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); "
        "module.assert_conservation(1, 0, 0, 999)"
    )
    result = subprocess.run(
        [sys.executable, "-O", "-c", script], text=True, capture_output=True, check=False
    )
    assert result.returncode != 0
    assert "RuntimeError: conservation check failed" in result.stderr


if __name__ == "__main__":
    test_writer_normalizes_all_newline_forms()
    test_repair_consumes_continuations_and_is_idempotent()
    test_conservation_guard_aborts_before_writes()
    test_conservation_guard_survives_python_optimized_mode()
    print("ALL PASS (4/4)")

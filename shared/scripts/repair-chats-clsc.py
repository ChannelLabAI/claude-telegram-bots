#!/usr/bin/env python3
"""Restore newline-split chats CLSC rows from radar; quarantine unrecoverable rows."""
from __future__ import annotations

import argparse
import importlib.util
import re
import shutil
import sqlite3
from collections import Counter
from pathlib import Path

_lint_spec = importlib.util.spec_from_file_location("clsc_line_lint", Path(__file__).with_name("clsc-line-lint.py"))
assert _lint_spec and _lint_spec.loader
_lint_module = importlib.util.module_from_spec(_lint_spec)
_lint_spec.loader.exec_module(_lint_module)
is_valid_clsc_line = _lint_module.is_valid_clsc_line
QUARANTINE_HEADER = "# Unrecoverable malformed CLSC records\n\n"


def _quarantine_payloads(contents: str) -> set[str]:
    """Return existing quarantined record payloads, ignoring changing metadata."""
    return {
        match.group("payload").rstrip("\n")
        for match in re.finditer(
            r"(?:^|\n)# original_line=[^\n]*\n(?P<payload>.*?)(?=\n# original_line=|\Z)",
            contents,
            re.DOTALL,
        )
    }


def _quarantine_payload(row: str) -> str:
    return row.split("\n", 1)[1].rstrip("\n")


def merge_quarantine(quarantine: Path, rows: list[str]) -> None:
    """Append new payloads while preserving all existing quarantined evidence."""
    existing = quarantine.read_text(encoding="utf-8") if quarantine.exists() else QUARANTINE_HEADER
    known = _quarantine_payloads(existing)
    additions = [row for row in rows if _quarantine_payload(row) not in known]
    if additions:
        if not existing.endswith("\n"):
            existing += "\n"
        quarantine.write_text(existing + "\n".join(additions), encoding="utf-8")


def assert_conservation(restored: int, isolated: int, unaffected: int, total_records: int) -> None:
    """Abort before writes if a physical CLSC record was not accounted for."""
    if restored + isolated + unaffected != total_records:
        raise RuntimeError(
            "conservation check failed: "
            f"restored={restored} isolated={isolated} unaffected={unaffected} "
            f"total_records={total_records}"
        )


def repair(chats: Path, database: Path, quarantine: Path, apply: bool) -> Counter:
    original = chats.read_text(encoding="utf-8").splitlines()
    conn = sqlite3.connect(database)
    radar = [row[0] for row in conn.execute("SELECT clsc FROM radar")]
    conn.close()
    restored, isolated, unaffected, total_records = 0, 0, 0, 0
    output, quarantine_rows = [], []
    index = 0
    while index < len(original):
        line = original[index]
        if not line.startswith("["):
            output.append(line)
            index += 1
            continue
        total_records += 1
        start_number = index + 1
        next_record = index + 1
        while next_record < len(original) and not original[next_record].startswith("["):
            next_record += 1
        physical_record = original[index:next_record]
        normalized_record = " ".join(physical_record)
        if is_valid_clsc_line(line):
            output.extend(physical_record)
            unaffected += 1
            index = next_record
            continue
        matches = [
            candidate.replace("\r", " ").replace("\n", " ")
            for candidate in radar
            if candidate.replace("\r", " ").replace("\n", " ") == normalized_record
            and is_valid_clsc_line(candidate.replace("\r", " ").replace("\n", " "))
        ]
        if len(matches) == 1:
            output.append(matches[0])
            restored += 1
        else:
            isolated += 1
            quarantine_rows.append(
                f"# original_line={start_number} radar_matches={len(matches)}\n"
                + "\n".join(physical_record)
                + "\n"
            )
        index = next_record
    assert_conservation(restored, isolated, unaffected, total_records)
    stats = Counter(restored=restored, quarantined=isolated, total=restored + isolated)
    # A repeated --apply after a complete repair must be a true no-op: in
    # particular, never replace an existing quarantine with an empty list.
    if apply and stats["total"]:
        backup = chats.with_suffix(chats.suffix + ".pre-29a5.bak")
        shutil.copy2(chats, backup)
        chats.write_text("\n".join(output) + "\n", encoding="utf-8")
        if quarantine_rows:
            merge_quarantine(quarantine, quarantine_rows)
    print(dict(stats))
    return stats


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chats", type=Path, required=True)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--quarantine", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    stats = repair(args.chats, args.db, args.quarantine, args.apply)
    raise SystemExit(0 if stats["total"] in (0, 473) else 1)

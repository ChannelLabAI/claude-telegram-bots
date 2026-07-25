#!/usr/bin/env python3
"""Conservatively align Anya's morning focus list before it is relayed.

Only a terminal FATQ record identified by its full ID or a unique four-character
suffix can close an item automatically.  Owner messages are candidate signals
only, never a reason to rewrite a decision as a closure.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import tempfile
from pathlib import Path

TERMINAL = {"done", "cancelled", "archived"}
TASK_ID = re.compile(r"\b20\d{6}-\d{4}-[0-9a-f]{4}-[a-z0-9-]+\b", re.I)
SHORT_ID = re.compile(r"(?<![0-9a-f])[0-9a-f]{4}(?![0-9a-f])", re.I)


def load_tasks(root: Path) -> dict[str, tuple[str, str]]:
    records: dict[str, tuple[str, str]] = {}
    for state in ("pending", "in_progress", "review", "done", "cancelled", "archived"):
        directory = root / state
        if not directory.is_dir():
            continue
        for path in directory.glob("*.json"):
            try:
                item = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            task_id = item.get("task_id")
            if isinstance(task_id, str):
                # The queue directory is the state-machine authority.  Do not
                # trust a stale JSON status field to close a focus item.
                records[task_id.lower()] = (state, task_id)
    return records


def owner_decision_text(db_path: Path) -> str:
    if not db_path.is_file():
        return ""
    try:
        with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as conn:
            rows = conn.execute(
                "SELECT prompt FROM tasks WHERE user_id = ? "
                "AND created_at >= datetime('now', '-3 days')",
                ("1050312492",),
            ).fetchall()
    except sqlite3.Error:
        return ""
    return "\n".join(str(row[0] or "") for row in rows)


def has_decision_candidate(line: str, decisions: str) -> bool:
    """Require a specific shared phrase; candidate marking remains non-destructive."""
    for token in re.findall(r"[\u4e00-\u9fff]{4,}", line):
        for width in range(4, min(8, len(token)) + 1):
            if any(token[i : i + width] in decisions for i in range(len(token) - width + 1)):
                return True
    return False


def resolve(line: str, records: dict[str, tuple[str, str]]) -> tuple[str, str] | None:
    for full_id in TASK_ID.findall(line):
        found = records.get(full_id.lower())
        if found:
            return found
    matches = []
    for suffix in SHORT_ID.findall(line):
        candidates = []
        for key, value in records.items():
            parts = key.split("-")
            if len(parts) > 2 and parts[2] == suffix.lower():
                candidates.append(value)
        if len(candidates) == 1:
            matches.extend(candidates)
    unique = {(status, task_id) for status, task_id in matches}
    return unique.pop() if len(unique) == 1 else None


PENDING_NOTE = re.compile(
    r"（(?:FATQ 顯示仍在 [^）]+，不需處置|FATQ 未找到對應單，待 Anya 核對|"
    r"老兔近 3 日裁決候選，待 Anya 核對（原文未自動改寫）)）$"
)


def with_pending_note(line: str, note: str) -> str:
    """Keep a pending focus item visible and replace, rather than stack, our note."""
    eol = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
    body = line[:-len(eol)] if eol else line
    return f"{PENDING_NOTE.sub('', body)}（{note}）{eol}"


def align(vault: Path, task_root: Path, db_path: Path) -> dict[str, int]:
    raw = vault.read_bytes()
    text = raw.decode("utf-8")
    start = text.find("### 進行中")
    if start < 0:
        return {"checked": 0, "closed": 0, "pending": 0}
    end = text.find("### ", start + len("### 進行中"))
    if end < 0:
        end = len(text)
    records, decisions = load_tasks(task_root), owner_decision_text(db_path)
    checked = closed = pending = 0
    rewritten = []
    for line in text[start:end].splitlines(keepends=True):
        if "🟡" not in line:
            rewritten.append(line)
            continue
        checked += 1
        found = resolve(line, records)
        if found:
            status, task_id = found
            if status in TERMINAL:
                newline = line.replace("🟡", "✅", 1).rstrip("\r\n")
                rewritten.append(f"{newline}（已結案：FATQ {task_id}／{status}）" + ("\r\n" if line.endswith("\r\n") else "\n"))
                closed += 1
                continue
            rewritten.append(with_pending_note(line, f"FATQ 顯示仍在 {status}，不需處置"))
            pending += 1
            continue
        pending += 1
        reason = "老兔近 3 日裁決候選，待 Anya 核對（原文未自動改寫）" if has_decision_candidate(line, decisions) else "FATQ 未找到對應單，待 Anya 核對"
        rewritten.append(with_pending_note(line, reason))
    updated = text[:start] + "".join(rewritten) + text[end:]
    if updated != text:
        with tempfile.NamedTemporaryFile("wb", dir=vault.parent, delete=False) as out:
            out.write(updated.encode("utf-8"))
            temporary = Path(out.name)
        temporary.replace(vault)
    return {"checked": checked, "closed": closed, "pending": pending}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True, type=Path)
    parser.add_argument("--tasks-root", required=True, type=Path)
    parser.add_argument("--db", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(align(args.vault, args.tasks_root, args.db), ensure_ascii=False))


if __name__ == "__main__":
    main()

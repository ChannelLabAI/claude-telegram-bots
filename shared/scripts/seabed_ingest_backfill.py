#!/usr/bin/env python3
"""Backfill gateway relay/TG archives into memory.db messages.

This is intentionally conservative:
- relay/read/*.json has full text and is inserted as source=relay-msg.
- gateway log lines only contain previews, so inserted text is explicitly
  prefixed with source_fidelity=preview.
- inserts go through shared/fts5/lib.py for seen-key idempotency and seabed
  mirroring behavior.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path


ROOT = Path.home() / ".claude-bots"
RELAY_RE = re.compile(r"^\[([^\]]+)\] enqueued task from ([^/]+)/([^ ]+) \((.*)\.\.\.\)$")


def parse_ts(value: str) -> datetime | None:
    if not value:
        return None
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s).astimezone(timezone.utc)
    except ValueError:
        return None


def to_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def in_window(ts: str, start: datetime, end: datetime) -> bool:
    dt = parse_ts(ts)
    return bool(dt and start <= dt < end)


def load_bot_map(root: Path) -> dict[str, str]:
    mapping: dict[str, str] = {}
    pods = root / "pod-system" / "pods"
    for path in pods.glob("*.json"):
        try:
            cfg = json.loads(path.read_text())
        except Exception:
            continue
        for bot in cfg.get("bots", []):
            name = bot.get("name")
            username = bot.get("username")
            if name:
                mapping[name.lower()] = name
            if username:
                mapping[username.lower()] = name or username
                mapping[f"@{username}".lower()] = name or username
    return mapping


def relay_rows(root: Path, start: datetime, end: datetime, bot_map: dict[str, str]):
    for path in sorted((root / "relay" / "read").glob("*.json")):
        try:
            payload = json.loads(path.read_text())
        except Exception:
            continue
        ts_raw = payload.get("ts") or ""
        if not in_window(ts_raw, start, end):
            continue
        text = str(payload.get("text") or "").strip()
        if not text:
            continue
        recipient = str(payload.get("recipient") or "").strip()
        bot_name = bot_map.get(recipient.lower(), recipient.lstrip("@") or "unknown")
        msg_id = payload.get("fatq_task_id") or path.name
        yield {
            "bot_name": bot_name,
            "ts": to_z(parse_ts(ts_raw) or start),
            "source": "relay-msg",
            "chat_id": str(payload.get("chat_id") or payload.get("recipient") or ""),
            "user": str(payload.get("from_bot") or "relay"),
            "message_id": f"relay-read|{path.name}|{msg_id}",
            "text": "[source_fidelity=full]\n" + text,
        }


def gateway_preview_rows(root: Path, start: datetime, end: datetime):
    candidates = [
        *root.glob("pod-system/gateway*.log"),
        *root.glob("incident-20260716-seabed-lag/journal-pod@*.log"),
    ]
    seen: set[str] = set()
    for path in sorted(candidates):
        try:
            lines = path.read_text(errors="replace").splitlines()
        except Exception:
            continue
        for line in lines:
            m = RELAY_RE.match(line)
            if not m:
                continue
            ts, bot_name, chat_id, preview = m.groups()
            if not in_window(ts, start, end):
                continue
            key = hashlib.sha256(f"{path}|{line}".encode()).hexdigest()[:24]
            if key in seen:
                continue
            seen.add(key)
            yield {
                "bot_name": bot_name,
                "ts": to_z(parse_ts(ts) or start),
                "source": "telegram",
                "chat_id": chat_id,
                "user": "",
                "message_id": f"gateway-preview|{key}",
                "text": "[source_fidelity=preview]\n" + preview.strip(),
            }


def insert_rows(root: Path, db_path: Path, rows: list[dict], dry_run: bool) -> int:
    if dry_run:
        return len(rows)
    sys.path.insert(0, str(root / "shared" / "fts5"))
    from lib import insert_row  # noqa: PLC0415

    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=10000")
    inserted = 0
    try:
        for row in rows:
            if insert_row(conn, row):
                inserted += 1
        conn.commit()
    finally:
        conn.close()
    return inserted


def rebuild_seabed(days: list[str], db_path: Path, dry_run: bool) -> None:
    script = ROOT / "shared" / "scripts" / "messages-to-reef-seabed.py"
    for day in days:
        cmd = ["python3", str(script), "--date", day, "--db", str(db_path)]
        if dry_run:
            cmd.append("--dry-run")
        subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--db", type=Path, default=ROOT / "memory.db")
    ap.add_argument("--from", dest="from_ts", default="2026-07-11T20:29:00Z")
    ap.add_argument("--to", dest="to_ts", default=datetime.now(timezone.utc).isoformat())
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--rebuild-seabed", action="store_true")
    args = ap.parse_args()

    start = parse_ts(args.from_ts)
    end = parse_ts(args.to_ts)
    if not start or not end or start >= end:
        raise SystemExit("invalid --from/--to window")

    bot_map = load_bot_map(args.root)
    rows = [*relay_rows(args.root, start, end, bot_map), *gateway_preview_rows(args.root, start, end)]
    inserted = insert_rows(args.root, args.db, rows, args.dry_run)
    days = sorted({(parse_ts(r["ts"]) + timedelta(hours=8)).strftime("%Y-%m-%d") for r in rows if parse_ts(r["ts"])})
    print(json.dumps({"candidate_rows": len(rows), "inserted_or_would_insert": inserted, "days": days}, ensure_ascii=False))
    if args.rebuild_seabed and days:
        rebuild_seabed(days, args.db, args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

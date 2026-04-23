#!/usr/bin/env python3
"""
ocean_seabed_rebuild.py — Proof of concept: reconstruct messages list from Ocean/原檔海床 .md files.

This script reads all Seabed .md files and builds an in-memory messages list,
demonstrating that Ocean/原檔海床/ is the source of truth and the FTS index
(memory.db messages table) can be fully reconstructed from it.

Usage:
  python3 ocean_seabed_rebuild.py            # show stats only
  python3 ocean_seabed_rebuild.py --verify   # compare against SQLite DB
  python3 ocean_seabed_rebuild.py --rebuild  # rebuild SQLite FTS index from Seabed files
"""

import argparse
import os
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

OCEAN_SEABED = Path(os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/原檔海床"
))
DB_PATH = os.path.expanduser("~/.claude-bots/memory.db")

# Regex to parse message lines:
# - HH:MM [user] text <!-- mid:MESSAGE_ID -->
LINE_RE = re.compile(
    r"^- (\d{2}:\d{2}) \[([^\]]+)\] (.*?) <!-- mid:([^>]+) -->$"
)

# Frontmatter field extractors
FM_CHAT_ID_RE = re.compile(r'^chat_id:\s*"?([^"\n]+)"?', re.MULTILINE)
FM_CHAT_NAME_RE = re.compile(r'^chat_name:\s*(\S+)', re.MULTILINE)
FM_DATE_RE = re.compile(r'^date:\s*(\S+)', re.MULTILINE)


def parse_seabed_file(file_path: Path) -> list[dict]:
    """
    Parse a single Seabed .md file and return list of message dicts.

    Each dict: {chat_id, chat_name, date, ts, user, message_id, text}
    """
    try:
        content = file_path.read_text(encoding="utf-8")
    except Exception as e:
        print(f"[warn] cannot read {file_path}: {e}")
        return []

    # Extract frontmatter
    chat_id = ""
    chat_name = ""
    date_str = ""
    if content.startswith("---"):
        end = content.find("---", 3)
        if end != -1:
            fm = content[3:end]
            m = FM_CHAT_ID_RE.search(fm)
            if m:
                chat_id = m.group(1).strip()
            m = FM_CHAT_NAME_RE.search(fm)
            if m:
                chat_name = m.group(1).strip()
            m = FM_DATE_RE.search(fm)
            if m:
                date_str = m.group(1).strip()

    messages = []
    for line in content.splitlines():
        line = line.strip()
        m = LINE_RE.match(line)
        if not m:
            continue
        time_str, user, text, message_id = m.groups()

        # Reconstruct ISO timestamp from date + time (assume UTC)
        ts = ""
        if date_str and time_str:
            try:
                ts = f"{date_str}T{time_str}:00.000Z"
            except Exception:
                ts = ""

        messages.append({
            "chat_id": chat_id,
            "chat_name": chat_name,
            "date": date_str,
            "ts": ts,
            "user": user,
            "message_id": message_id,
            "text": text,
            "source_file": str(file_path),
        })

    return messages


def rebuild_messages_list(seabed_dir: Path = OCEAN_SEABED) -> list[dict]:
    """
    Read chat Seabed .md files and return a flat list of all messages.
    Searches chats/ subdir (Phase 1.5+) with fallback to legacy root-level YYYY-MM/ dirs.
    Sorted by ts ascending.
    """
    all_messages = []

    # Phase 1.5 layout: Seabed/chats/YYYY-MM/*.md
    chats_dir = seabed_dir / "chats"
    if chats_dir.exists():
        md_files = sorted(chats_dir.rglob("*.md"))
    else:
        # Legacy layout: Seabed/YYYY-MM/*.md (backward compat — migration not yet run)
        md_files = sorted(
            f for f in seabed_dir.rglob("*.md")
            if f.parent.name[:4].isdigit()  # only YYYY-MM dirs, not reef/ docs/ etc.
        )

    for md_file in md_files:
        msgs = parse_seabed_file(md_file)
        all_messages.extend(msgs)

    # Sort by timestamp
    all_messages.sort(key=lambda m: m.get("ts", ""))
    return all_messages


def verify_against_sqlite(messages: list[dict], db_path: str = DB_PATH) -> dict:
    """
    Compare rebuilt messages list against SQLite messages table.
    Returns stats dict with coverage info.
    """
    conn = sqlite3.connect(db_path)
    try:
        db_rows = conn.execute(
            "SELECT chat_id, message_id FROM messages"
        ).fetchall()
    finally:
        conn.close()

    # Build sets for comparison
    db_keys = {(str(r[0]), str(r[1])) for r in db_rows if r[0] and r[1]}
    seabed_keys = {
        (m["chat_id"], m["message_id"])
        for m in messages
        if m.get("chat_id") and m.get("message_id")
    }

    in_db_not_seabed = db_keys - seabed_keys
    in_seabed_not_db = seabed_keys - db_keys
    in_both = db_keys & seabed_keys

    return {
        "db_total": len(db_keys),
        "seabed_total": len(seabed_keys),
        "in_both": len(in_both),
        "in_db_not_seabed": len(in_db_not_seabed),
        "in_seabed_not_db": len(in_seabed_not_db),
        "coverage_pct": round(len(in_both) / len(db_keys) * 100, 1) if db_keys else 0.0,
        "missing_sample": list(in_db_not_seabed)[:5],
    }


def rebuild_sqlite_fts(messages: list[dict], db_path: str = DB_PATH) -> dict:
    """
    Rebuild the SQLite FTS messages table from Seabed messages list.
    This is a proof of concept — it inserts messages that are in Seabed but not in DB.

    WARNING: Does not delete existing DB records, only adds missing ones.
    """
    conn = sqlite3.connect(db_path)
    inserted = 0
    skipped = 0
    errors = 0

    try:
        for msg in messages:
            chat_id = msg.get("chat_id", "")
            message_id = msg.get("message_id", "")
            if not chat_id or not message_id:
                skipped += 1
                continue

            # Check if already in seen table
            key = f"seabed|telegram|{chat_id}|{message_id}"
            exists = conn.execute(
                "SELECT 1 FROM seen WHERE key = ?", (key,)
            ).fetchone()
            if exists:
                skipped += 1
                continue

            try:
                conn.execute(
                    "INSERT INTO messages(bot_name, ts, source, chat_id, user, message_id, text) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        "seabed_rebuild",
                        msg.get("ts", ""),
                        "telegram",
                        chat_id,
                        msg.get("user", "unknown"),
                        message_id,
                        msg.get("text", ""),
                    ),
                )
                conn.execute("INSERT OR IGNORE INTO seen(key) VALUES (?)", (key,))
                inserted += 1
            except Exception as e:
                errors += 1
                print(f"[warn] insert error for {chat_id}:{message_id}: {e}")

        conn.commit()
    finally:
        conn.close()

    return {"inserted": inserted, "skipped": skipped, "errors": errors}


def main():
    parser = argparse.ArgumentParser(
        description="Rebuild/verify Ocean messages from Seabed .md files"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Compare Seabed messages against SQLite DB and report coverage",
    )
    parser.add_argument(
        "--rebuild",
        action="store_true",
        help="Rebuild SQLite FTS index from Seabed files (adds missing records)",
    )
    parser.add_argument(
        "--db",
        default=DB_PATH,
        help=f"Path to SQLite DB (default: {DB_PATH})",
    )
    parser.add_argument(
        "--seabed",
        default=str(OCEAN_SEABED),
        help=f"Path to Ocean/原檔海床 directory (default: {OCEAN_SEABED})",
    )
    args = parser.parse_args()

    seabed_dir = Path(args.seabed)
    print(f"[ocean_seabed_rebuild] Reading Seabed files from: {seabed_dir}")

    messages = rebuild_messages_list(seabed_dir)
    print(f"[ocean_seabed_rebuild] Parsed {len(messages)} messages from Seabed .md files")

    if not messages:
        print("[ocean_seabed_rebuild] No messages found. Has backfill been run?")
        return

    # Show per-chat stats
    from collections import Counter
    chat_counts = Counter(m["chat_id"] for m in messages)
    print("\nMessages per chat:")
    for chat_id, count in chat_counts.most_common():
        from ocean_seabed_write import get_chat_name
        name = get_chat_name(chat_id)
        print(f"  {name:30s}  {count:5d}")

    if args.verify or args.rebuild:
        print(f"\n[ocean_seabed_rebuild] Verifying against DB: {args.db}")
        stats = verify_against_sqlite(messages, db_path=args.db)
        print(f"\nVerification results:")
        print(f"  DB total           : {stats['db_total']}")
        print(f"  Seabed total       : {stats['seabed_total']}")
        print(f"  In both            : {stats['in_both']}")
        print(f"  DB coverage        : {stats['coverage_pct']}%")
        print(f"  In DB not Seabed   : {stats['in_db_not_seabed']}")
        print(f"  In Seabed not DB   : {stats['in_seabed_not_db']}")
        if stats["missing_sample"]:
            print(f"  Missing sample     : {stats['missing_sample'][:3]}")

    if args.rebuild:
        print(f"\n[ocean_seabed_rebuild] Rebuilding SQLite FTS from Seabed...")
        rebuild_stats = rebuild_sqlite_fts(messages, db_path=args.db)
        print(f"Rebuild complete:")
        print(f"  Inserted : {rebuild_stats['inserted']}")
        print(f"  Skipped  : {rebuild_stats['skipped']}")
        print(f"  Errors   : {rebuild_stats['errors']}")


if __name__ == "__main__":
    main()

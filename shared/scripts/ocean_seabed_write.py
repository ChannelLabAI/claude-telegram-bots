#!/usr/bin/env python3
"""
ocean_seabed_write.py — Ocean Origin Rule: write TG messages to Ocean/Seabed .md files.

Each TG message is appended to:
  Ocean/Seabed/YYYY-MM/YYYY-MM-DD-{chat_name}.md

File format:
  --- (YAML frontmatter)
  type: seabed
  chat_id: "1050312492"
  chat_name: oldrabbit-private
  date: 2026-04-15
  source: telegram
  ---
  - 09:30 [oldrabbit_eth] message text here
  - 09:31 [anna] reply text here

Atomic write: append to temp file in same dir, then rename.
Dedup: check if message_id already exists in file before writing.

Usage:
  python3 ocean_seabed_write.py --backfill  # backfill all messages from SQLite
"""

import argparse
import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
OCEAN_SEABED = Path(os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/Seabed"
))
DB_PATH = os.path.expanduser("~/.claude-bots/memory.db")

# chat_id → human-readable name mapping
# Sources: team-config.json + known private chats
CHAT_NAME_MAP: dict[str, str] = {
    # Private DMs (user_id based)
    "1050312492": "oldrabbit-private",
    "2114307569": "caijie-private",
    "5288537361": "ron-private",
    "7132373174": "nicky-private",
    "8201149279": "taotao-private",
    "5728956655": "chuange-private",
    # Groups (from team-config.json)
    "-1003634255226": "team-main",
    "-5175060310": "coordinator",
    "-1005267778636": "lt-command",
    "-5267778636": "lt-command",       # old ID before supergroup upgrade
    "-1003612111775": "ron-command",
    "-5002663624": "nicky-command",
    "-5180494548": "cj-command",
    "-5291099801": "taotao-command",
    "-5034023909": "cj-extra-1",
    "-5200547431": "cj-extra-2",
    "-5103207922": "test-group",
    "-5145214198": "unknown-group-5145214198",
    "-5208584620": "unknown-group-5208584620",
}


def get_chat_name(chat_id: str) -> str:
    """Map chat_id to a human-readable name. Falls back to sanitized chat_id."""
    chat_id = str(chat_id).strip()
    if chat_id in CHAT_NAME_MAP:
        return CHAT_NAME_MAP[chat_id]
    # For unknown IDs, create a sanitized name
    safe = chat_id.replace("-", "neg").replace("+", "")
    return f"chat-{safe}"


def seabed_file_path(chat_id: str, ts: str) -> Path:
    """
    Compute the Seabed chat file path for a given chat_id and ISO timestamp.
    Returns: Ocean/Seabed/chats/YYYY-MM/YYYY-MM-DD-{chat_name}.md  (Phase 1.5+)
    """
    chat_name = get_chat_name(chat_id)
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        # Convert to UTC+8 for date (Taiwan timezone)
        from datetime import timedelta
        dt_local = dt.utctimetuple()
        # Use the raw UTC date for simplicity (consistent with DB storage)
        date_str = dt.strftime("%Y-%m-%d")
        month_str = dt.strftime("%Y-%m")
    except Exception:
        now = datetime.now(timezone.utc)
        date_str = now.strftime("%Y-%m-%d")
        month_str = now.strftime("%Y-%m")

    return OCEAN_SEABED / "chats" / month_str / f"{date_str}-{chat_name}.md"


def _build_frontmatter(chat_id: str, chat_name: str, date_str: str) -> str:
    """Build YAML frontmatter for a Seabed file."""
    return (
        "---\n"
        f"type: seabed\n"
        f"chat_id: \"{chat_id}\"\n"
        f"chat_name: {chat_name}\n"
        f"date: {date_str}\n"
        f"source: telegram\n"
        "---\n"
    )


def _message_line(ts: str, user: str, text: str, message_id: str) -> str:
    """Format a single message as a markdown list item with hidden message_id anchor."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        time_str = dt.strftime("%H:%M")
    except Exception:
        time_str = "??:??"

    # Sanitize: replace newlines in text with space so one message = one line
    clean_text = (text or "").replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    # Use message_id as anchor so dedup can scan for it
    return f"- {time_str} [{user}] {clean_text} <!-- mid:{message_id} -->\n"


def _message_already_written(file_path: Path, message_id: str) -> bool:
    """Check if a message_id anchor already exists in the file."""
    if not file_path.exists():
        return False
    try:
        content = file_path.read_text(encoding="utf-8")
        return f"<!-- mid:{message_id} -->" in content
    except Exception:
        return False


def write_message_to_seabed(msg: dict) -> bool:
    """
    Write a single message dict to the appropriate Seabed .md file.

    Expected keys: chat_id, message_id, user, ts, text
    Optional: bot_name, source

    Returns True if message was written, False if skipped (already exists).
    Raises on file I/O errors.
    """
    chat_id = str(msg.get("chat_id", ""))
    message_id = str(msg.get("message_id", ""))
    user = str(msg.get("user", "unknown"))
    ts = str(msg.get("ts", ""))
    text = str(msg.get("text", ""))

    # Skip empty/system messages
    if not chat_id or chat_id in ("self", "system", ""):
        return False
    if not text.strip():
        return False

    file_path = seabed_file_path(chat_id, ts)
    chat_name = get_chat_name(chat_id)

    # Dedup check
    if message_id and _message_already_written(file_path, message_id):
        return False

    # Ensure directory exists
    file_path.parent.mkdir(parents=True, exist_ok=True)

    # Build frontmatter if file doesn't exist yet
    needs_frontmatter = not file_path.exists()

    try:
        date_str = datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%Y-%m-%d")
    except Exception:
        date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    line = _message_line(ts, user, text, message_id)

    # Atomic append: write to temp file in same dir, then rename
    # Since we're appending, we need to read existing + append + write atomically
    try:
        if needs_frontmatter:
            new_content = _build_frontmatter(chat_id, chat_name, date_str) + line
        else:
            existing = file_path.read_text(encoding="utf-8")
            new_content = existing + line

        # Write to temp file in same directory, then rename
        dir_path = file_path.parent
        fd, tmp_path = tempfile.mkstemp(dir=dir_path, suffix=".tmp", prefix=".seabed-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(new_content)
            os.replace(tmp_path, file_path)
        except Exception:
            # Clean up temp file on error
            try:
                os.unlink(tmp_path)
            except Exception:
                pass
            raise

    except Exception as e:
        raise RuntimeError(f"Failed to write seabed {file_path}: {e}") from e

    return True


def backfill_from_sqlite(db_path: str = DB_PATH, verbose: bool = True) -> dict:
    """
    Backfill all messages from SQLite messages table into Seabed .md files.

    Returns summary stats dict.
    """
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            "SELECT bot_name, ts, source, chat_id, user, message_id, text "
            "FROM messages "
            "ORDER BY ts ASC"
        ).fetchall()
    finally:
        conn.close()

    if verbose:
        print(f"[ocean_seabed_write] backfill: {len(rows)} messages from {db_path}")

    written = 0
    skipped = 0
    errors = 0

    for i, row in enumerate(rows):
        bot_name, ts, source, chat_id, user, message_id, text = row
        msg = {
            "bot_name": bot_name,
            "ts": ts or "",
            "source": source or "telegram",
            "chat_id": str(chat_id) if chat_id else "",
            "user": user or "unknown",
            "message_id": str(message_id) if message_id else "",
            "text": text or "",
        }
        try:
            result = write_message_to_seabed(msg)
            if result:
                written += 1
            else:
                skipped += 1
        except Exception as e:
            errors += 1
            if verbose:
                print(f"[warn] row {i}: {e}")

        if verbose and (i + 1) % 500 == 0:
            print(f"[ocean_seabed_write] {i+1}/{len(rows)} processed "
                  f"(written={written}, skipped={skipped}, errors={errors})")

    stats = {
        "total": len(rows),
        "written": written,
        "skipped": skipped,
        "errors": errors,
    }
    if verbose:
        print(f"[ocean_seabed_write] backfill done: {stats}")
    return stats


def main():
    parser = argparse.ArgumentParser(description="Ocean Seabed write utility")
    parser.add_argument(
        "--backfill",
        action="store_true",
        help="Backfill all messages from SQLite into Ocean/Seabed .md files",
    )
    parser.add_argument(
        "--db",
        default=DB_PATH,
        help=f"Path to SQLite DB (default: {DB_PATH})",
    )
    args = parser.parse_args()

    if args.backfill:
        stats = backfill_from_sqlite(db_path=args.db, verbose=True)
        print(f"\nBackfill complete:")
        print(f"  Total messages : {stats['total']}")
        print(f"  Written        : {stats['written']}")
        print(f"  Skipped (dedup): {stats['skipped']}")
        print(f"  Errors         : {stats['errors']}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()

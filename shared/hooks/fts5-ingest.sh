#!/usr/bin/env bash
# fts5-ingest.sh — Ingest a task JSON's learnings into memory.db FTS5 index.
#
# Usage:
#   bash fts5-ingest.sh <task_json_file>
#
# Also usable as a PostToolUse hook (no args): ingests inbox messages and
# relay log for the current bot session (original fts5-ingest.sh behavior).
#
# Exit codes:
#   0 — success (or nothing to ingest)
#   1 — ingest failed (caller should log failure and NOT mark as ingested)
#
# Design:
#   - idempotent: INSERT OR IGNORE on seen.key, safe to retry
#   - task learnings are stored in messages table with source='task-learnings'
#   - The seen key for task learnings: 'task-learnings|<task_id>|<task_id>|<task_id>'
set -uo pipefail

STATE_DIR="${TELEGRAM_STATE_DIR:-}"
INGEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fts5"
DB_PATH="$HOME/.claude-bots/memory.db"

# ── Mode A: task learnings ingest (when called with a task JSON file arg) ──
if [[ $# -ge 1 ]]; then
    TASK_FILE="$1"
    if [[ ! -f "$TASK_FILE" ]]; then
        echo "fts5-ingest: task file not found: $TASK_FILE" >&2
        exit 1
    fi

    python3 - "$TASK_FILE" "$DB_PATH" "$INGEST_DIR" <<'PYEOF'
#!/usr/bin/env python3
"""Ingest task JSON learnings into FTS5 messages table."""
import sys
import json
import os
from pathlib import Path
from datetime import datetime, timezone

task_file = Path(sys.argv[1])
db_path = Path(sys.argv[2])
fts5_dir = Path(sys.argv[3])

# Load the fts5 lib
sys.path.insert(0, str(fts5_dir))
try:
    from lib import open_db, insert_row
except ImportError as e:
    print(f"fts5-ingest: cannot import fts5 lib from {fts5_dir}: {e}", file=sys.stderr)
    sys.exit(1)

# Parse task JSON
try:
    with open(task_file) as f:
        task = json.load(f)
except Exception as e:
    print(f"fts5-ingest: cannot parse {task_file}: {e}", file=sys.stderr)
    sys.exit(1)

# Extract task_id
task_id = (
    task.get('id')
    or task.get('task_id')
    or task_file.stem  # filename without .json
)

# Extract learnings (support 'learnings' list or 'learning' string)
learnings_raw = task.get('learnings') or task.get('learning')
if not learnings_raw:
    # Nothing to ingest — not an error
    print(f"fts5-ingest: {task_id} has no learnings field, nothing to do", file=sys.stderr)
    sys.exit(0)

# Normalize to string
if isinstance(learnings_raw, list):
    learnings_text = '\n'.join(str(x) for x in learnings_raw)
elif isinstance(learnings_raw, dict):
    learnings_text = json.dumps(learnings_raw, ensure_ascii=False, indent=2)
else:
    learnings_text = str(learnings_raw)

# Also include task title/summary for richer search context
title = task.get('title', '')
full_text = f"[task-learnings] {title}\ntask_id: {task_id}\n\n{learnings_text}"

# Determine bot_name from assigned_to or task path
bot_name = task.get('assigned_to', '') or task.get('assigned_by', '') or 'unknown'

# Timestamp: use latest history entry, or created_at, or file mtime
ts = ''
history = task.get('history', [])
if history and isinstance(history, list):
    last = history[-1]
    ts = last.get('at', '')
if not ts:
    ts = task.get('created_at', '')
if not ts:
    try:
        mtime = task_file.stat().st_mtime
        ts = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
    except Exception:
        pass

row = {
    'bot_name': bot_name,
    'ts': ts,
    'source': 'task-learnings',
    'chat_id': '',
    'user': bot_name,
    'message_id': task_id,  # used as seen key component
    'text': full_text,
}

try:
    conn = open_db()
    inserted = insert_row(conn, row)
    conn.commit()
    conn.close()
    if inserted:
        print(f"fts5-ingest: ingested task learnings for {task_id}", file=sys.stderr)
    else:
        print(f"fts5-ingest: {task_id} already in index (idempotent skip)", file=sys.stderr)
    sys.exit(0)
except Exception as e:
    print(f"fts5-ingest: DB error for {task_id}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    exit $?
fi

# ── Mode B: inbox/relay ingest (original PostToolUse hook behavior, no args) ──
[[ -z "$STATE_DIR" ]] && exit 0

INGEST_SCRIPT="$HOME/.claude-bots/shared/fts5/ingest_one.py"

MESSAGES_DIR="$STATE_DIR/inbox/messages"
if [[ -d "$MESSAGES_DIR" ]]; then
  nohup python3 "$INGEST_SCRIPT" "$MESSAGES_DIR" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

RELAY_LOG="$STATE_DIR/relay-messages.log"
if [[ -f "$RELAY_LOG" ]]; then
  nohup python3 "$INGEST_SCRIPT" "$RELAY_LOG" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exit 0

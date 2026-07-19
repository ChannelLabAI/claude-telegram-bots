#!/usr/bin/env bash
# cache-metrics-logger.sh — Stop hook: append cache metrics to JSONL
#
# Parses the Claude Code session transcript at stop time.
# Extracts per-turn cache usage (cache_creation_input_tokens,
# cache_read_input_tokens, input_tokens) and appends one JSONL line
# per assistant turn to ~/.claude-bots/bots/{name}/cache-metrics.jsonl.
#
# Install in each bot's settings.json under Stop hooks (AFTER save-session):
#
#   "Stop": [{
#     "matcher": "",
#     "hooks": [
#       {"type": "command", "command": "bash ~/.claude-bots/shared/hooks/cache-metrics-logger.sh"},
#       ...
#     ]
#   }]
#
# Output format (one JSON line per turn):
#   {"ts":"...", "bot":"...", "session_id":"...", "turn_idx":N,
#    "cache_create":N, "cache_read":N, "input":N,
#    "hit_rate":0.NN}

set -euo pipefail

# Guarantee Stop hook always emits valid JSON — metrics failure must never block shutdown
trap 'echo "{}"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/stop_hook_lib.sh"

# Dead-loop guard (reads stdin into $STOP_HOOK_LIB_INPUT)
guard_stop_hook_active

BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ -z "$BOT_NAME" ]]; then
    echo "{}"
    exit 0
fi

STATE_DIR="$HOME/.claude-bots/bots/$BOT_NAME"
METRICS_FILE="$STATE_DIR/cache-metrics.jsonl"
CURSOR_FILE="$STATE_DIR/.cache-metrics-cursor.json"
LOCK_FILE="$STATE_DIR/.cache-metrics-cursor.lock"

python3 - "$BOT_NAME" "$METRICS_FILE" "$CURSOR_FILE" "$LOCK_FILE" <<'PYEOF'
import sys, json, os, fcntl
from pathlib import Path
from datetime import datetime, timezone

bot_name = sys.argv[1]
metrics_file = Path(sys.argv[2])
cursor_file = Path(sys.argv[3])
lock_file = Path(sys.argv[4])
metrics_file.parent.mkdir(parents=True, exist_ok=True)

# Parse stop hook input from env (set by guard_stop_hook_active via STOP_HOOK_LIB_INPUT)
raw_input = os.environ.get("STOP_HOOK_LIB_INPUT", "{}")
try:
    hook_data = json.loads(raw_input)
except json.JSONDecodeError:
    hook_data = {}

session_id = hook_data.get("session_id", "unknown")
transcript_path = hook_data.get("transcript_path", "")

if not transcript_path or not Path(transcript_path).exists():
    sys.exit(0)

# Stop can fire after every response. Keep a byte offset per session so each
# invocation reads and records only newly appended transcript lines. The old
# implementation re-read and re-appended the full transcript every time,
# causing quadratic CPU, I/O, and log growth.
with open(lock_file, "a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    try:
        state = json.loads(cursor_file.read_text()) if cursor_file.exists() else {}
    except (json.JSONDecodeError, OSError):
        state = {}

    session_state = state.get(session_id, {})
    offset = int(session_state.get("offset", 0))
    turn_idx = int(session_state.get("turn_idx", 0))
    transcript_size = Path(transcript_path).stat().st_size
    if offset < 0 or offset > transcript_size:
        offset = 0
        turn_idx = 0

    entries = []
    next_offset = offset
    with open(transcript_path, "rb") as tf:
        tf.seek(offset)
        while True:
            line_start = tf.tell()
            raw_line = tf.readline()
            if not raw_line:
                break
            if not raw_line.endswith(b"\n"):
                tf.seek(line_start)
                break
            next_offset = tf.tell()
            try:
                msg = json.loads(raw_line.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue

            role = msg.get("role") or msg.get("type", "")
            if role != "assistant":
                continue
            usage = msg.get("usage") or msg.get("message", {}).get("usage", {})
            current_turn = turn_idx
            turn_idx += 1
            if not usage:
                continue

            cache_create = int(usage.get("cache_creation_input_tokens") or 0)
            cache_read = int(usage.get("cache_read_input_tokens") or 0)
            input_tok = int(usage.get("input_tokens") or 0)
            if cache_create == 0 and cache_read == 0:
                continue

            total_input = cache_create + cache_read + input_tok
            entries.append({
                "ts": msg.get("timestamp") or datetime.now(timezone.utc).isoformat(),
                "bot": bot_name,
                "session_id": session_id,
                "turn_idx": current_turn,
                "cache_create": cache_create,
                "cache_read": cache_read,
                "input": input_tok,
                "hit_rate": round(cache_read / total_input, 4) if total_input > 0 else 0.0,
            })

    if entries:
        with open(metrics_file, "a", encoding="utf-8") as mf:
            mf.writelines(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries)

    state[session_id] = {"offset": next_offset, "turn_idx": turn_idx, "updated_at": datetime.now(timezone.utc).isoformat()}
    # Bound cursor growth while preserving the most recently updated sessions.
    state = dict(sorted(state.items(), key=lambda item: item[1].get("updated_at", ""), reverse=True)[:50])
    tmp = cursor_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, cursor_file)

if entries:
    print(f"cache-metrics: wrote {len(entries)} new turn(s) for {bot_name}", file=sys.stderr)
PYEOF

# Allow Claude to stop normally (no block)
echo "{}"

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

METRICS_FILE="$HOME/.claude-bots/bots/$BOT_NAME/cache-metrics.jsonl"

python3 - "$BOT_NAME" "$METRICS_FILE" <<'PYEOF'
import sys, json, re
from pathlib import Path
from datetime import datetime, timezone

bot_name = sys.argv[1]
metrics_file = Path(sys.argv[2])
metrics_file.parent.mkdir(parents=True, exist_ok=True)

# Parse stop hook input from env (set by guard_stop_hook_active via STOP_HOOK_LIB_INPUT)
import os
raw_input = os.environ.get("STOP_HOOK_LIB_INPUT", "{}")
try:
    hook_data = json.loads(raw_input)
except json.JSONDecodeError:
    hook_data = {}

session_id = hook_data.get("session_id", "unknown")
transcript_path = hook_data.get("transcript_path", "")

if not transcript_path or not Path(transcript_path).exists():
    sys.exit(0)

# Parse transcript JSONL for assistant turns with usage data
lines_written = 0
turn_idx = 0
with open(transcript_path, encoding="utf-8", errors="replace") as tf:
    for raw_line in tf:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            msg = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        # Look for assistant messages with usage metadata
        role = msg.get("role") or msg.get("type", "")
        if role not in ("assistant",):
            continue

        usage = msg.get("usage") or msg.get("message", {}).get("usage", {})
        if not usage:
            continue

        cache_create = int(usage.get("cache_creation_input_tokens") or 0)
        cache_read = int(usage.get("cache_read_input_tokens") or 0)
        input_tok = int(usage.get("input_tokens") or 0)

        # Only log if at least one cache field is non-zero
        if cache_create == 0 and cache_read == 0:
            turn_idx += 1
            continue

        total_input = cache_create + cache_read + input_tok
        hit_rate = round(cache_read / total_input, 4) if total_input > 0 else 0.0

        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "bot": bot_name,
            "session_id": session_id,
            "turn_idx": turn_idx,
            "cache_create": cache_create,
            "cache_read": cache_read,
            "input": input_tok,
            "hit_rate": hit_rate,
        }

        with open(metrics_file, "a", encoding="utf-8") as mf:
            mf.write(json.dumps(entry, ensure_ascii=False) + "\n")
        lines_written += 1
        turn_idx += 1

if lines_written > 0:
    print(f"cache-metrics: wrote {lines_written} turn(s) for {bot_name}", file=sys.stderr)
PYEOF

# Allow Claude to stop normally (no block)
echo "{}"

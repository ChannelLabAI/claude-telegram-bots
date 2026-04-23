#!/bin/bash
# task-done-extract.sh — auto-classify learnings when a task moves review → done.
#
# Usage:
#   task-done-extract.sh <task_json_path>
#
# Behaviour:
#   1. Reads the task JSON (from tasks/done/).
#   2. Extracts the task's learnings text (learnings / deliverable / spec fields).
#   3. Runs memory_extractor.classify_text and writes the classification to:
#        ~/.claude-bots/logs/task-done-extract.log
#   4. If the task JSON references a card under Cards/learnings/, also updates
#      that card's frontmatter with `memory_type:`.
#
# Non-destructive: never mutates the task JSON itself.
# Safe to call from clsc-sync.sh or any other hook that observes done/ moves.

set -euo pipefail

LIB_DIR="$HOME/.claude-bots/shared/lib"
LOG="$HOME/.claude-bots/logs/task-done-extract.log"
VAULT="$HOME/Documents/Obsidian Vault"

mkdir -p "$(dirname "$LOG")"

if [[ $# -lt 1 ]]; then
    echo "Usage: task-done-extract.sh <task_json_path>" >&2
    exit 2
fi

TASK_FILE="$1"

if [[ ! -f "$TASK_FILE" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR not-found: $TASK_FILE" >> "$LOG"
    exit 1
fi

python3 - "$TASK_FILE" "$VAULT" "$LOG" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".claude-bots" / "shared" / "lib"))
from memory_extractor import classify_text, tag_file_frontmatter  # noqa: E402

task_path = Path(sys.argv[1])
vault = Path(sys.argv[2])
log_path = Path(sys.argv[3])

try:
    task = json.loads(task_path.read_text(encoding="utf-8"))
except Exception as e:
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"[{datetime.now(timezone.utc).isoformat()}] PARSE_ERROR {task_path}: {e}\n")
    sys.exit(1)

def _flatten(obj):
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj
    if isinstance(obj, (int, float, bool)):
        return str(obj)
    if isinstance(obj, list):
        return "\n".join(_flatten(x) for x in obj)
    if isinstance(obj, dict):
        return "\n".join(f"{k}: {_flatten(v)}" for k, v in obj.items())
    return str(obj)

parts = []
for key in ("learnings", "deliverable", "spec", "title", "credit"):
    val = task.get(key)
    if val:
        parts.append(_flatten(val))
text = "\n\n".join(parts).strip()

mtype = classify_text(text) if text else None
stamp = datetime.now(timezone.utc).isoformat()
with log_path.open("a", encoding="utf-8") as f:
    f.write(f"[{stamp}] {task_path.name} -> {mtype or 'none'}\n")

# Optional: if the task mentions a learnings card path, tag it.
# Convention: task['learnings_card'] = "Ocean/珍珠卡/learnings/foo.md" (relative to vault)
card_rel = task.get("learnings_card")
if card_rel and mtype:
    card = vault / card_rel
    if card.exists():
        try:
            changed = tag_file_frontmatter(card, mtype)
            with log_path.open("a", encoding="utf-8") as f:
                f.write(
                    f"[{stamp}]   card {'TAGGED' if changed else 'UNCHANGED'} {mtype} {card_rel}\n"
                )
        except Exception as e:
            with log_path.open("a", encoding="utf-8") as f:
                f.write(f"[{stamp}]   card ERROR {card_rel}: {e}\n")

print(mtype or "none")
PY

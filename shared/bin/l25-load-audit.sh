#!/usr/bin/env bash
# Aggregate logs/l25-trigger.jsonl.
# JSONL schema (one eligible load/dedup attempt per row):
#   ts:string, session_id:string, bot:string, event:string, block:string,
#   bytes:int (source file bytes), context_bytes:int (injected body UTF-8 bytes),
#   first_in_session:bool, injected:bool.

set -euo pipefail

LOG_PATH="${L25_LOG_PATH:-$HOME/.claude-bots/logs/l25-trigger.jsonl}"
SORT_BY="loads"

usage() {
    echo "Usage: l25-load-audit.sh [--log PATH] [--sort loads|count|bytes|saved|attempts]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log) [[ $# -ge 2 ]] || usage; LOG_PATH="$2"; shift 2 ;;
        --sort) [[ $# -ge 2 ]] || usage; SORT_BY="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ "$SORT_BY" == "count" ]] && SORT_BY="loads"
case "$SORT_BY" in loads|bytes|saved|attempts) ;; *) usage ;; esac

if [[ ! -r "$LOG_PATH" ]]; then
    echo "[l25-load-audit] ERROR: unreadable log: $LOG_PATH" >&2
    exit 2
fi

python3 - "$LOG_PATH" "$SORT_BY" <<'PYEOF'
import json
import sys
from collections import defaultdict

path, sort_by = sys.argv[1:]
required = {
    "ts": str,
    "session_id": str,
    "bot": str,
    "event": str,
    "block": str,
    "bytes": int,
    "context_bytes": int,
    "first_in_session": bool,
    "injected": bool,
}
totals = defaultdict(lambda: {
    "attempts": 0,
    "loads": 0,
    "cumulative_bytes": 0,
    "dedup_hits": 0,
    "dedup_saved_bytes": 0,
})

with open(path, encoding="utf-8") as handle:
    for line_no, line in enumerate(handle, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            print(f"[l25-load-audit] ERROR: line {line_no}: invalid JSON: {exc}", file=sys.stderr)
            sys.exit(2)
        for field, kind in required.items():
            if field not in row or type(row[field]) is not kind:
                print(f"[l25-load-audit] ERROR: line {line_no}: {field} must be {kind.__name__}", file=sys.stderr)
                sys.exit(2)
        if row["bytes"] < 0 or row["context_bytes"] < 0:
            print(f"[l25-load-audit] ERROR: line {line_no}: byte counts must be non-negative", file=sys.stderr)
            sys.exit(2)

        item = totals[row["block"]]
        item["attempts"] += 1
        if row["first_in_session"]:
            item["loads"] += 1
            item["cumulative_bytes"] += row["bytes"]
        else:
            item["dedup_hits"] += 1
            item["dedup_saved_bytes"] += row["bytes"]

key_field = {
    "loads": "loads",
    "bytes": "cumulative_bytes",
    "saved": "dedup_saved_bytes",
    "attempts": "attempts",
}[sort_by]
rows = sorted(totals.items(), key=lambda pair: (-pair[1][key_field], pair[0]))

print("block\tloads\tcumulative_bytes\tdedup_hits\tdedup_saved_bytes\tattempts")
for block, item in rows:
    print("\t".join([
        block,
        str(item["loads"]),
        str(item["cumulative_bytes"]),
        str(item["dedup_hits"]),
        str(item["dedup_saved_bytes"]),
        str(item["attempts"]),
    ]))
PYEOF

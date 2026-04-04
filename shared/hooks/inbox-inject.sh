#!/usr/bin/env bash
# PostToolUse hook: surface undelivered Telegram messages to Claude
# Runs after every tool call. Fast-exits (<5ms) when inbox is empty.
set -uo pipefail

STATE_DIR="${TELEGRAM_STATE_DIR:-}"
[[ -z "$STATE_DIR" ]] && exit 0

MESSAGES_DIR="$STATE_DIR/inbox/messages"
[[ ! -d "$MESSAGES_DIR" ]] && exit 0

shopt -s nullglob
files=("$MESSAGES_DIR"/*.json)
shopt -u nullglob
[[ ${#files[@]} -eq 0 ]] && exit 0

for f in "${files[@]}"; do
  python3 - "$f" <<'PYEOF' && mv "$f" "${f}.delivered" 2>/dev/null || true
import json, sys
f = sys.argv[1]
try:
    with open(f) as fp:
        data = json.load(fp)
    params = data.get('params', {})
    text = params.get('content', '')
    meta = params.get('meta', {})
    attrs = ' '.join(f'{k}="{v}"' for k, v in meta.items())
    print(f'<channel source="telegram" {attrs}>{text}</channel>')
except Exception:
    sys.exit(1)
PYEOF
done

exit 0

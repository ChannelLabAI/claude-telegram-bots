#!/usr/bin/env bash
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ -z "$BOT_NAME" ]]; then exit 0; fi
SESSION_FILE="$HOME/.claude-bots/state/$BOT_NAME/session.json"
if [[ ! -f "$SESSION_FILE" ]]; then exit 0; fi
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)
if python3 -c "
import json, sys
with open('$SESSION_FILE') as f:
    s = json.load(f)
s['lastActiveAt'] = '$TIMESTAMP'
s['memoryCheckNeeded'] = True
with open('$TMP', 'w') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
" 2>/dev/null; then
    mv "$TMP" "$SESSION_FILE"
else
    rm -f "$TMP"
fi
exit 0

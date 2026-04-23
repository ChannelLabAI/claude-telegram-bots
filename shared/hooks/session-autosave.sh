#!/usr/bin/env bash
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ -z "$BOT_NAME" ]]; then exit 0; fi
SESSION_FILE="$HOME/.claude-bots/bots/$BOT_NAME/session.json"
if [[ ! -f "$SESSION_FILE" ]]; then exit 0; fi
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)
if SESSION_FILE="$SESSION_FILE" TIMESTAMP="$TIMESTAMP" TMP="$TMP" python3 <<'EOF' 2>/dev/null
import json, os
session_file = os.environ['SESSION_FILE']
timestamp = os.environ['TIMESTAMP']
tmp = os.environ['TMP']
with open(session_file) as f:
    s = json.load(f)
s['lastActiveAt'] = timestamp
s['memoryCheckNeeded'] = True
with open(tmp, 'w') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
EOF
then
    mv "$TMP" "$SESSION_FILE"
else
    rm -f "$TMP"
fi
exit 0

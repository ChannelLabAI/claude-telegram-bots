#!/usr/bin/env bash
# Hook 3: Session Auto-save — Stop event
# Updates lastActiveAt in session.json when the Claude session ends.
# This ensures the session file is always up-to-date even if the bot
# forgot to explicitly save during the session.

BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")

if [[ -z "$BOT_NAME" ]]; then
    exit 0
fi

SESSION_FILE="$HOME/.claude-bots/state/$BOT_NAME/session.json"

if [[ ! -f "$SESSION_FILE" ]]; then
    exit 0
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)

# Update lastActiveAt atomically
if python3 -c "
import json, sys
with open('$SESSION_FILE') as f:
    s = json.load(f)
s['lastActiveAt'] = '$TIMESTAMP'
with open('$TMP', 'w') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
" 2>/dev/null; then
    mv "$TMP" "$SESSION_FILE"
else
    rm -f "$TMP"
fi

exit 0

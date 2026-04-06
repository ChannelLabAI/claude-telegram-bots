#!/usr/bin/env bash
# Start: {{BOT_NAME}} (@{{BOT_USERNAME}})
# Features: auto-restart with backoff, boot trigger, session cleanup

cd "$(dirname "$0")"

# Auto-patch plugin on startup
"$HOME/.claude-bots/patch-server.sh" 2>/dev/null || true

BOT_NAME="{{BOT_NAME}}"
BOT_USERNAME="{{BOT_USERNAME}}"
RELAY_DIR="$HOME/.claude-bots/relay"
STATE_DIR="$HOME/.claude-bots/state/$BOT_NAME"
SESSION_FILE="$STATE_DIR/session.json"

# --- Session cleanup: clear completedToday if new day ---
if [[ -f "$SESSION_FILE" ]]; then
  LAST_DATE=$(python3 -c "
import json
with open('$SESSION_FILE') as f:
    s = json.load(f)
print(s.get('lastActiveAt','')[:10])
" 2>/dev/null)
  TODAY=$(date -u '+%Y-%m-%d')
  if [[ -n "$LAST_DATE" && "$LAST_DATE" != "$TODAY" ]]; then
    TMP=$(mktemp)
    python3 -c "
import json
with open('$SESSION_FILE') as f:
    s = json.load(f)
s['completedToday'] = []
s['notes'] = ''
with open('$TMP', 'w') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
" 2>/dev/null && mv "$TMP" "$SESSION_FILE" || rm -f "$TMP"
    echo "[$(date -u '+%H:%M:%S')] Cleared yesterday's completedToday"
  fi
fi

# --- Auto-restart with exponential backoff ---
MAX_RETRIES=10
BACKOFF_STEPS=(5 10 30 60 60 60 60 60 60 60)
STABLE_THRESHOLD=300  # 5 minutes = considered stable
RETRY=0

while [[ $RETRY -lt $MAX_RETRIES ]]; do
  START_TIME=$(date +%s)

  # Start Claude
  env TELEGRAM_STATE_DIR="$STATE_DIR" \
    TELEGRAM_RELAY_DIR="$RELAY_DIR" \
    claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official &
  CLAUDE_PID=$!

  # Self-trigger via relay file
  BOOT_WAIT="${BOOT_WAIT:-8}"
  (
    WAITED=0
    while [[ $WAITED -lt $BOOT_WAIT ]]; do
      if [[ -d "$RELAY_DIR" ]] && kill -0 $CLAUDE_PID 2>/dev/null; then
        if pgrep -f "telegram.*start" -P $CLAUDE_PID >/dev/null 2>&1 || [[ $WAITED -ge 6 ]]; then
          break
        fi
      fi
      sleep 1
      WAITED=$((WAITED + 1))
    done
    if ! kill -0 $CLAUDE_PID 2>/dev/null; then
      echo "WARN: Claude process exited before boot trigger" >&2
      exit 1
    fi
    RELAY_FILE="$RELAY_DIR/boot-${BOT_NAME}-$$.json"
    cat > "${RELAY_FILE}.tmp" <<RELAY
{"from_bot":"system","chat_id":"self","text":"@${BOT_USERNAME} 啟動自我檢視","message_id":0,"ts":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}
RELAY
    mv "${RELAY_FILE}.tmp" "$RELAY_FILE"
    sleep 30
    rm -f "$RELAY_FILE" "${RELAY_FILE}.read-by-${BOT_USERNAME}"
  ) &
  TRIGGER_PID=$!

  # Wait for Claude to exit
  wait $CLAUDE_PID
  EXIT_CODE=$?
  kill $TRIGGER_PID 2>/dev/null; wait $TRIGGER_PID 2>/dev/null

  END_TIME=$(date +%s)
  UPTIME=$((END_TIME - START_TIME))

  if [[ $UPTIME -ge $STABLE_THRESHOLD ]]; then
    RETRY=0
    echo "[$(date -u '+%H:%M:%S')] Claude exited (code $EXIT_CODE) after ${UPTIME}s (stable). Restarting immediately..."
    continue
  fi

  RETRY=$((RETRY + 1))
  DELAY=${BACKOFF_STEPS[$((RETRY - 1))]}
  echo "[$(date -u '+%H:%M:%S')] Claude exited (code $EXIT_CODE) after ${UPTIME}s. Retry $RETRY/$MAX_RETRIES in ${DELAY}s..."
  sleep "$DELAY"
done

echo "[$(date -u '+%H:%M:%S')] Max retries ($MAX_RETRIES) reached. $BOT_NAME stopped."

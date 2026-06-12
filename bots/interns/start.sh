#!/usr/bin/env bash

# Load shared environment
source "/home/oldrabbit/.claude-bots/shared/bin/secrets-loader.sh" "" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load bot token from .env.backup if secrets-loader skipped it (BOT_NAME="")
_INTERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -f "${_INTERNS_DIR}/.env.backup" ]]; then
  set -a; source "${_INTERNS_DIR}/.env.backup"; set +a
fi
unset _INTERNS_DIR
# Start: interns (@WuTung_bot / 梧桐)

cd "$(dirname "$0")"

# Auto-patch plugin on startup
"$HOME/.claude-bots/patch-server.sh" 2>/dev/null || true

BOT_NAME="interns"
BOT_USERNAME="WuTung_bot"
RELAY_DIR="$HOME/.claude-bots/relay"
STATE_DIR="$HOME/.claude-bots/bots/$BOT_NAME"
SESSION_FILE="$STATE_DIR/session.json"

# --- Session cleanup: clear completedToday if new day ---
if [[ -f "$SESSION_FILE" ]]; then
  LAST_DATE=$(python3 -c "
import json
with open('$SESSION_FILE') as f:
    s = json.load(f)
print(s.get('lastActiveAt','')[:10])
" 2>/dev/null)
  TODAY=$(TZ=Asia/Taipei date '+%Y-%m-%d')
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
    echo "[$(TZ=Asia/Taipei date '+%H:%M:%S')] Cleared yesterday's completedToday"
  fi
fi

# --- SIGTERM/SIGHUP/SIGINT trap ---
source "$HOME/.claude-bots/shared/lib/save_session_on_kill.sh"

MAX_RETRIES=10
BACKOFF_STEPS=(5 10 30 60 60 60 60 60 60 60)
STABLE_THRESHOLD=300
RETRY=0

while [[ $RETRY -lt $MAX_RETRIES ]]; do
  START_TIME=$(date +%s)

  # Start Claude
  env TELEGRAM_STATE_DIR="$STATE_DIR" \
    TELEGRAM_RELAY_DIR="$RELAY_DIR" \
    claude --model "$(/home/oldrabbit/.claude-bots/shared/bin/model-resolve.sh "$BOT_NAME")" --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official &
  CLAUDE_PID=$!
  trap 'save_session_on_kill "$SESSION_FILE" "$CLAUDE_PID"' SIGTERM SIGHUP SIGINT

  # Boot trigger
  BOOT_WAIT="${BOOT_WAIT:-8}"
  (
    WAITED=0
    while [[ $WAITED -lt $BOOT_WAIT ]]; do
      kill -0 $CLAUDE_PID 2>/dev/null || exit
      sleep 1; WAITED=$((WAITED + 1))
    done
    RELAY_FILE="$RELAY_DIR/boot-${BOT_NAME}-$$.json"
    BOOT_TEXT="@${BOT_USERNAME} 啟動自我檢視"
    BOOT_TEXT_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' <<<"$BOOT_TEXT")
    cat > "${RELAY_FILE}.tmp" <<EOF
{"from_bot":"system","chat_id":"self","text":${BOOT_TEXT_JSON},"message_id":0,"ts":"$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S.000+08:00')"}
EOF
    mv "${RELAY_FILE}.tmp" "$RELAY_FILE"
    sleep 30
    rm -f "$RELAY_FILE" "${RELAY_FILE}.read-by-${BOT_USERNAME}"
  ) &
  TRIGGER_PID=$!

  wait $CLAUDE_PID
  EXIT_CODE=$?
  trap - SIGTERM SIGHUP SIGINT
  kill $TRIGGER_PID 2>/dev/null; wait $TRIGGER_PID 2>/dev/null

  END_TIME=$(date +%s)
  UPTIME=$((END_TIME - START_TIME))

  if [[ $UPTIME -ge $STABLE_THRESHOLD ]]; then
    RETRY=0
    echo "[$(TZ=Asia/Taipei date '+%H:%M:%S')] Stable restart"
    continue
  fi

  RETRY=$((RETRY + 1))
  DELAY=${BACKOFF_STEPS[$((RETRY - 1))]}
  echo "[$(TZ=Asia/Taipei date '+%H:%M:%S')] Exited (code $EXIT_CODE) after ${UPTIME}s. Retry $RETRY/$MAX_RETRIES in ${DELAY}s..."
  sleep "$DELAY"
done

echo "[$(TZ=Asia/Taipei date '+%H:%M:%S')] Max retries reached. interns stopped."

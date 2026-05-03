#!/usr/bin/env bash

# Load shared environment
source "/home/oldrabbit/.claude-bots/shared/bin/secrets-loader.sh" "panda" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Start: ron-assistant (@ron_assistant_bot)
# Features: auto-restart with backoff, boot trigger, session cleanup

cd "$(dirname "$0")"

# Auto-patch plugin on startup
"$HOME/.claude-bots/patch-server.sh" 2>/dev/null || true

# ── L2 on-demand block loading ─────────────────────────────────────────────
_L2_BLOCKS_DIR="$HOME/.claude-bots/bots/ron-assistant/blocks"
_L2_LIB="$HOME/.claude-bots/shared/lib"
_L2_HINT="${L2_HINT:-${1:-}}"

_L2_MATCHED=$(python3 - <<L2PYEOF 2>/dev/null
import sys
sys.path.insert(0, '$_L2_LIB')
from l2_loader import L2Loader, log_session
loader = L2Loader('$_L2_BLOCKS_DIR')
hint = '$_L2_HINT'
matched = loader.match(hint)
log_session(hint, matched)
for p in matched:
    print(p)
L2PYEOF
) || true

if [[ -n "$_L2_MATCHED" ]]; then
    echo "=== L2 on-demand blocks (hint: ${_L2_HINT:-<empty>}) ==="
    while IFS= read -r _l2_block; do
        [[ -f "$_l2_block" ]] || continue
        echo "--- $(basename "$_l2_block") ---"
        cat "$_l2_block"
        echo
    done <<< "$_L2_MATCHED"
    echo "=== end L2 blocks ==="
else
    echo "[$(date -u '+%H:%M:%S')] L2: no blocks matched for hint='${_L2_HINT:-<empty>}'"
fi

unset _L2_BLOCKS_DIR _L2_LIB _L2_HINT _L2_MATCHED _l2_block
# ───────────────────────────────────────────────────────────────────────────

BOT_NAME="ron-assistant"
BOT_USERNAME="Ron0001_bot"
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

# --- SIGTERM/SIGHUP/SIGINT trap (task a634) ---
source "$HOME/.claude-bots/shared/lib/save_session_on_kill.sh"
# --- Auto-restart with exponential backoff ---
MAX_RETRIES=10
BACKOFF_STEPS=(5 10 30 60 60 60 60 60 60 60)
STABLE_THRESHOLD=300  # 5 minutes = considered stable
RETRY=0

while [[ $RETRY -lt $MAX_RETRIES ]]; do
  START_TIME=$(date +%s)

  # === team-l0 enforce (task 88fe) ===
  TEAM_L0="$HOME/.claude-bots/shared/wakeup/team-l0.md"
  MEMORY_FILE="$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-${BOT_NAME}/memory/MEMORY.md"

  if [ ! -f "$TEAM_L0" ]; then
    echo "ERROR [88fe]: team-l0.md not found at $TEAM_L0 — aborting startup" >&2
    exit 1
  fi
  if [ ! -f "$MEMORY_FILE" ]; then
    echo "ERROR [88fe]: MEMORY.md not found at $MEMORY_FILE — aborting startup" >&2
    exit 1
  fi


  # Start Claude
  env TELEGRAM_STATE_DIR="$STATE_DIR" \
    TELEGRAM_RELAY_DIR="$RELAY_DIR" \
    claude --model sonnet --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official &
  CLAUDE_PID=$!
  trap 'save_session_on_kill "$SESSION_FILE" "$CLAUDE_PID"' SIGTERM SIGHUP SIGINT

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
    # Boot prompt = wake-up trigger + (optional) cron-init block from shared/lib/bot-crons.yml
    _BOOT_TEXT="@${BOT_USERNAME} 啟動自我檢視"
    _CRON_BLOCK="$("$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh" "$BOT_NAME" 2>/dev/null || true)"
    if [[ -n "$_CRON_BLOCK" ]]; then
      _BOOT_TEXT="${_BOOT_TEXT}${_CRON_BLOCK}"
    fi
    # JSON-escape the full boot text (handles newlines, quotes, backslashes)
    _BOOT_TEXT_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' <<<"$_BOOT_TEXT")
    cat > "${RELAY_FILE}.tmp" <<RELAY
{"from_bot":"system","chat_id":"self","text":${_BOOT_TEXT_JSON},"message_id":0,"ts":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}
RELAY
    unset _BOOT_TEXT _CRON_BLOCK _BOOT_TEXT_JSON
    mv "${RELAY_FILE}.tmp" "$RELAY_FILE"
    sleep 30
    rm -f "$RELAY_FILE" "${RELAY_FILE}.read-by-${BOT_USERNAME}"
  ) &
  TRIGGER_PID=$!

  # Wait for Claude to exit
  wait $CLAUDE_PID
  EXIT_CODE=$?
  trap - SIGTERM SIGHUP SIGINT
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

#!/usr/bin/env bash
# Bot health check — checks all bots, optionally restarts dead ones
# Usage:
#   bot-health.sh              # Check status only
#   bot-health.sh --restart    # Check + restart dead bots

set -euo pipefail

BOTS=("assistant:BOT_LEAD_USERNAME" "builder:BOT_DEV_USERNAME" "reviewer:BOT_QA_USERNAME")
BOTS_DIR="$HOME/.claude-bots/bots"
STATE_DIR="$HOME/.claude-bots/state"
RESTART=false

for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=true ;;
  esac
done

DEAD=()
ALIVE=()

for entry in "${BOTS[@]}"; do
  BOT_NAME="${entry%%:*}"
  SCREEN_NAME=$(echo "$BOT_NAME" | tr '[:upper:]' '[:lower:]')
  START_SCRIPT="$BOTS_DIR/$BOT_NAME/start.sh"

  # Check if there's a running claude process spawned from this bot's start.sh
  BOT_ALIVE=false
  if pgrep -f "bash.*$START_SCRIPT" >/dev/null 2>&1; then
    # start.sh is running — check if claude is also running as a sibling
    PARENT_PIDS=$(pgrep -f "bash.*$START_SCRIPT" 2>/dev/null)
    for ppid in $PARENT_PIDS; do
      if pgrep -P "$ppid" -f "claude" >/dev/null 2>&1; then
        BOT_ALIVE=true
        break
      fi
    done
  fi

  if $BOT_ALIVE; then
    ALIVE+=("$BOT_NAME")
  else
    DEAD+=("$BOT_NAME")
    if $RESTART; then
      # Kill any leftover tmux session
      tmux kill-session -t "$SCREEN_NAME" 2>/dev/null || true
      sleep 1
      echo "[restart] Starting $BOT_NAME..."
      tmux new-session -d -s "$SCREEN_NAME" bash "$START_SCRIPT"
      ALIVE+=("$BOT_NAME(restarted)")
    fi
  fi
done

NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
echo "=== Bot Health Check — $NOW ==="
echo "Alive: ${ALIVE[*]:-none}"
echo "Dead:  ${DEAD[*]:-none}"

for entry in "${BOTS[@]}"; do
  BOT_NAME="${entry%%:*}"
  SESSION="$STATE_DIR/$BOT_NAME/session.json"
  if [[ -f "$SESSION" ]]; then
    LAST=$(python3 -c "import json; print(json.load(open('$SESSION')).get('lastActiveAt','?'))" 2>/dev/null)
    WORK=$(python3 -c "import json; print(json.load(open('$SESSION')).get('currentWork','?'))" 2>/dev/null)
    echo "  $BOT_NAME: last=$LAST work=\"$WORK\""
  fi
done

[[ ${#DEAD[@]} -eq 0 ]] && echo "All bots healthy."
exit 0

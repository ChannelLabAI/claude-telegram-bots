#!/usr/bin/env bash

# Load shared environment
source "/home/oldrabbit/.claude-bots/shared/bin/secrets-loader.sh"
# Ops bot — 按需模式（非常駐）
# 用法：bash start.sh "做某件事"
# Anya 用這個按需調用 Ops 執行系統管理任務

cd "$(dirname "$0")"

if [[ -z "$1" ]]; then
    echo "Usage: bash start.sh \"<prompt>\""
    exit 1
fi

# === team-l0 enforce (task 88fe) ===
TEAM_L0="$HOME/.claude-bots/shared/wakeup/team-l0.md"
BOT_NAME=$(basename $(dirname $0))
MEMORY_FILE="$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-${BOT_NAME}/memory/MEMORY.md"

if [ ! -f "$TEAM_L0" ]; then
  echo "ERROR [88fe]: team-l0.md not found at $TEAM_L0 — aborting startup" >&2
  exit 1
fi
if [ ! -f "$MEMORY_FILE" ]; then
  echo "ERROR [88fe]: MEMORY.md not found at $MEMORY_FILE — aborting startup" >&2
  exit 1
fi


# --- SIGTERM/SIGHUP/SIGINT trap (task a634) ---
STATE_DIR="$HOME/.claude-bots/bots/$BOT_NAME"
SESSION_FILE="$STATE_DIR/session.json"
source "$HOME/.claude-bots/shared/lib/save_session_on_kill.sh"
trap 'save_session_on_kill "$SESSION_FILE" ""' SIGTERM SIGHUP SIGINT

exec claude --dangerously-skip-permissions -p "$1"

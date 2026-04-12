#!/usr/bin/env bash
# anya-on-stop-save-session.sh — Stop hook: reverse-control session save
#
# Triggered on Claude Code "Stop" event for Anya's session.
# Blocks Claude from stopping and instructs it to flush session.json
# with current in_flight and completedToday before exiting.
#
# Dead-loop prevention: stop_hook_active=true on second stop → guard exits cleanly.
#
# Install in ~/.claude-bots/bots/anya/.claude/settings.json:
#
#   "Stop": [{
#     "matcher": "",
#     "hooks": [{
#       "type": "command",
#       "command": "bash ~/.claude-bots/shared/hooks/anya-on-stop-save-session.sh",
#       "timeout": 10
#     }]
#   }]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stop_hook_lib.sh
source "$SCRIPT_DIR/lib/stop_hook_lib.sh"

# MUST be first: dead-loop guard. Reads stdin into $STOP_HOOK_LIB_INPUT.
guard_stop_hook_active

# Only trigger for Anya sessions
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ "$BOT_NAME" != "anya" ]]; then
    echo "{}"
    exit 0
fi

SESSION_FILE="$HOME/.claude-bots/state/anya/session.json"
if [[ ! -f "$SESSION_FILE" ]]; then
    echo "{}"
    exit 0
fi

# Set env guard so nested hook calls (if any) pass through immediately
export STOP_HOOK_ACTIVE=1

emit_block_reason "Before stopping, update $SESSION_FILE: set lastActiveAt to current UTC timestamp, ensure in_flight array reflects only currently running sub-agents (remove any stale entries), and verify completedToday list is accurate. Write the updated JSON atomically (write to .tmp then mv). Do not call any Telegram tools."

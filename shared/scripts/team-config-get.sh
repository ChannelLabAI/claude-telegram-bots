#!/usr/bin/env bash
# team-config-get.sh — Read a value from team-config.json
#
# Usage:
#   team-config-get.sh groups.main_team.chat_id
#   team-config-get.sh dms.lt
#   team-config-get.sh shared_pools.builder[0].bot_username
#
# Returns the value on stdout. Exits 1 if key not found.
#
# Requires: jq
#
# Examples in bot start.sh:
#   MAIN_TEAM=$(~/.claude-bots/shared/scripts/team-config-get.sh groups.main_team.chat_id)
#   LT_DM=$(~/.claude-bots/shared/scripts/team-config-get.sh dms.lt)

CONFIG="${CLAUDE_BOTS_DIR:-$HOME/.claude-bots}/shared/team-config.json"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: team-config.json not found at $CONFIG" >&2
    exit 1
fi

if [[ -z "$1" ]]; then
    echo "Usage: $0 <jq-key>" >&2
    echo "Example: $0 groups.main_team.chat_id" >&2
    exit 1
fi

KEY="$1"

# Convert dot-notation to jq path (e.g., groups.main_team.chat_id → .groups.main_team.chat_id)
JQ_PATH=".${KEY}"

VALUE=$(jq -r "$JQ_PATH" "$CONFIG" 2>/dev/null)

if [[ "$VALUE" == "null" || -z "$VALUE" ]]; then
    echo "ERROR: key '$KEY' not found in team-config.json" >&2
    exit 1
fi

echo "$VALUE"

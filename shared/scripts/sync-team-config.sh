#!/usr/bin/env bash
# sync-team-config.sh — Sync team-config.json values to all bot access.json files
#
# What it syncs:
#   - main_team chat_id → all bots' access.json groups section
#   - coordinator chat_id → assistant bots' access.json groups section
#   - lt_command chat_id → anya's access.json groups section
#
# What it does NOT sync:
#   - dmPolicy, allowFrom (user_ids) — these are bot-specific, don't touch
#   - Group requireMention settings — these are bot-specific
#   - Groups that aren't in team-config.json — left as-is
#
# Usage:
#   bash sync-team-config.sh [--dry-run]
#
# Requires: jq

BOTS_DIR="${CLAUDE_BOTS_DIR:-$HOME/.claude-bots}"
CONFIG="$BOTS_DIR/shared/team-config.json"
DRY_RUN=0

if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=1
    echo "[dry-run] No files will be written."
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: $CONFIG not found" >&2
    exit 1
fi

MAIN_TEAM=$(jq -r '.groups.main_team.chat_id' "$CONFIG")
COORDINATOR=$(jq -r '.groups.coordinator.chat_id' "$CONFIG")
LT_COMMAND=$(jq -r '.groups.lt_command.chat_id' "$CONFIG")

echo "Values from team-config.json:"
echo "  main_team:   $MAIN_TEAM"
echo "  coordinator: $COORDINATOR"
echo "  lt_command:  $LT_COMMAND"
echo ""

update_access_json() {
    local BOT_STATE_DIR="$1"
    local ACCESS_FILE="$BOTS_DIR/state/$BOT_STATE_DIR/access.json"

    if [[ ! -f "$ACCESS_FILE" ]]; then
        echo "  SKIP $BOT_STATE_DIR: access.json not found"
        return
    fi

    local CHANGED=0
    local CURRENT=$(cat "$ACCESS_FILE")
    local UPDATED="$CURRENT"

    # Update main_team chat_id if the old key exists in the file
    # (we check for both the new and common old IDs)
    for OLD_ID in "-5267778636" "-1003634255226" "-1005267778636"; do
        if echo "$CURRENT" | jq -e ".groups[\"$OLD_ID\"]" > /dev/null 2>&1; then
            if [[ "$OLD_ID" != "$MAIN_TEAM" ]]; then
                echo "  $BOT_STATE_DIR: rename group $OLD_ID → $MAIN_TEAM (main_team)"
                UPDATED=$(echo "$UPDATED" | jq --arg old "$OLD_ID" --arg new "$MAIN_TEAM" \
                    '.groups[$new] = .groups[$old] | del(.groups[$old])')
                CHANGED=1
            fi
        fi
    done

    if [[ $CHANGED -eq 1 ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            echo "$UPDATED" | jq '.' > "${ACCESS_FILE}.tmp" && mv "${ACCESS_FILE}.tmp" "$ACCESS_FILE"
            echo "  $BOT_STATE_DIR: ✅ updated"
        else
            echo "  $BOT_STATE_DIR: [dry-run] would update"
        fi
    else
        echo "  $BOT_STATE_DIR: already up to date"
    fi
}

echo "Checking bots..."
for STATE_DIR in "$BOTS_DIR/state"/*/; do
    BOT=$(basename "$STATE_DIR")
    update_access_json "$BOT"
done

echo ""
echo "Done. Run without --dry-run to apply changes."

#!/bin/bash
# Audit logging hook — appends tool use to bot's audit.log
# Rotates at 10MB, keeps max 5 rotated files

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
CHAT_ID=$(echo "$INPUT" | jq -r '.tool_input.chat_id // empty')
TEXT=$(echo "$INPUT" | jq -r '.tool_input.text // empty' | head -c 200)

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
if [ -z "$BOT_NAME" ]; then
  BOT_NAME="unknown"
fi

STATE_DIR="$HOME/.claude-bots/bots/$BOT_NAME"
AUDIT_LOG="$STATE_DIR/audit.log"

LOG_ENTRY=$(jq -n -c \
  --arg ts "$TIMESTAMP" \
  --arg bot "$BOT_NAME" \
  --arg tool "$TOOL_NAME" \
  --arg cmd "$COMMAND" \
  --arg fp "$FILE_PATH" \
  --arg pat "$PATTERN" \
  --arg cid "$CHAT_ID" \
  --arg txt "$TEXT" \
  '{ts: $ts, bot: $bot, tool: $tool} +
   (if $cmd != "" then {command: $cmd} else {} end) +
   (if $fp != "" then {file: $fp} else {} end) +
   (if $pat != "" then {pattern: $pat} else {} end) +
   (if $cid != "" then {chat_id: $cid} else {} end) +
   (if $txt != "" then {text: $txt} else {} end)')

echo "$LOG_ENTRY" >> "$AUDIT_LOG"

# Rotation: >10MB → rotate, keep max 5 old files
MAX_SIZE=$((10 * 1024 * 1024))
MAX_ROTATED=5
CURRENT_SIZE=$(stat -c%s "$AUDIT_LOG" 2>/dev/null || stat -f%z "$AUDIT_LOG" 2>/dev/null || echo 0)
if [ "$CURRENT_SIZE" -gt "$MAX_SIZE" ]; then
    ROTATED="${AUDIT_LOG%.log}.$(date +%Y%m%d_%H%M%S).log"
    mv "$AUDIT_LOG" "$ROTATED"
    # Prune old rotated files beyond limit
    ls -1t "${AUDIT_LOG%.log}".*.log 2>/dev/null | tail -n +$((MAX_ROTATED + 1)) | xargs rm -f 2>/dev/null
fi

exit 0

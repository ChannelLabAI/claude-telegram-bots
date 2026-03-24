#!/bin/bash
# Audit logging hook for Claude Code bots
# Appends every tool use to the bot's audit.log in its state directory.
# Usage: Configure as PreToolUse hook in .claude/settings.json

INPUT=$(cat)

# Extract fields from JSON input
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')

# Extract key parameters based on tool type
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
CHAT_ID=$(echo "$INPUT" | jq -r '.tool_input.chat_id // empty')
TEXT=$(echo "$INPUT" | jq -r '.tool_input.text // empty' | head -c 200)

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Determine bot name from CWD (e.g., /Users/.../bots/anna → anna)
BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
if [ -z "$BOT_NAME" ]; then
  BOT_NAME="unknown"
fi

# Determine audit log location
STATE_DIR="$HOME/.claude-bots/state/$BOT_NAME"
AUDIT_LOG="$STATE_DIR/audit.log"

# Build compact JSON log entry
LOG_ENTRY=$(jq -n -c \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
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

# Allow the action to proceed
exit 0

#!/usr/bin/env bash
# Hook 1: Workspace Protection — PreToolUse on Edit|Write
# Blocks a bot from modifying another bot's files or system settings.
# Requires: TELEGRAM_STATE_DIR env var (set by each bot's start.sh)

BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")

# Not a bot session → allow
if [[ -z "$BOT_NAME" ]]; then
    exit 0
fi

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# No file_path in input → allow (not Edit/Write, or no target)
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Resolve to absolute path (best effort)
ABS_PATH=$(cd / && realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

check_forbidden() {
    local path="$1"
    local prefix="$2"
    [[ "$path" == "$prefix" || "$path" == "${prefix%/}"/* ]]
}

# Always forbidden: Claude system files
ALWAYS_FORBIDDEN=(
    "$HOME/.claude/settings.json"
    "$HOME/.claude/plugins"
)

for fp in "${ALWAYS_FORBIDDEN[@]}"; do
    if check_forbidden "$ABS_PATH" "$fp"; then
        echo "BLOCKED [$BOT_NAME]: Cannot modify system file: $FILE_PATH" >&2
        exit 2
    fi
done

# Forbidden: other bots' directories
BOT_NAME_LOWER=$(echo "$BOT_NAME" | tr '[:upper:]' '[:lower:]')

for bot_dir in "$HOME/.claude-bots/bots"/*/; do
    dir_name=$(basename "$bot_dir")
    dir_name_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')
    # Skip own directory
    [[ "$dir_name_lower" == "$BOT_NAME_LOWER" ]] && continue
    if check_forbidden "$ABS_PATH" "$bot_dir"; then
        echo "BLOCKED [$BOT_NAME]: Cannot modify another bot's files: $FILE_PATH" >&2
        exit 2
    fi
done

exit 0

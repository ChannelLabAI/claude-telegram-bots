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

# Shared files that all bots can write
SHARED_ALLOWLIST=(
    "$HOME/.claude-bots/shared/mistakes.md"
    "$HOME/.claude-bots/shared/server.patched.ts"
)

BOT_NAME_LOWER=$(echo "$BOT_NAME" | tr '[:upper:]' '[:lower:]')

# assistant-only: management-level files
if [[ "$BOT_NAME_LOWER" == "assistant" ]]; then
    ASSISTANT_ALLOWLIST=(
        "$HOME/.claude/settings.json"
        "$HOME/.claude-bots/bots/CLAUDE.md"
        "$HOME/.claude-bots/bots/builder/.claude/settings.json"
        "$HOME/.claude-bots/bots/reviewer/.claude/settings.json"
        "$HOME/.claude-bots/shared/server.patched.ts"
        "$HOME/.claude-bots/shared/hooks/workspace-protect.sh"
    )
    for a in "${ASSISTANT_ALLOWLIST[@]}"; do
        [[ "$ABS_PATH" == "$a" ]] && exit 0
    done
    # assistant can bootstrap new bot directories
    ASSISTANT_PREFIX_ALLOW=(
        "$HOME/.claude-bots/bots/team-member-assistant"
        "$HOME/.claude-bots/bots/team-member-builder"
    )
    for prefix in "${ASSISTANT_PREFIX_ALLOW[@]}"; do
        if check_forbidden "$ABS_PATH" "$prefix"; then
            exit 0
        fi
    done
fi

# Ops admin: can write to all ~/.claude-bots/bots/ (but not ~/.claude/plugins/)
if [[ "$BOT_NAME_LOWER" == "ops" ]]; then
    if check_forbidden "$ABS_PATH" "$HOME/.claude-bots/bots"; then
        exit 0
    fi
    if check_forbidden "$ABS_PATH" "$HOME/.claude-bots/state"; then
        exit 0
    fi
    if check_forbidden "$ABS_PATH" "$HOME/.claude-bots/shared"; then
        exit 0
    fi
fi

for allowed in "${SHARED_ALLOWLIST[@]}"; do
    if [[ "$ABS_PATH" == "$allowed" ]]; then
        exit 0
    fi
done

# Always forbidden: Claude system files + plugins (applies to ALL bots including ops)
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

# === Obsidian Vault protection ===
# Only assistants can write to vault; builder/reviewer/ops cannot write
ASSISTANTS=("assistant" "assistant-2" "assistant-3" "assistant-4" "assistant-5" "assistant-6" "assistant-7")

is_assistant() {
    local bot="$1"
    for a in "${ASSISTANTS[@]}"; do
        [[ "$bot" == "$a" ]] && return 0
    done
    return 1
}

COMPANY_VAULT="$HOME/Documents/Obsidian Vault"
PERSONAL_VAULT_PREFIX="$HOME/Documents/Obsidian Vault - "

# Designer bot restricted allowlist: can only write to Chart/ and Assets/
DESIGNER_ALLOWED_PREFIXES=(
    "$HOME/Documents/Obsidian Vault/Ocean/Chart"
    "$HOME/Documents/Obsidian Vault/Assets"
)

# Reviewer bot restricted allowlist: can only write to Reviews/
REVIEWER_ALLOWED_PREFIXES=(
    "$HOME/Documents/Obsidian Vault/Ocean/Reviews"
)

# Company Vault: only assistants can write; designer has restricted scope
if check_forbidden "$ABS_PATH" "$COMPANY_VAULT" && [[ "$ABS_PATH" != "$PERSONAL_VAULT_PREFIX"* ]]; then
    if [[ "$BOT_NAME_LOWER" == "designer" ]]; then
        # designer can only write to designated scope
        designer_allowed=0
        for prefix in "${DESIGNER_ALLOWED_PREFIXES[@]}"; do
            if check_forbidden "$ABS_PATH" "$prefix"; then
                designer_allowed=1
                break
            fi
        done
        if [[ $designer_allowed -eq 0 ]]; then
            echo "BLOCKED [$BOT_NAME]: Designer can only write to Ocean/Chart/ or Assets/ in vault: $FILE_PATH" >&2
            exit 2
        fi
    elif [[ "$BOT_NAME_LOWER" == "reviewer" ]]; then
        # reviewer can only write to Ocean/Reviews/
        reviewer_allowed=0
        for prefix in "${REVIEWER_ALLOWED_PREFIXES[@]}"; do
            if check_forbidden "$ABS_PATH" "$prefix"; then
                reviewer_allowed=1
                break
            fi
        done
        if [[ $reviewer_allowed -eq 0 ]]; then
            echo "BLOCKED [$BOT_NAME]: Reviewer can only write to Ocean/Reviews/ in vault: $FILE_PATH" >&2
            exit 2
        fi
    elif ! is_assistant "$BOT_NAME_LOWER"; then
        echo "BLOCKED [$BOT_NAME]: Only assistants can write to company Obsidian Vault: $FILE_PATH" >&2
        exit 2
    fi
fi

# Personal Vault: only the owner's assistant can write
# Mapping: vault name → allowed assistant bot(s)
declare -A PERSONAL_VAULT_OWNERS=(
    ["owner"]="assistant"
    ["<OWNER_NAME_1>"]="assistant-2"
    ["<OWNER_NAME_2>"]="assistant-3 assistant-4"
    ["<OWNER_NAME_3>"]="assistant-5"
    ["<OWNER_NAME_4>"]="assistant-6"
)

for vault_name in "${!PERSONAL_VAULT_OWNERS[@]}"; do
    vault_path="${PERSONAL_VAULT_PREFIX}${vault_name}"
    if check_forbidden "$ABS_PATH" "$vault_path"; then
        allowed_owners="${PERSONAL_VAULT_OWNERS[$vault_name]}"
        owner_match=0
        for owner in $allowed_owners; do
            [[ "$BOT_NAME_LOWER" == "$owner" ]] && owner_match=1 && break
        done
        if [[ $owner_match -eq 0 ]]; then
            echo "BLOCKED [$BOT_NAME]: Only $allowed_owners can write to personal vault: $vault_name" >&2
            exit 2
        fi
    fi
done

exit 0

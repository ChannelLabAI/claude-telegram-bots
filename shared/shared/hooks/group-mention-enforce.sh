#!/usr/bin/env bash
# Hook 2: Group @ Enforcement — PreToolUse on telegram reply
# Blocks group messages that mention a bot by name but don't @mention them.
# Broadcast/greeting messages (no bot names) are allowed through.
# Only enforced for the bot team's internal group.

# Internal bot team group — only this group requires @ enforcement
INTERNAL_GROUP="-5267778636"

INPUT=$(cat)
CHAT_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('chat_id',''))" 2>/dev/null)
TEXT=$(echo "$INPUT"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('text',''))" 2>/dev/null)

# Only enforce for internal group
if [[ "$CHAT_ID" == "$INTERNAL_GROUP" ]]; then
    # Derive current bot name from working directory (~/.claude-bots/bots/<name>/)
    SELF_BOT=$(basename "$PWD" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    MISSING=""
    # Check each bot: if name is mentioned but @username is missing, flag it
    # Skip check for the bot's own name (self-reference is fine)
    if [[ "$SELF_BOT" != "anna" ]]; then
        if echo "$TEXT" | grep -iq "anna" && ! echo "$TEXT" | grep -q "@annadesu_bot"; then
            MISSING="$MISSING @annadesu_bot"
        fi
    fi
    if [[ "$SELF_BOT" != "bella" ]]; then
        if echo "$TEXT" | grep -iq "bella" && ! echo "$TEXT" | grep -q "@Bellalovechl_Bot"; then
            MISSING="$MISSING @Bellalovechl_Bot"
        fi
    fi
    if [[ "$SELF_BOT" != "anya" ]]; then
        if echo "$TEXT" | grep -iq "anya" && ! echo "$TEXT" | grep -q "@Anyachl_bot"; then
            MISSING="$MISSING @Anyachl_bot"
        fi
    fi
    if [[ -n "$MISSING" ]]; then
        echo "BLOCKED: Message mentions bot(s) by name but missing @username:$MISSING" >&2
        echo "Add the @BotUsername so the target bot can receive it." >&2
        exit 2
    fi
fi

exit 0

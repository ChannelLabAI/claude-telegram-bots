#!/usr/bin/env bash
# Hook 2: Group @ Enforcement — PreToolUse on telegram reply
# Blocks group messages that don't @ any bot in the INTERNAL group.
# Only enforced for the bot team's internal group where relay requires @mention.

# Internal bot team group — only this group requires @ enforcement
INTERNAL_GROUP="-5267778636"

INPUT=$(cat)
CHAT_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('chat_id',''))" 2>/dev/null)
TEXT=$(echo "$INPUT"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('text',''))" 2>/dev/null)

# Only enforce for internal group
if [[ "$CHAT_ID" == "$INTERNAL_GROUP" ]]; then
    if [[ "$TEXT" != *"@"* ]]; then
        echo "BLOCKED: Internal group message missing @mention — bots won't receive the message without it." >&2
        echo "Add @BotUsername to your message." >&2
        exit 2
    fi
fi

exit 0

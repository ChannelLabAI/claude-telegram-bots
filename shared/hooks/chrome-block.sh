#!/usr/bin/env bash
# Hook: Chrome Block — PreToolUse on Bash
# Blocks any Bash command that attempts to use Google Chrome.
# All AI tools must use Brave browser instead.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)

# Only check Bash commands
if [[ "$TOOL" != "Bash" ]]; then
    exit 0
fi

CMD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

# Block any reference to Google Chrome
if echo "$CMD" | grep -iq "google.chrome\|Google Chrome\|google-chrome\|/Chrome.app"; then
    echo "BLOCKED: AI 禁止使用 Google Chrome。請改用 Brave Browser。" >&2
    echo "Brave path: /Applications/Brave Browser.app/Contents/MacOS/Brave Browser" >&2
    exit 2
fi

exit 0

#!/bin/bash
# §11 L3a — Agent PreToolUse: inject v2 schema + tier instructions
# Fires before Agent tool calls to inject return schema into the agent prompt.
# Modifies the prompt by appending schema instructions.

set -u

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Only act on Agent tool
case "$TOOL_NAME" in
  Agent) ;;
  *) echo "$INPUT"; exit 0 ;;
esac

PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""')

# If prompt is empty, pass through unchanged
if [ -z "$PROMPT" ]; then
  echo "$INPUT"
  exit 0
fi

# Detect bot from CWD
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && BOT_NAME="unknown"

# Determine tier and threshold
# Tier 1 (特助/assistants): 1500 tokens
# Tier 2 (builders/reviewers): 3000 tokens
# Tier 3 (others/default): 5000 tokens
THRESHOLD=5000
case "$BOT_NAME" in
  anya|anna|sancai|ron-assistant)
    THRESHOLD=1500
    ;;
  Bella|ron-builder|ron-reviewer|nicky-builder)
    THRESHOLD=3000
    ;;
esac

APPEND_TEXT="

---
[§11 Return Schema Required]
Your response MUST follow this JSON schema:
{
  \"status\": \"success|partial|failed|blocked\",
  \"summary\": \"≤100字 conclusion\",
  \"confidence\": \"high|medium|low\",
  \"findings\": [{\"severity\":\"high|medium|low\",\"title\":\"...\",\"evidence\":\"file:line or slug\"}],
  \"files_changed\": [{\"path\":\"...\",\"action\":\"created|modified|deleted\"}],
  \"blockers\": [\"≤3 items, only if status=failed|blocked\"],
  \"next_action\": \"≤30字 suggested next step\"
}
Return limit for this session: ${THRESHOLD} tokens
Model: use Haiku unless task requires deep reasoning (mark with model: sonnet in prompt).
---"

# Output modified input with updated prompt; if jq fails, output original INPUT unchanged
RESULT=$(echo "$INPUT" | jq --arg newprompt "${PROMPT}${APPEND_TEXT}" '.tool_input.prompt = $newprompt' 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$RESULT" ]; then
  echo "$INPUT"
  exit 0
fi

echo "$RESULT"
exit 0

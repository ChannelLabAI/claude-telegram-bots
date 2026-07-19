#!/bin/bash
# §11 L3b — Subagent Return Monitor
# PostToolUse hook for Task/Agent tool.
# Does NOT modify tool_response (Claude Code API doesn't allow it).
# Instead:
#   1. Measures token size of tool_response
#   2. Validates Schema v3 shape (best-effort JSON parse)
#   3. Logs violations to ~/.claude-bots/logs/section11/violations.jsonl
#   4. Emits additionalContext warning to main agent if oversize
#
# Phase 1: log-only mode (no enforcement) — violations are logged and warned but never blocked.
#
# Role thresholds (Tier system, 2026-04-17):
#   - Tier 1 (特助/assistants): anya, anna, sancai, ron-assistant → 1500 tokens
#   - Tier 2 (builders/reviewers): Bella, eric, kk, twinkle → 3000 tokens
#   - Tier 3 (others/default): 5000 tokens
#
# Token estimation: char-length / 3.5 (conservative; avoids tiktoken dependency)

set -u

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Only monitor subagent/Task calls
case "$TOOL_NAME" in
  Task|Agent) ;;
  *) exit 0 ;;
esac

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && BOT_NAME="unknown"

# Extract tool response as string
RESP=$(echo "$INPUT" | jq -r '.tool_response // .tool_result // ""' 2>/dev/null)
if [ -z "$RESP" ] || [ "$RESP" = "null" ]; then
  RESP=$(echo "$INPUT" | jq -c '.tool_response // .tool_result // ""' 2>/dev/null)
fi

# Skip background-agent launch confirmations (2026-06-11).
# For run_in_background=true, PostToolUse fires at LAUNCH time with a "launched"
# confirmation message — NOT the real subagent return (which arrives via
# task-notification and never re-triggers this hook). Measuring the launch text
# produced ~81% false missing_schema_v3 violations (317/390). These are not real
# returns, so skip entirely (no observation, no violation).
case "$RESP" in
  *"Async agent launched"*|*"agent is working in the background"*|*"will be notified automatically when it completes"*)
    exit 0 ;;
esac

# Token estimate (chars / 3.5)
CHAR_COUNT=${#RESP}
TOKEN_EST=$(( CHAR_COUNT * 10 / 35 ))

# Determine threshold from Tier system
# Tier 1 (特助/assistants): 1500 tokens
# Tier 2 (builders/reviewers): 3000 tokens
# Tier 3 (others/default): 5000 tokens
THRESHOLD=5000
case "$BOT_NAME" in
  anya|anna|sancai|ron-assistant)
    THRESHOLD=1500
    ;;
  bella|eric|kk|twinkle)
    THRESHOLD=3000
    ;;
esac

# Two-layer unwrap for Schema v3 validation.
# Token size uses original RESP above (conservative); validation uses extracted JSON.
SCHEMA_RESP="$RESP"

# Layer 1: Unwrap content-block array (Claude Code Agent tool_response format)
# [{"type":"text","text":"actual content"}] → concatenated text
if echo "$SCHEMA_RESP" | jq -e 'type == "array" and length > 0 and (.[0].type? == "text")' >/dev/null 2>&1; then
  _extracted=$(echo "$SCHEMA_RESP" | jq -r '[.[].text // ""] | join("\n")' 2>/dev/null)
  [ -n "$_extracted" ] && SCHEMA_RESP="$_extracted"
fi

# Layer 2: Strip markdown code fences and extract first JSON object.
# Handles ```json\n{...}\n``` wrapping and surrounding prose.
UNWRAPPED=$(printf '%s' "$SCHEMA_RESP" | python3 -c "
import sys, re
t = sys.stdin.read()
t = re.sub(r'\x60{3}(?:json)?\n?', '', t)
m = re.search(r'\{.*\}', t, re.DOTALL)
print(m.group(0) if m else t)
" 2>/dev/null)
[ -n "$UNWRAPPED" ] && SCHEMA_RESP="$UNWRAPPED"

# Schema v3 validation (best-effort)
SCHEMA_OK=true
SCHEMA_REASON=""
if echo "$SCHEMA_RESP" | jq -e '.status and .summary and .confidence' >/dev/null 2>&1; then
  SUMMARY_LEN=$(echo "$SCHEMA_RESP" | jq -r '.summary | length' 2>/dev/null || echo 0)
  if [ "$SUMMARY_LEN" -gt 200 ]; then
    SCHEMA_OK=false
    SCHEMA_REASON="summary_too_long:$SUMMARY_LEN"
  fi
else
  SCHEMA_OK=false
  SCHEMA_REASON="missing_schema_v3_fields"
fi

TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LOG_DIR="$HOME/.claude-bots/logs/section11"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/violations.jsonl"

OVERSIZE=false
if [ "$TOKEN_EST" -gt "$THRESHOLD" ]; then OVERSIZE=true; fi

# Always log observations (not just violations) for Tier 1 metrics
OBS_LOG="$LOG_DIR/observations.jsonl"
jq -n -c \
  --arg ts "$TS" --arg bot "$BOT_NAME" --arg sid "$SESSION_ID" \
  --argjson tok "$TOKEN_EST" --argjson thr "$THRESHOLD" \
  --argjson oversize "$OVERSIZE" --argjson schema_ok "$SCHEMA_OK" \
  --arg reason "$SCHEMA_REASON" \
  '{ts:$ts, bot:$bot, session:$sid, tokens:$tok, threshold:$thr,
    oversize:$oversize, schema_ok:$schema_ok, schema_reason:$reason}' \
  >> "$OBS_LOG"

# Hard violation = OVERSIZE only. §11 is size-discipline: a return under the bot's
# threshold doesn't pollute context, so it's compliant regardless of form. Schema v3
# is the *recommended* way to stay small (nudged at dispatch by agent-schema-inject.sh),
# not a gate — flagging small free-text returns as violations injects false warnings
# into the main context, the very thing §11 exists to prevent (2026-06-14: schema-only
# "violations" were 74% of the log, all under-threshold). schema_ok stays in
# observations.jsonl for adoption metrics.
if [ "$OVERSIZE" = "true" ]; then
  jq -n -c \
    --arg ts "$TS" --arg bot "$BOT_NAME" --arg sid "$SESSION_ID" \
    --argjson tok "$TOKEN_EST" --argjson thr "$THRESHOLD" \
    --argjson oversize "$OVERSIZE" --argjson schema_ok "$SCHEMA_OK" \
    --arg reason "$SCHEMA_REASON" \
    '{ts:$ts, bot:$bot, session:$sid, tokens:$tok, threshold:$thr,
      oversize:$oversize, schema_ok:$schema_ok, schema_reason:$reason}' \
    >> "$LOG_FILE"

  WARN="⚠️ §11 L3 警告: subagent 回傳 ${TOKEN_EST} token（門檻 ${THRESHOLD}）"
  [ "$OVERSIZE" = "true" ] && WARN="$WARN；超標=true"
  [ "$SCHEMA_OK" = "false" ] && WARN="$WARN；schema 問題=$SCHEMA_REASON"
  WARN="$WARN。建議：(1) 要求 subagent 重壓縮摘要；(2) 將大內容寫入 _raw_if_needed.path；(3) 下次派發時在 prompt 尾強調 Schema v3 與 ≤100字 summary。"

  # Emit hookSpecificOutput with additionalContext
  jq -n -c --arg msg "$WARN" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$msg}}'
fi

exit 0

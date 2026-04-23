#!/bin/bash
# §12 Post-Compact Inject
# SessionStart hook: injects Must-Keep 6 backup back as additionalContext
# so the main agent recovers state after auto-compact or session restart.
#
# Only runs for 特助 (§12 ✅ 適用).
# After successful inject, the backup file is moved to consumed/ (kept 7 days for audit).

set -u

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && exit 0

BOT_CLAUDE="$HOME/.claude-bots/bots/$BOT_NAME/CLAUDE.md"
[ -f "$BOT_CLAUDE" ] || exit 0
grep -qE '§12\s*✅\s*適用' "$BOT_CLAUDE" 2>/dev/null || exit 0

BACKUP_DIR="$HOME/.claude-bots/state/_compact_backup/$BOT_NAME"
[ -d "$BACKUP_DIR" ] || exit 0

# Pick most recent backup (< 24h old)
LATEST=$(ls -1t "$BACKUP_DIR"/*.json 2>/dev/null | head -1)
[ -z "$LATEST" ] && exit 0

AGE_SEC=$(( $(date +%s) - $(stat -f%m "$LATEST" 2>/dev/null || echo 0) ))
[ "$AGE_SEC" -gt 86400 ] && exit 0

# Build additionalContext message
CTX=$(python3 - "$LATEST" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    b = json.load(f)
mk = b.get("must_keep", {})
lines = ["📦 §12 Compact 後恢復 — Must-Keep 6 條備份："]
if mk.get("3_owner_last_cmd"):
    lines.append(f"\n[3] owner 最後指令：\n{mk['3_owner_last_cmd']}")
if mk.get("2_subagent_index"):
    idx = mk["2_subagent_index"]
    lines.append(f"\n[2] Subagent 產物索引 ({len(idx)} 筆)：")
    for e in idx[-5:]:
        lines.append(f"  - {e}")
if mk.get("4_recent_dialogue"):
    lines.append("\n[4] 近期對話：")
    for p in mk["4_recent_dialogue"][-6:]:
        lines.append(f"  [{p['role']}] {p['text'][:300]}")
if mk.get("5_half_finished"):
    lines.append(f"\n[5] 半成品：\n{mk['5_half_finished'][:800]}")
if mk.get("6_agent_memo"):
    lines.append(f"\n[6] AGENT_MEMO：\n{mk['6_agent_memo']}")
lines.append("\n⚠️ [1] 任務總狀態請自行從 FATQ (~/.claude-bots/tasks/) 確認。")
print("\n".join(lines))
PYEOF
)

[ -z "$CTX" ] && exit 0

# Emit as additionalContext
jq -n -c --arg msg "$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$msg}}'

# Archive backup
CONSUMED_DIR="$BACKUP_DIR/consumed"
mkdir -p "$CONSUMED_DIR"
mv "$LATEST" "$CONSUMED_DIR/" 2>/dev/null

# Prune consumed > 7 days
find "$CONSUMED_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null

# Log
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LOG_DIR="$HOME/.claude-bots/logs/section12"
mkdir -p "$LOG_DIR"
jq -n -c \
  --arg ts "$TS" --arg bot "$BOT_NAME" --arg sid "$SESSION_ID" \
  --arg src "$SOURCE" --arg backup "$LATEST" \
  '{ts:$ts, bot:$bot, session:$sid, source:$src, backup:$backup, event:"inject"}' \
  >> "$LOG_DIR/injects.jsonl"

exit 0

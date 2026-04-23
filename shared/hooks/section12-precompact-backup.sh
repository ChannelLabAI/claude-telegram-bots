#!/bin/bash
# §12 Proactive Compact — Pre-Compact Must-Keep Backup
# Stop hook: runs when main agent ends a turn.
# Detects large transcript (approaching auto-compact), snapshots Must-Keep 6 items.
#
# Claude Code's Stop hook CANNOT modify transcript in place, so we:
#   1. Read transcript_path (JSONL)
#   2. Extract the 6 must-keep anchors (heuristic pass)
#   3. Save to ~/.claude-bots/state/_compact_backup/{bot}/{session}.json
#   4. Next session/compact, section12-inject.sh pulls this back via SessionStart
#
# Only runs for 特助 (assistants), identified by bot L2 CLAUDE.md marker
# "§12 ✅ 適用".

set -u

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')

BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && exit 0

BOT_CLAUDE="$HOME/.claude-bots/bots/$BOT_NAME/CLAUDE.md"
[ -f "$BOT_CLAUDE" ] || exit 0

# Gate: only 特助
grep -qE '§12\s*✅\s*適用' "$BOT_CLAUDE" 2>/dev/null || exit 0

[ -f "$TRANSCRIPT" ] || exit 0

# Size gate: transcript < 500KB → skip (not yet near compact)
SIZE=$(stat -f%z "$TRANSCRIPT" 2>/dev/null || echo 0)
[ "$SIZE" -lt 500000 ] && exit 0

TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
BACKUP_DIR="$HOME/.claude-bots/state/_compact_backup/$BOT_NAME"
mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/${SESSION_ID}.json"

# Extract Must-Keep 6 heuristically:
#   #1 task state: last FATQ-related tool result
#   #2 subagent index: last 5 Task tool responses' _raw_if_needed paths
#   #3 owner last cmd: last user message
#   #4 recent dialogue: last 5 user+assistant pairs
#   #5 in-session half-finished: last assistant message with tool_use
#   #6 agent memo: search transcript for <!-- AGENT_MEMO -->

python3 - "$TRANSCRIPT" "$OUT" "$BOT_NAME" "$SESSION_ID" "$TS" <<'PYEOF' 2>/dev/null || exit 0
import json, sys, re
from pathlib import Path

transcript_path, out_path, bot, sid, ts = sys.argv[1:6]

msgs = []
with open(transcript_path) as f:
    for line in f:
        try:
            msgs.append(json.loads(line))
        except Exception:
            pass

def msg_text(m):
    c = m.get("message", {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for b in c:
            if isinstance(b, dict):
                if b.get("type") == "text":
                    parts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    parts.append(f"[tool_use:{b.get('name','')}]")
                elif b.get("type") == "tool_result":
                    tc = b.get("content", "")
                    if isinstance(tc, list):
                        tc = " ".join(x.get("text","") for x in tc if isinstance(x,dict))
                    parts.append(f"[tool_result:{str(tc)[:500]}]")
        return "\n".join(parts)
    return ""

def role(m):
    return m.get("message", {}).get("role") or m.get("type", "")

# #3 owner last cmd
owner_last = ""
for m in reversed(msgs):
    if role(m) == "user":
        t = msg_text(m)
        if t and not t.startswith("["):
            owner_last = t[:3000]
            break

# #4 recent dialogue: last 5 pairs
pairs = []
buf = []
for m in reversed(msgs):
    r = role(m)
    if r in ("user", "assistant"):
        buf.append({"role": r, "text": msg_text(m)[:800]})
        if len(buf) >= 10:
            break
pairs = list(reversed(buf))

# #2 subagent index: scan tool_results for _raw_if_needed paths
subagent_index = []
for m in msgs:
    c = m.get("message", {}).get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if isinstance(b, dict) and b.get("type") == "tool_result":
            tc = b.get("content", "")
            if isinstance(tc, list):
                tc = " ".join(x.get("text","") for x in tc if isinstance(x,dict))
            tc = str(tc)
            mm = re.search(r'"_raw_if_needed"\s*:\s*\{[^}]*"path"\s*:\s*"([^"]+)"', tc)
            slug = re.search(r'"seabed_slug"\s*:\s*"([^"]+)"', tc)
            if mm or slug:
                entry = {}
                if mm: entry["raw_path"] = mm.group(1)
                if slug: entry["seabed_slug"] = slug.group(1)
                subagent_index.append(entry)
subagent_index = subagent_index[-10:]

# #5 in-session half-finished: last assistant with tool_use
half = ""
for m in reversed(msgs):
    if role(m) == "assistant":
        c = m.get("message", {}).get("content")
        if isinstance(c, list) and any(isinstance(b,dict) and b.get("type")=="tool_use" for b in c):
            half = msg_text(m)[:1500]
            break

# #6 agent memo
memo = ""
for m in reversed(msgs):
    t = msg_text(m)
    mm = re.search(r'<!--\s*AGENT_MEMO\s*-->(.*?)<!--\s*/AGENT_MEMO\s*-->', t, re.S)
    if mm:
        memo = mm.group(1).strip()[:2000]
        break

out = {
    "ts": ts,
    "bot": bot,
    "session": sid,
    "must_keep": {
        "1_task_state": "[extracted by main agent on restore]",
        "2_subagent_index": subagent_index,
        "3_owner_last_cmd": owner_last,
        "4_recent_dialogue": pairs,
        "5_half_finished": half,
        "6_agent_memo": memo,
    },
    "meta": {
        "msg_count": len(msgs),
        "transcript_bytes": Path(transcript_path).stat().st_size,
    }
}

with open(out_path, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
PYEOF

# Log
LOG_DIR="$HOME/.claude-bots/logs/section12"
mkdir -p "$LOG_DIR"
jq -n -c \
  --arg ts "$TS" --arg bot "$BOT_NAME" --arg sid "$SESSION_ID" \
  --arg out "$OUT" --argjson size "$SIZE" \
  '{ts:$ts, bot:$bot, session:$sid, backup:$out, transcript_bytes:$size, event:"precompact_snapshot"}' \
  >> "$LOG_DIR/backups.jsonl"

exit 0

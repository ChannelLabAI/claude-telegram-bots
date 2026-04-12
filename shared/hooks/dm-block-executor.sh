#!/usr/bin/env bash
# Hook: DM Block — PreToolUse on mcp__plugin_telegram_telegram__reply
#                                 mcp__plugin_telegram_telegram__edit_message
# Prevents executor bots from DMing human users directly.
# Three-layer architecture rule: executors ack via group @mention to their assistant,
# not direct DM to human.
#
# Pass-through: negative chat_id (group chats) → always allowed
# Block: positive chat_id matching known human user_ids → exit 2
#
# FAIL-CLOSED policy: any ambiguous case (malformed input, missing chat_id,
# missing team-config) is treated as a potential human DM → blocked.
#
# NOTE: PreToolUse hooks DO NOT fire for tool calls made inside sub-agents.
# Sub-agents run in isolated sessions without the parent's hook configuration.
# This is a known bypass gap: a sub-agent spawned by an executor bot can call
# mcp__plugin_telegram_telegram__reply / edit_message directly to a human DM
# without triggering this hook. Mitigation: trust model relies on sub-agents
# inheriting the executor's persona rules; architectural fix requires
# agent-level hook propagation (not yet supported by Claude Code as of 2026-04).

TEAM_CONFIG="$HOME/.claude-bots/shared/team-config.json"
LOG_FILE="$HOME/.claude-bots/logs/three-layer-violations.log"
LOG_DIR="$HOME/.claude-bots/logs"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Emit a block JSON response using python3 (safe, no injection risk)
emit_block() {
    local reason="$1"
    python3 -c "
import json, sys
print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}))" "$reason"
    exit 2
}

# Read stdin
INPUT=$(cat)
if [[ -z "$INPUT" ]]; then
    echo "BLOCKED [dm-block]: empty stdin, blocking as fail-safe" >&2
    emit_block "dm-block: empty input, failing closed"
fi

# Parse JSON — malformed input → fail-CLOSED
PARSE_RESULT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('tool_input', {}).get('chat_id', '__MISSING__')
    print(str(v))
except json.JSONDecodeError as e:
    print('__MALFORMED__')
except Exception as e:
    print('__ERROR__')
" 2>/dev/null)

# Malformed JSON → block
if [[ "$PARSE_RESULT" == "__MALFORMED__" ]]; then
    echo "BLOCKED [dm-block]: malformed JSON input, blocking as fail-safe" >&2
    emit_block "dm-block: malformed JSON input, failing closed for safety"
fi

# Unexpected parse error → block
if [[ "$PARSE_RESULT" == "__ERROR__" ]]; then
    echo "BLOCKED [dm-block]: unexpected parse error, blocking as fail-safe" >&2
    emit_block "dm-block: unexpected parse error, failing closed for safety"
fi

# Missing chat_id field → block
if [[ "$PARSE_RESULT" == "__MISSING__" || -z "$PARSE_RESULT" ]]; then
    echo "BLOCKED [dm-block]: missing chat_id field, blocking as fail-safe" >&2
    emit_block "dm-block: chat_id field missing, failing closed for safety"
fi

CHAT_ID="$PARSE_RESULT"

# Negative chat_id = group chat → always allow
if [[ "$CHAT_ID" =~ ^- ]]; then
    exit 0
fi

# Build list of known human user_ids from team-config.json
# Fallback hardcoded list — always active as baseline
HUMAN_IDS_FALLBACK=(
    "1050312492"   # 老兔
    "2114307569"   # 菜姐
    "5288537361"   # Ron
    "7132373174"   # Nicky
    "8201149279"   # 桃桃
    "5728956655"   # 川哥
)

HUMAN_IDS=()

# Try loading from team-config.json
# If file is missing → fail-CLOSED (use fallback only, still block if matched)
if [[ -f "$TEAM_CONFIG" ]]; then
    LOADED=$(python3 -c "
import sys, json
try:
    with open('$TEAM_CONFIG') as f:
        d = json.load(f)
    ids = []
    owners = d.get('owners', {})
    for k, v in owners.items():
        uid = str(v.get('user_id', ''))
        if uid:
            ids.append(uid)
    dms = d.get('dms', {})
    for k, v in dms.items():
        if v and str(v) not in ids:
            ids.append(str(v))
    print(' '.join(ids))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
    if [[ -n "$LOADED" ]]; then
        read -ra HUMAN_IDS <<< "$LOADED"
    else
        # team-config.json present but failed to parse → log warning, continue with fallback
        echo "WARNING [dm-block]: team-config.json parse failed, using fallback list only" >&2
    fi
else
    # team-config.json not found → log warning, continue with fallback (fail-CLOSED intent:
    # fallback list is always active, so known humans are still blocked)
    echo "WARNING [dm-block]: team-config.json not found at $TEAM_CONFIG, using hardcoded fallback list" >&2
fi

# Merge with fallback (deduplicated)
for fid in "${HUMAN_IDS_FALLBACK[@]}"; do
    found=0
    for hid in "${HUMAN_IDS[@]}"; do
        [[ "$hid" == "$fid" ]] && found=1 && break
    done
    [[ $found -eq 0 ]] && HUMAN_IDS+=("$fid")
done

# Derive current bot name from working directory or TELEGRAM_STATE_DIR
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-$PWD}" 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Check if chat_id matches a known human
for HID in "${HUMAN_IDS[@]}"; do
    if [[ "$CHAT_ID" == "$HID" ]]; then
        TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        # Write violation log using python3 (safe JSON output)
        LOG_ENTRY=$(python3 -c "
import json, sys
entry = {'ts': sys.argv[1], 'bot': sys.argv[2], 'chat_id': sys.argv[3], 'blocked': True}
print(json.dumps(entry))" "$TS" "$BOT_NAME" "$CHAT_ID")
        echo "$LOG_ENTRY" >> "$LOG_FILE"
        # Block with reason
        echo "BLOCKED [$BOT_NAME]: 執行層 bot 不直接 reply 人類，請改 ack 對應特助（群裡 @mention）" >&2
        echo "chat_id=$CHAT_ID 是人類用戶，三層架構規則禁止執行層 bot 直接私訊。" >&2
        emit_block "[$BOT_NAME] chat_id=$CHAT_ID 是人類用戶，三層架構規則禁止執行層 bot 直接私訊。請改為群裡 @mention 對應特助。"
    fi
done

# Not a human DM → allow
exit 0

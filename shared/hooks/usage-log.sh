#!/usr/bin/env bash
# usage-log.sh — Stop hook: aggregate session token usage and append to logs/usage.jsonl
#
# Input (stdin): {"session_id": "...", "transcript_path": "...", "cwd": "..."}
# Output: ~/.claude-bots/logs/usage.jsonl (one JSON line per session)
#
# Log format:
#   {"ts":"...","date":"...","bot":"anna","model":"sonnet","session_id":"...",
#    "input_tokens":N,"output_tokens":N,"cache_read_tokens":N,"approx_cost_usd":N}

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Need at least session_id
[ -z "$SESSION_ID" ] && exit 0

# Bot name from CWD (e.g. /home/.../bots/anna → anna)
BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && BOT_NAME="unknown"

# Resolve JSONL path: prefer transcript_path from hook input,
# fall back to deriving from CWD project slug
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    JSONL="$TRANSCRIPT_PATH"
else
    # CWD → project slug: replace / with -, remove dots
    PROJECT_SLUG=$(echo "$CWD" | sed 's|/|-|g; s|\.||g')
    JSONL="$HOME/.claude/projects/${PROJECT_SLUG}/${SESSION_ID}.jsonl"
fi

[ -f "$JSONL" ] || exit 0

# Model from bot's start.sh (grep --model flag)
BOT_START="$HOME/.claude-bots/bots/$BOT_NAME/start.sh"
MODEL="sonnet"
if [ -f "$BOT_START" ]; then
    M=$(grep -oP '(?<=--model )\S+' "$BOT_START" 2>/dev/null | head -1)
    [ -n "$M" ] && MODEL="$M"
fi

# Aggregate tokens and write log entry via Python
python3 - "$JSONL" "$SESSION_ID" "$BOT_NAME" "$MODEL" <<'PYEOF'
import json, sys, os, datetime

jsonl_path, session_id, bot, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

input_tokens = output_tokens = cache_read_tokens = 0

with open(jsonl_path, encoding='utf-8', errors='ignore') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        # usage can appear at top level or nested in message
        usage = obj.get('usage') or (obj.get('message') or {}).get('usage') or {}
        input_tokens     += usage.get('input_tokens', 0) or 0
        output_tokens    += usage.get('output_tokens', 0) or 0
        cache_read_tokens += usage.get('cache_read_input_tokens', 0) or 0

# Pricing per 1M tokens
if 'opus' in model:
    cost = (input_tokens * 15 + output_tokens * 75 + cache_read_tokens * 1.5) / 1_000_000
else:  # sonnet / haiku / default → use sonnet pricing as upper bound
    cost = (input_tokens * 3 + output_tokens * 15 + cache_read_tokens * 0.3) / 1_000_000

now = datetime.datetime.utcnow()
entry = {
    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "date": now.strftime("%Y-%m-%d"),
    "bot": bot,
    "model": model,
    "session_id": session_id,
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cache_read_tokens": cache_read_tokens,
    "approx_cost_usd": round(cost, 4),
}

logs_dir = os.path.expanduser("~/.claude-bots/logs")
os.makedirs(logs_dir, exist_ok=True)
usage_log = os.path.join(logs_dir, "usage.jsonl")

with open(usage_log, 'a', encoding='utf-8') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

print(f"usage-log: {bot}/{model} in={input_tokens} out={output_tokens} "
      f"cache_read={cache_read_tokens} cost=${cost:.4f}", file=sys.stderr)
PYEOF

exit 0

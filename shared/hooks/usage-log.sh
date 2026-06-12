#!/usr/bin/env bash
# usage-log.sh — Stop hook: aggregate session token usage and append to logs/usage.jsonl
#
# Input (stdin): {"session_id": "...", "transcript_path": "...", "cwd": "..."}
# Output: ~/.claude-bots/logs/usage.jsonl (one JSON line per session)
#
# Log format:
#   {"ts":"...","date":"...","bot":"assistant","model":"sonnet","session_id":"...",
#    "input_tokens":N,"output_tokens":N,"cache_read_tokens":N,"approx_cost_usd":N}

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Need at least session_id
[ -z "$SESSION_ID" ] && exit 0

# Bot name: prefer TELEGRAM_STATE_DIR (reliable), fall back to CWD parse
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [ -z "$BOT_NAME" ]; then
    BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
fi
[ -z "$BOT_NAME" ] && BOT_NAME="unknown"

# Resolve JSONL path: prefer transcript_path from hook input,
# fall back to deriving from CWD project slug
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    JSONL="$TRANSCRIPT_PATH"
else
    # CWD → project slug: replace / with -, replace . with -
    PROJECT_SLUG=$(echo "$CWD" | sed 's|/|-|g; s|\.|-|g')
    JSONL="$HOME/.claude/projects/${PROJECT_SLUG}/${SESSION_ID}.jsonl"
fi

[ -f "$JSONL" ] || exit 0

# Model from model-resolve.sh shim (D2 convergence — must use FULL PATH, Stop hook has no login shell PATH)
SHIM="/home/oldrabbit/.claude-bots/shared/bin/model-resolve.sh"
if [ -x "$SHIM" ]; then
    MODEL=$("$SHIM" "$BOT_NAME" 2>/dev/null || echo "sonnet")
else
    # Fallback: grep start.sh (pre-convergence or shim unavailable)
    BOT_START="$HOME/.claude-bots/bots/$BOT_NAME/start.sh"
    MODEL="sonnet"
    if [ -f "$BOT_START" ]; then
        M=$(grep -oP '(?<=--model )\S+' "$BOT_START" 2>/dev/null | head -1)
        [ -n "$M" ] && MODEL="$M"
    fi
fi

# Aggregate tokens, per-turn latency, rate_limit events, and write log entry
python3 - "$JSONL" "$SESSION_ID" "$BOT_NAME" "$MODEL" <<'PYEOF'
import json, sys, os, datetime, statistics

jsonl_path, session_id, bot, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

input_tokens = output_tokens = cache_read_tokens = cache_write_tokens = 0
rate_limit_events = 0
turns = []  # list of (user_ts, assistant_ts) pairs for per-turn latency
last_user_ts = None

with open(jsonl_path, encoding='utf-8', errors='ignore') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue

        # token aggregation
        usage = obj.get('usage') or (obj.get('message') or {}).get('usage') or {}
        input_tokens      += usage.get('input_tokens', 0) or 0
        output_tokens     += usage.get('output_tokens', 0) or 0
        cache_read_tokens += usage.get('cache_read_input_tokens', 0) or 0
        cache_write_tokens += usage.get('cache_creation_input_tokens', 0) or 0

        # per-turn latency: user ts → first assistant ts per turn
        obj_type = obj.get('type', '')
        ts_str = obj.get('timestamp', '')
        if obj_type == 'user' and ts_str:
            last_user_ts = ts_str
        elif obj_type == 'assistant' and ts_str and last_user_ts:
            try:
                t_user = datetime.datetime.fromisoformat(last_user_ts.replace('Z', '+00:00'))
                t_asst = datetime.datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
                delta_ms = (t_asst - t_user).total_seconds() * 1000
                if 0 < delta_ms < 300_000:  # sanity: 0–5min
                    turns.append(delta_ms)
            except Exception:
                pass
            last_user_ts = None  # reset: first assistant reply per turn only

        # rate limit events: look for 429 / overloaded / rate_limit in content
        content_str = json.dumps(obj).lower()
        if '429' in content_str or 'rate_limit' in content_str or 'overloaded' in content_str:
            rate_limit_events += 1

# per-turn latency percentiles
latency_p50 = round(statistics.median(turns), 1) if turns else None
latency_p95 = round(sorted(turns)[int(len(turns) * 0.95)], 1) if len(turns) >= 2 else None

# approx_cost_usd: API-equivalent concept value, NOT real spend (internal subscription)
if 'opus' in model:
    cost = (input_tokens * 15 + output_tokens * 75 + cache_read_tokens * 1.5 + cache_write_tokens * 18.75) / 1_000_000
else:
    cost = (input_tokens * 3 + output_tokens * 15 + cache_read_tokens * 0.3 + cache_write_tokens * 3.75) / 1_000_000

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
    "cache_write_tokens": cache_write_tokens,
    # approx_cost_usd is API-equivalent concept, NOT real spend (internal subscription)
    "approx_cost_usd": round(cost, 4),
    # D3 measurement fields
    "latency_ms_p50": latency_p50,     # per-turn median (user→assistant ms)
    "latency_ms_p95": latency_p95,     # per-turn p95
    "latency_turns": len(turns),        # number of turns measured
    "rate_limit_events": rate_limit_events,  # 429/overloaded events in transcript
    "route_tag": "bot-direct",          # stop hook = bot direct session
    "subscription_account": "default",  # extend when multi-account routing active
}

logs_dir = os.path.expanduser("~/.claude-bots/logs")
os.makedirs(logs_dir, exist_ok=True)
usage_log = os.path.join(logs_dir, "usage.jsonl")

with open(usage_log, 'a', encoding='utf-8') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

print(f"usage-log: {bot}/{model} in={input_tokens} out={output_tokens} "
      f"cache_read={cache_read_tokens} cost_equiv=${cost:.4f} "
      f"latency_p50={latency_p50}ms turns={len(turns)} rate_limit={rate_limit_events}",
      file=sys.stderr)
PYEOF

exit 0

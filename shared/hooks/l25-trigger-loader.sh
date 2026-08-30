#!/usr/bin/env bash
# l25-trigger-loader.sh — L2.5 Trigger-Based Block Loader
#
# Dual-mode hook:
#   SessionStart     → refresh manifest.json + inject priority:high blocks
#   UserPromptSubmit → match prompt triggers + inject matching blocks
#
# Every eligible block attempt is recorded in logs/l25-trigger.jsonl. A block
# is injected at most once per sanitized session_id; duplicate attempts are
# logged with first_in_session=false so the saved context cost is measurable.

set -u

INPUT=$(cat)

EVENT=$(jq -r '.hook_event_name // .hookEventName // ""' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // .sessionId // "unknown"' <<<"$INPUT")
SESSION_ID=$(tr -cd 'a-zA-Z0-9_-' <<<"$SESSION_ID" | head -c 64)
# Missing or wholly-invalid IDs must not share a global dedup bucket. Failing
# open here preserves context injection when a caller omits session identity.
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "unknown" ]; then
    SESSION_ID="anonymous-$$"
fi
CWD=$(jq -r '.cwd // ""' <<<"$INPUT")

BOT_NAME=$(sed -n 's|.*/bots/\([^/]*\).*|\1|p' <<<"$CWD")
[ -z "$BOT_NAME" ] && exit 0

L25_ROOT="${L25_ROOT:-$HOME/.claude-bots}"
BLOCKS_DIR="${L25_BLOCKS_DIR:-$L25_ROOT/bots/$BOT_NAME/blocks}"
MANIFEST="$BLOCKS_DIR/manifest.json"
INJECTED_LOG="$BLOCKS_DIR/.injected-$SESSION_ID"
LOAD_LOG="${L25_LOG_PATH:-$L25_ROOT/logs/l25-trigger.jsonl}"
MANIFEST_GENERATOR="${L25_MANIFEST_GENERATOR:-$L25_ROOT/shared/lib/generate-manifest.py}"

generate_manifest() {
    python3 "$MANIFEST_GENERATOR" "$BLOCKS_DIR" "$MANIFEST" 2>&1 \
        | grep -v '^$' >&2 || true
}

case "$EVENT" in
    SessionStart)
        [ -d "$BLOCKS_DIR" ] || exit 0
        generate_manifest 2>/dev/null
        [ -f "$MANIFEST" ] || exit 0
        # Session identity is the boundary. Do not clear an existing file for
        # the same ID: duplicate SessionStart delivery must remain deduplicated.
        find "$BLOCKS_DIR" \( -name '.injected-*' -o -name '.injected-*.lock' \) \
            -mtime +7 -delete 2>/dev/null || true
        PROMPT=""
        ;;
    UserPromptSubmit)
        PROMPT=$(jq -r '.prompt // ""' <<<"$INPUT")
        [ -z "$PROMPT" ] && exit 0
        [ -d "$BLOCKS_DIR" ] && [ ! -f "$MANIFEST" ] && generate_manifest 2>/dev/null
        [ -f "$MANIFEST" ] || exit 0
        ;;
    *)
        exit 0
        ;;
esac

CTX=$(python3 - "$EVENT" "$MANIFEST" "$INJECTED_LOG" "$PROMPT" \
    "$SESSION_ID" "$BOT_NAME" "$LOAD_LOG" <<'PYEOF' 2>/dev/null
import datetime
import fcntl
import json
import re
import sys
from pathlib import Path

event, manifest_path, state_path, prompt, session_id, bot, log_path = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text())
prompt = prompt.lower()
state = Path(state_path)
state.parent.mkdir(parents=True, exist_ok=True)

if event == "SessionStart":
    candidates = [b for b in manifest if b.get("priority") == "high"]
    token_budget = 5000
    heading = "📦 L2.5 自動載入（priority:high blocks）："
else:
    candidates = []
    for block in manifest:
        if any(str(trigger).lower() in prompt for trigger in block.get("triggers", [])):
            candidates.append(block)
    priority_order = {"high": 0, "medium": 1, "low": 2}
    candidates.sort(key=lambda b: priority_order.get(b.get("priority", "medium"), 1))
    token_budget = 3000
    heading = "💡 L2.5 Trigger 載入（prompt 命中）："


def append_records(records):
    if not records:
        return
    try:
        target = Path(log_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            for record in records:
                handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            handle.flush()
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        # Observability must not disable the existing context-injection path.
        pass


parts = [heading]
loaded = []
records = []
used = 0
now = datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")

# The per-session lock makes the read/check/mark decision atomic across hook
# processes. Without it, two simultaneous prompt events can both inject.
with Path(str(state) + ".lock").open("a+") as state_lock:
    fcntl.flock(state_lock, fcntl.LOCK_EX)
    already = set(state.read_text().splitlines()) if state.exists() else set()

    for block in candidates:
        name = block.get("name", "")
        path = Path(block.get("path", ""))
        if not name or not path.is_file():
            continue

        raw = path.read_bytes()
        text = raw.decode("utf-8", errors="replace")
        body = re.sub(r"^---.*?---\s*\n", "", text, flags=re.DOTALL, count=1).strip()
        source_bytes = len(raw)
        context_bytes = len(body.encode("utf-8"))

        if name in already:
            records.append({
                "ts": now,
                "session_id": session_id,
                "bot": bot,
                "event": event,
                "block": name,
                "bytes": source_bytes,
                "context_bytes": context_bytes,
                "first_in_session": False,
                "injected": False,
            })
            continue

        cost = int(block.get("size_tokens", 500) or 500)
        if used + cost > token_budget:
            continue

        parts.append(f"\n### {name}\n{body}")
        loaded.append(name)
        already.add(name)
        used += cost
        records.append({
            "ts": now,
            "session_id": session_id,
            "bot": bot,
            "event": event,
            "block": name,
            "bytes": source_bytes,
            "context_bytes": context_bytes,
            "first_in_session": True,
            "injected": True,
        })

    if loaded:
        with state.open("a", encoding="utf-8") as handle:
            for name in loaded:
                handle.write(name + "\n")

    append_records(records)
    fcntl.flock(state_lock, fcntl.LOCK_UN)

if loaded:
    print("\n".join(parts))
PYEOF
)

[ -z "$CTX" ] && exit 0

jq -n -c --arg event "$EVENT" --arg msg "$CTX" \
    '{hookSpecificOutput:{hookEventName:$event, additionalContext:$msg}}'

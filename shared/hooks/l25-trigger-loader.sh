#!/usr/bin/env bash
# l25-trigger-loader.sh — L2.5 Trigger-Based Block Loader
#
# Dual-mode hook:
#   SessionStart   → Generate/refresh manifest.json + inject priority:high blocks
#   UserPromptSubmit → Match triggers in prompt → inject matching blocks dynamically
#
# Block structure: ~/.claude-bots/bots/{bot}/blocks/block-*.md
# Each block has frontmatter: triggers, priority, size_tokens
#
# Cold-start: only priority:high blocks auto-injected (SessionStart)
# Dynamic:    any block whose trigger matches the prompt (UserPromptSubmit)
# Dedup:      blocks already injected this session are not re-injected
#             (tracked in ~/.claude-bots/bots/{bot}/blocks/.injected-{session_id})

set -u

INPUT=$(cat)

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // .hookEventName // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
# Sanitize SESSION_ID to prevent path traversal
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-' | head -c 64)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

BOT_NAME=$(echo "$CWD" | sed -n 's|.*/bots/\([^/]*\).*|\1|p')
[ -z "$BOT_NAME" ] && exit 0

BLOCKS_DIR="$HOME/.claude-bots/bots/$BOT_NAME/blocks"
MANIFEST="$BLOCKS_DIR/manifest.json"
INJECTED_LOG="$BLOCKS_DIR/.injected-$SESSION_ID"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Generate manifest.json from blocks/*.md frontmatter
generate_manifest() {
    python3 - "$BLOCKS_DIR" "$MANIFEST" <<'PYEOF'
import json, re, sys
from pathlib import Path

blocks_dir = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])

FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---', re.DOTALL)

manifest = []
for f in sorted(blocks_dir.glob("block-*.md")):
    if f.name.endswith(".pre-symlink"):
        continue
    text = f.read_text(errors='replace')
    m = FRONTMATTER_RE.match(text)
    if not m:
        continue
    fm = m.group(1)
    # Parse YAML fields manually (avoid pyyaml dep)
    triggers = []
    t_match = re.search(r'^triggers:\s*(\[.*?\])', fm, re.MULTILINE)
    if t_match:
        try:
            triggers = json.loads(t_match.group(1))
        except Exception:
            pass
    priority = "medium"
    p_match = re.search(r'^priority:\s*(\w+)', fm, re.MULTILINE)
    if p_match:
        priority = p_match.group(1).strip()
    size_tokens = 0
    s_match = re.search(r'^size_tokens:\s*(\d+)', fm, re.MULTILINE)
    if s_match:
        size_tokens = int(s_match.group(1))
    manifest.append({
        "name": f.name,
        "path": str(f),
        "triggers": triggers,
        "priority": priority,
        "size_tokens": size_tokens,
    })

manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
print(f"manifest: {len(manifest)} blocks", file=sys.stderr)
PYEOF
}

# Check if block already injected this session
already_injected() {
    local name="$1"
    [ -f "$INJECTED_LOG" ] && grep -qF "$name" "$INJECTED_LOG"
}

# Mark block as injected
mark_injected() {
    echo "$1" >> "$INJECTED_LOG"
}

# ── SessionStart ─────────────────────────────────────────────────────────────

if [ "$EVENT" = "SessionStart" ]; then
    [ -d "$BLOCKS_DIR" ] || exit 0

    # Regenerate manifest
    generate_manifest 2>/dev/null

    [ -f "$MANIFEST" ] || exit 0

    # Clear injection log for this session
    rm -f "$INJECTED_LOG"

    # Clean up stale injection logs (older than 7 days)
    find "$BLOCKS_DIR" -name '.injected-*' -mtime +7 -delete 2>/dev/null

    # Inject all priority:high blocks (cap at 5000 tokens)
    CTX=$(python3 - "$MANIFEST" "$INJECTED_LOG" <<'PYEOF' 2>/dev/null
import json, re, sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
injected_log = sys.argv[2]

high_blocks = [b for b in manifest if b.get("priority") == "high"]
if not high_blocks:
    sys.exit(0)

TOKEN_BUDGET = 5000
parts = ["📦 L2.5 自動載入（priority:high blocks）："]
loaded = []
used = 0
for b in high_blocks:
    cost = b.get("size_tokens", 500)
    if used + cost > TOKEN_BUDGET:
        continue
    path = b["path"]
    if not Path(path).exists():
        continue
    text = Path(path).read_text(errors='replace')
    body = re.sub(r'^---.*?---\s*\n', '', text, flags=re.DOTALL, count=1).strip()
    parts.append(f"\n### {b['name']}\n{body}")
    loaded.append(b['name'])
    used += cost

if not loaded:
    sys.exit(0)

# Mark as injected
with open(injected_log, 'w') as f:
    f.write('\n'.join(loaded) + '\n')

print('\n'.join(parts))
PYEOF
)

    [ -z "$CTX" ] && exit 0

    jq -n -c --arg msg "$CTX" \
        '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$msg}}'
    exit 0
fi

# ── UserPromptSubmit ──────────────────────────────────────────────────────────

if [ "$EVENT" = "UserPromptSubmit" ]; then
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
    [ -z "$PROMPT" ] && exit 0
    [ -f "$MANIFEST" ] || exit 0

    CTX=$(python3 - "$MANIFEST" "$INJECTED_LOG" "$PROMPT" <<'PYEOF' 2>/dev/null
import json, re, sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
injected_log = sys.argv[2]
prompt = sys.argv[3].lower()

already = set()
if Path(injected_log).exists():
    already = set(Path(injected_log).read_text().splitlines())

matched = []
for b in manifest:
    if b['name'] in already:
        continue
    for trigger in b.get('triggers', []):
        if trigger.lower() in prompt:
            matched.append(b)
            break

if not matched:
    sys.exit(0)

# Sort by priority (high > medium > low)
PRIORITY_ORDER = {"high": 0, "medium": 1, "low": 2}
matched.sort(key=lambda b: PRIORITY_ORDER.get(b.get("priority", "medium"), 1))

# Budget: cap at 3000 tokens total to avoid context bloat
TOKEN_BUDGET = 3000
parts = ["💡 L2.5 Trigger 載入（prompt 命中）："]
loaded = []
used = 0
for b in matched:
    cost = b.get("size_tokens", 500)
    if used + cost > TOKEN_BUDGET:
        continue
    path = b["path"]
    if not Path(path).exists():
        continue
    text = Path(path).read_text(errors='replace')
    body = re.sub(r'^---.*?---\s*\n', '', text, flags=re.DOTALL, count=1).strip()
    parts.append(f"\n### {b['name']}\n{body}")
    loaded.append(b['name'])
    used += cost

if not loaded:
    sys.exit(0)

# Append newly loaded to injected log
with open(injected_log, 'a') as f:
    f.write('\n'.join(loaded) + '\n')

print('\n'.join(parts))
PYEOF
)

    [ -z "$CTX" ] && exit 0

    jq -n -c --arg msg "$CTX" \
        '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$msg}}'
    exit 0
fi

exit 0

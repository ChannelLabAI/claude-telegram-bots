#!/bin/bash
# Patch script: register §11 / §12 hooks on remote bots (VPS-side).
#
# Usage (on VPS):
#   bash ~/.claude-bots/shared/patch-section11-12-hooks.sh <bot-name> [--assistant|--builder|--reviewer]
#
# Examples:
#   bash patch-section11-12-hooks.sh ron-assistant --assistant   # §11 + §12
#   bash patch-section11-12-hooks.sh ron-builder  --builder      # §11 only
#   bash patch-section11-12-hooks.sh ron-reviewer --reviewer     # §11 only
#
# Assistant bots (apply to all 6 on VPS):
#   ron-assistant, caijie-zhuchu, chltao, nicky-zhanglinghe, lilai-fengfeng, wes-buddy
#
# Idempotent: safe to re-run. Creates .bak backup of settings.json on first run.

set -euo pipefail

BOT="${1:?bot name required}"
ROLE="${2:---assistant}"

SETTINGS="$HOME/.claude-bots/bots/$BOT/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "ERROR: $SETTINGS not found"; exit 1; }

# Backup once
[ -f "$SETTINGS.bak" ] || cp "$SETTINGS" "$SETTINGS.bak"

# Detect already patched
if grep -q 'section11-return-monitor.sh' "$SETTINGS"; then
  echo "Already patched (§11 present). Skipping."
  exit 0
fi

TMP=$(mktemp)

python3 - "$SETTINGS" "$TMP" "$ROLE" <<'PYEOF'
import json, sys
settings_path, tmp_path, role = sys.argv[1:4]

with open(settings_path) as f:
    s = json.load(f)

hooks = s.setdefault("hooks", {})

# §11 PostToolUse on Task (all roles)
post = hooks.setdefault("PostToolUse", [])
post.append({
    "matcher": "Task",
    "hooks": [{
        "type": "command",
        "command": "bash ~/.claude-bots/shared/hooks/section11-return-monitor.sh"
    }]
})

# §12 only for assistants
if role == "--assistant":
    # Append section12-precompact-backup to Stop
    stop = hooks.setdefault("Stop", [])
    empty_matcher = next((h for h in stop if h.get("matcher","") == ""), None)
    if empty_matcher is None:
        empty_matcher = {"matcher": "", "hooks": []}
        stop.append(empty_matcher)
    empty_matcher["hooks"].append({
        "type": "command",
        "command": "bash ~/.claude-bots/shared/hooks/section12-precompact-backup.sh",
        "async": True
    })

    ss = hooks.setdefault("SessionStart", [])
    ss.append({
        "matcher": "",
        "hooks": [{
            "type": "command",
            "command": "bash ~/.claude-bots/shared/hooks/section12-inject.sh"
        }]
    })

with open(tmp_path, "w") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
PYEOF

python3 -c "import json; json.load(open('$TMP'))" >/dev/null
mv "$TMP" "$SETTINGS"

echo "✅ Patched $BOT ($ROLE)"
echo "   §11 hook: PostToolUse matcher=Task"
[ "$ROLE" = "--assistant" ] && echo "   §12 hook: Stop + SessionStart"
echo "   Backup: $SETTINGS.bak"

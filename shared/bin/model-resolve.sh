#!/usr/bin/env bash
# model-resolve.sh — Resolve a bot name to the concrete Claude model ID.
#
# The pod configuration is the source of truth because gateway.ts passes its
# bots[].model value directly to `claude --model`.  model-router.yml is only a
# secondary compatibility source.  The final hardcoded model keeps legacy
# startup fail-safe, but every non-pod result is visibly marked on stderr.
#
# stdout is always exactly one model ID line.  Callers may safely use it as a
# `claude --model` argument; diagnostics never share stdout.

set -euo pipefail

BOT="${1:-}"
SHARED_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SHARED_DIR/.." && pwd)"
PODS_DIR="${MODEL_PODS_DIR:-$ROOT_DIR/pod-system/pods}"
YML_PATH="${MODEL_ROUTER_YML:-$SHARED_DIR/config/model-router.yml}"
ULTIMATE_DEFAULT="claude-sonnet-5"

warn_fallback() {
  local source="$1" model="$2" reason="$3"
  printf '[model-resolve] FALLBACK source=%s bot=%s model=%s reason=%s\n' \
    "$source" "${BOT:-<empty>}" "$model" "$reason" >&2
}

if [[ -z "$BOT" ]]; then
  warn_fallback "hardcoded-default" "$ULTIMATE_DEFAULT" "missing-bot-name"
  printf '%s\n' "$ULTIMATE_DEFAULT"
  exit 0
fi

# Resolve by either the runtime bot name or the bot workspace basename.  The
# latter preserves legacy callers such as 33-huizhang and caijie-zhuchu while
# pod configs use the canonical huizhang and zhuchu names.
POD_MODEL=""
if [[ -d "$PODS_DIR" ]]; then
  POD_MODEL="$(python3 - "$BOT" "$PODS_DIR" 2>/dev/null <<'PYEOF'
import glob
import json
import os
import re
import sys

requested = sys.argv[1].lower()
pods_dir = sys.argv[2]
matches = []
for path in sorted(glob.glob(os.path.join(pods_dir, "*.json"))):
    try:
        with open(path, encoding="utf-8") as handle:
            pod = json.load(handle)
    except Exception:
        sys.exit(2)
    for bot in pod.get("bots", []):
        name = str(bot.get("name", "")).lower()
        workspace = os.path.basename(str(bot.get("dir", "")).rstrip("/")).lower()
        if requested not in {name, workspace}:
            continue
        model = bot.get("model")
        if not isinstance(model, str) or not re.fullmatch(r"claude-[A-Za-z0-9._-]+", model):
            sys.exit(3)
        matches.append(model)

if not matches or len(set(matches)) != 1:
    sys.exit(4)
print(matches[0])
PYEOF
  )" || POD_MODEL=""
fi

if [[ -n "$POD_MODEL" ]]; then
  printf '%s\n' "$POD_MODEL"
  exit 0
fi

# Secondary mirror for legacy/customer deployments whose pod source is absent.
# Only top-level `bot_defaults` is read; nested codex.bot_defaults contains
# sol/terra/luna tiers and must never be interpreted as Claude model aliases.
ROUTER_MODEL=""
if [[ -f "$YML_PATH" ]]; then
  ROUTER_MODEL="$(python3 - "$BOT" "$YML_PATH" 2>/dev/null <<'PYEOF'
import re
import sys

bot = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    lines = handle.read().splitlines()

def top_level_map(section):
    result = {}
    start = None
    for index, line in enumerate(lines):
        if re.fullmatch(re.escape(section) + r"\s*:\s*", line):
            start = index + 1
            break
    if start is None:
        return result
    for line in lines[start:]:
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            break
        match = re.match(r"^\s+([^\s:#]+):\s*([^\s#]+)", line)
        if match:
            result[match.group(1)] = match.group(2).strip("'\"")
    return result

models = top_level_map("models")
defaults = top_level_map("bot_defaults")
if not defaults:
    sys.exit(2)
value = defaults.get(bot) or defaults.get("_default")
if not value:
    sys.exit(3)
model = value if value.startswith("claude-") and value not in models else models.get(value, "")
if not re.fullmatch(r"claude-[A-Za-z0-9._-]+", model):
    sys.exit(4)
print(model)
PYEOF
  )" || ROUTER_MODEL=""
fi

if [[ -n "$ROUTER_MODEL" ]]; then
  warn_fallback "model-router" "$ROUTER_MODEL" "pod-source-unavailable-or-missing"
  printf '%s\n' "$ROUTER_MODEL"
  exit 0
fi

warn_fallback "hardcoded-default" "$ULTIMATE_DEFAULT" "pod-and-router-unavailable-or-missing"
printf '%s\n' "$ULTIMATE_DEFAULT"
exit 0

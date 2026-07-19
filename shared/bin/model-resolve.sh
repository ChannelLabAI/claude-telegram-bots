#!/usr/bin/env bash
# model-resolve.sh — Resolve bot name → full model ID from model-router.yml
#
# Usage:  model-resolve.sh <bot-name>
# Output: full model ID (e.g. claude-opus-4-8 or claude-sonnet-5)
#
# Design: fail-safe — if yml is missing/corrupt/empty, fall back to
# hardcoded defaults so yml can NEVER be a single point of failure
# for 16-bot fleet startup.
#
# Source of truth: shared/config/model-router.yml (bot_defaults + models sections)

set -euo pipefail

BOT="${1:-}"
if [ -z "$BOT" ]; then
  echo "claude-sonnet-5"
  exit 0
fi

YML_PATH="$(cd "$(dirname "$0")/.." && pwd)/config/model-router.yml"

# ── Hardcode fallback table (yml fail-safe) ──────────────────────────────────
# Must exactly match the hardcode in each bot's start.sh BEFORE convergence.
# If yml is absent/corrupt, shim outputs these values — no bot startup breakage.
declare -A FALLBACK=(
  ["anya"]="claude-opus-4-8"
  ["twinkle"]="claude-opus-4-8"
  ["anna"]="claude-sonnet-5"
  ["Bella"]="claude-fable-5"
  ["sancai"]="claude-sonnet-5"
  ["yitang"]="claude-sonnet-5"
  ["eric"]="claude-sonnet-5"
  ["interns"]="claude-sonnet-5"
  ["ron-assistant"]="claude-sonnet-5"
  ["ron-reviewer"]="claude-sonnet-5"
  ["caijie-zhuchu"]="claude-sonnet-5"
  ["chltao"]="claude-sonnet-5"
  ["wes-buddy"]="claude-sonnet-5"
  ["lilai-fengfeng"]="claude-sonnet-5"
  ["33-huizhang"]="claude-sonnet-5"
  ["nicky-zhanglinghe"]="claude-sonnet-5"
)

# ── Try to resolve from yml via python3 ──────────────────────────────────────
# python3 is more reliable than yq for yml parsing across environments.
RESOLVED=""
if [ -f "$YML_PATH" ]; then
  RESOLVED=$(python3 - "$BOT" "$YML_PATH" 2>/dev/null <<'PYEOF'
import sys, re

bot = sys.argv[1]
yml_path = sys.argv[2]

with open(yml_path, encoding='utf-8') as f:
    content = f.read()

def get_section(yml_text, section_name):
    """Extract a simple key: value section from yml (no nested maps)."""
    lines = yml_text.splitlines()
    in_section = False
    result = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#') or not stripped:
            continue
        if re.match(r'^' + re.escape(section_name) + r'\s*:', stripped):
            in_section = True
            continue
        if in_section:
            # End of section: top-level key (no leading whitespace, not comment)
            if re.match(r'^[^\s#]', line) and not re.match(r'^\s', line):
                break
            m = re.match(r'^\s+(\S+):\s+(\S+)', line)
            if m:
                result[m.group(1)] = m.group(2)
    return result

bot_defaults = get_section(content, 'bot_defaults')
models = get_section(content, 'models')

# Blocker 1 fix: corrupt/unparseable yml → exit 1 so bash RESOLVED="" → FALLBACK table
if not bot_defaults:
    sys.exit(1)

alias = bot_defaults.get(bot) or bot_defaults.get('_default') or 'claude-sonnet'
full_id = models.get(alias) or alias
print(full_id.strip())
PYEOF
  ) || RESOLVED=""
fi

# ── Validate and output ───────────────────────────────────────────────────────
# If yml resolution succeeded and gave a non-empty value, use it.
# Otherwise, use fallback table (fail-safe).
if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "None" ]; then
  echo "$RESOLVED"
  exit 0
fi

# Fallback: use hardcoded table
BOT_KEY="${BOT//[^a-zA-Z0-9_-]/}"  # sanitize (shouldn't matter but safe)
if [ -n "${FALLBACK[$BOT_KEY]+_}" ]; then
  echo "${FALLBACK[$BOT_KEY]}"
else
  echo "claude-sonnet-5"  # ultimate default
fi

exit 0

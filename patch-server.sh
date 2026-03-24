#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# patch-server.sh
# Re-apply patched server.ts after Claude Code updates
# Usage: ./patch-server.sh
# ─────────────────────────────────────────────

SHARED_DIR="$HOME/.claude-bots/shared"
PATCHED_SERVER="$SHARED_DIR/server.patched.ts"

# Find the telegram plugin directory (any version)
PLUGIN_BASE="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
PLUGIN_MKT="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

PLUGIN_CACHE=""
if [[ -d "$PLUGIN_MKT" ]]; then
  PLUGIN_CACHE="$PLUGIN_MKT"
elif [[ -d "$PLUGIN_BASE" ]]; then
  # Find the latest version directory
  LATEST=$(ls -d "$PLUGIN_BASE"/*/ 2>/dev/null | sort -V | tail -1)
  if [[ -n "$LATEST" ]]; then
    PLUGIN_CACHE="${LATEST%/}"
  fi
fi

if [[ ! -f "$PATCHED_SERVER" ]]; then
  echo "ERROR: No patched server.ts found at $PATCHED_SERVER" >&2
  echo "Copy your working server.ts (with relay support) there first." >&2
  exit 1
fi

if [[ -z "$PLUGIN_CACHE" || ! -d "$PLUGIN_CACHE" ]]; then
  echo "ERROR: Telegram plugin not found." >&2
  echo "Searched: $PLUGIN_BASE/*, $PLUGIN_MKT" >&2
  exit 1
fi

echo "→ Plugin found at: $PLUGIN_CACHE"

# Backup original before patching (first run only)
if [[ ! -f "$PLUGIN_CACHE/server.ts.original" ]]; then
  cp "$PLUGIN_CACHE/server.ts" "$PLUGIN_CACHE/server.ts.original"
  echo "→ Backed up original server.ts"
fi

if ! cmp -s "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"; then
  cp "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"
  echo "→ Patched server.ts applied"
  echo "→ Restart your bots to pick up changes."
else
  echo "→ server.ts already up to date."
fi

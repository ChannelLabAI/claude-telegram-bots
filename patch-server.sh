#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# patch-server.sh
# Re-apply patched server.ts after Claude Code updates
# Usage: ./patch-server.sh
# ─────────────────────────────────────────────

SHARED_DIR="$HOME/.claude-bots/shared"
PATCHED_SERVER="$SHARED_DIR/server.patched.ts"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.1"

if [[ ! -f "$PATCHED_SERVER" ]]; then
  echo "ERROR: No patched server.ts found at $PATCHED_SERVER" >&2
  echo "Copy your working server.ts (with relay + TELEGRAM_STATE_DIR support) there first." >&2
  exit 1
fi

if [[ ! -d "$PLUGIN_CACHE" ]]; then
  echo "ERROR: Plugin cache not found at $PLUGIN_CACHE" >&2
  echo "Make sure the telegram plugin is installed in Claude Code." >&2
  exit 1
fi

# Backup original before patching (first run only).
# Note: if this script was already run before, server.ts.original may itself
# be a patched version. The backup is best-effort — the true original lives
# in the Claude Code release.
if [[ ! -f "$PLUGIN_CACHE/server.ts.original" ]]; then
  cp "$PLUGIN_CACHE/server.ts" "$PLUGIN_CACHE/server.ts.original"
  echo "→ Backed up original server.ts to server.ts.original"
fi

cp "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"
echo "→ Patched server.ts applied to $PLUGIN_CACHE/server.ts"
echo "→ Done. Restart your bots to pick up changes."

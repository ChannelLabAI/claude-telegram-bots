#!/bin/sh
# seabed-reorg-rollback.sh — Reverse Seabed Phase 1.5 migration
#
# Restores:
#   Ocean/Seabed/chats/YYYY-MM/ → Ocean/Seabed/YYYY-MM/
#   Ocean/Seabed/chats/_index.clsc.md → Ocean/Seabed/chats.clsc.md
#   Ocean/Seabed/reef/{entity}/ → Ocean/Currents/{entity}/Seabed/
#   Removes compat symlinks
#
# Usage: sh seabed-reorg-rollback.sh [--dry-run]
# Alternatively, restore from backup:
#   tar -xzf ~/.claude-bots/backups/seabed-reorg-*.tar.gz -C "$HOME/Documents/Obsidian Vault"

set -e

OCEAN="$HOME/Documents/Obsidian Vault/Ocean"
SEABED="$OCEAN/Seabed"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; echo "[rollback] Dry run — no files moved."; fi

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[rollback] $*"; else eval "$@"; fi
}

echo "[rollback] Starting Seabed Phase 1.5 rollback..."

# ── Step 1: Remove compat symlinks ─────────────────────────────────────────────
for link in "$SEABED"/????-??; do
  if [ -L "$link" ]; then
    echo "[rollback] removing symlink $(basename "$link")"
    run rm "\"$link\""
  fi
done

# ── Step 2: Move chats/YYYY-MM/ back to root ───────────────────────────────────
if [ -d "$SEABED/chats" ]; then
  for month_dir in "$SEABED/chats"/????-??; do
    base="$(basename "$month_dir")"
    dest="$SEABED/$base"
    if [ -d "$month_dir" ] && [ ! -d "$dest" ]; then
      echo "[rollback] mv chats/$base → $base"
      run mv "\"$month_dir\"" "\"$dest\""
    fi
  done
fi

# ── Step 3: Move chats/_index.clsc.md back ────────────────────────────────────
NEW_CLSC="$SEABED/chats/_index.clsc.md"
OLD_CLSC="$SEABED/chats.clsc.md"
if [ -f "$NEW_CLSC" ] && [ ! -f "$OLD_CLSC" ]; then
  echo "[rollback] mv chats/_index.clsc.md → chats.clsc.md"
  run mv "\"$NEW_CLSC\"" "\"$OLD_CLSC\""
fi

# ── Step 4: Move reef/{entity}/ back to Currents ─────────────────────────────
# NOTE: We can't reconstruct the original Current+Reef path from entity name alone.
# This step restores to Currents/{entity}/Seabed/ (best effort).
if [ -d "$SEABED/reef" ]; then
  for entity_dir in "$SEABED/reef"/*/; do
    entity="$(basename "$entity_dir")"
    dest_parent="$OCEAN/Currents/$entity"
    dest="$dest_parent/Seabed"
    if [ -d "$entity_dir" ] && [ ! -d "$dest" ]; then
      echo "[rollback] restoring reef/$entity → Currents/$entity/Seabed"
      run mkdir -p "\"$dest_parent\""
      run mv "\"$entity_dir\"" "\"$dest\""
    fi
  done
fi

echo "[rollback] Rollback complete."
echo "NOTE: ocean_seabed_write.py path change is in code — revert git commit separately."
echo "      Backup restore is more reliable: tar -xzf ~/.claude-bots/backups/seabed-reorg-*.tar.gz -C \"\$HOME/Documents/Obsidian Vault\""

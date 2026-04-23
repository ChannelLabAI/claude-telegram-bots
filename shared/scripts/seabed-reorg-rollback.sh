#!/bin/sh
# seabed-reorg-rollback.sh — Reverse Seabed Phase 1.5 migration
#
# Restores:
#   Ocean/原檔海床/chats/YYYY-MM/ → Ocean/原檔海床/YYYY-MM/
#   Ocean/原檔海床/chats/_index.clsc.md → Ocean/原檔海床/chats.clsc.md
#   Ocean/原檔海床/reef/{entity}/ → Ocean/業務流/{entity}/Seabed/
#   Removes compat symlinks
#
# Usage: sh seabed-reorg-rollback.sh [--dry-run]
# Alternatively, restore from backup:
#   tar -xzf ~/.claude-bots/backups/seabed-reorg-*.tar.gz -C "$HOME/Documents/Obsidian Vault"

set -e

OCEAN="$HOME/Documents/Obsidian Vault/Ocean"
SEABED="$OCEAN/Seabed"
SYNCTHING_FOLDER="ocean-shared"
SYNCTHING_API="http://localhost:8384"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; echo "[rollback] Dry run — no files moved."; fi

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[rollback] $*"; else eval "$@"; fi
}

SYNC_KEY=""
if [ -f "$HOME/.config/syncthing/config.xml" ]; then
  SYNC_KEY=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$HOME/.config/syncthing/config.xml')
k = tree.getroot().find('.//apikey')
print(k.text if k is not None else '')
" 2>/dev/null || true)
fi

echo "[rollback] Starting Seabed Phase 1.5 rollback..."

# Pause Syncthing before file ops
if [ -n "$SYNC_KEY" ]; then
  run "curl -s -X POST '$SYNCTHING_API/rest/db/pause?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
  echo "[rollback] Syncthing folder paused"
fi

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

# Resume Syncthing after file ops
if [ -n "$SYNC_KEY" ]; then
  run "curl -s -X POST '$SYNCTHING_API/rest/db/resume?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
  run "curl -s '$SYNCTHING_API/rest/db/scan?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
  echo "[rollback] Syncthing folder resumed"
fi

echo "[rollback] Rollback complete."
echo "NOTE: ocean_seabed_write.py path change is in code — revert git commit separately."
echo "      Backup restore is more reliable: tar -xzf ~/.claude-bots/backups/seabed-reorg-*.tar.gz -C \"\$HOME/Documents/Obsidian Vault\""

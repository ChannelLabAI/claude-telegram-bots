#!/bin/sh
# seabed-reorg-migration.sh — Seabed Phase 1.5 one-shot migration
#
# Moves:
#   Ocean/原檔海床/YYYY-MM/   → Ocean/原檔海床/chats/YYYY-MM/
#   Ocean/原檔海床/chats.clsc.md → Ocean/原檔海床/chats/_index.clsc.md
#   Ocean/業務流/*/Seabed/ → Ocean/原檔海床/reef/{current}-{reef}/
# Creates: docs/{spec,pdf,release-note}/ raw/ scaffold
# Creates: 90-day backward-compat symlinks for old paths
#
# Idempotent: re-running skips already-moved items.
# Usage: sh seabed-reorg-migration.sh [--dry-run]

set -e

OCEAN="$HOME/Documents/Obsidian Vault/Ocean"
SEABED="$OCEAN/Seabed"
BACKUP_DIR="$HOME/.claude-bots/backups"
SYNCTHING_FOLDER="ocean-shared"
SYNCTHING_API="http://localhost:8384"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; echo "[dry-run] No files will be moved."; fi

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else eval "$@"; fi
}

# Read Syncthing API key from config
SYNC_KEY=""
if [ -f "$HOME/.config/syncthing/config.xml" ]; then
  SYNC_KEY=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$HOME/.config/syncthing/config.xml')
k = tree.getroot().find('.//apikey')
print(k.text if k is not None else '')
" 2>/dev/null || true)
fi

syncthing_pause() {
  if [ -n "$SYNC_KEY" ]; then
    echo "[ph15] Pausing Syncthing folder: $SYNCTHING_FOLDER"
    run "curl -s -X POST '$SYNCTHING_API/rest/db/pause?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
  else
    echo "[ph15] WARNING: Syncthing API key not found — pause skipped. Stop Syncthing manually before continuing."
  fi
}

syncthing_resume() {
  if [ -n "$SYNC_KEY" ]; then
    echo "[ph15] Resuming Syncthing folder: $SYNCTHING_FOLDER"
    run "curl -s -X POST '$SYNCTHING_API/rest/db/resume?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
    run "curl -s '$SYNCTHING_API/rest/db/scan?folder=$SYNCTHING_FOLDER' -H 'X-API-Key: $SYNC_KEY' -o /dev/null || true"
  fi
}

echo "[ph15] Starting Seabed Phase 1.5 migration..."

# ── Step 0: Backup ─────────────────────────────────────────────────────────────
BACKUP_TAR="$BACKUP_DIR/seabed-reorg-$(date +%Y%m%d-%H%M%S).tar.gz"
run mkdir -p "$BACKUP_DIR"
if [ "$DRY_RUN" = "0" ]; then
  echo "[ph15] Creating backup → $BACKUP_TAR"
  tar -czf "$BACKUP_TAR" \
    -C "$HOME/Documents/Obsidian Vault" \
    "Ocean/原檔海床" \
    2>/dev/null || true
  echo "[ph15] Backup done: $BACKUP_TAR"
fi

# ── Syncthing pause (before any file ops) ──────────────────────────────────────
syncthing_pause

# ── Step 1: Create new directory scaffold ──────────────────────────────────────
for d in \
  "$SEABED/chats" \
  "$SEABED/docs/spec" \
  "$SEABED/docs/pdf" \
  "$SEABED/docs/release-note" \
  "$SEABED/reef" \
  "$SEABED/raw"
do
  run mkdir -p "\"$d\""
done
echo "[ph15] Directory scaffold ready."

# ── Step 2: Move chats YYYY-MM/ dirs into chats/ ──────────────────────────────
for month_dir in "$SEABED"/????-??; do
  [ -d "$month_dir" ] || continue
  base="$(basename "$month_dir")"
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9])
      dest="$SEABED/chats/$base"
      if [ ! -d "$dest" ]; then
        echo "[ph15] mv Seabed/$base → Seabed/chats/$base"
        run mv "\"$month_dir\"" "\"$dest\""
      else
        echo "[ph15] merge Seabed/$base → Seabed/chats/$base"
        run "cp -n \"$month_dir\"/*.md \"$dest\"/ 2>/dev/null || true"
        run rmdir "\"$month_dir\"" 2>/dev/null || echo "[ph15] $month_dir not empty after merge, skipping rmdir"
      fi
      ;;
  esac
done

# ── Step 3: Move chats.clsc.md → chats/_index.clsc.md ─────────────────────────
OLD_CLSC="$SEABED/chats.clsc.md"
NEW_CLSC="$SEABED/chats/_index.clsc.md"
if [ -f "$OLD_CLSC" ] && [ ! -f "$NEW_CLSC" ]; then
  echo "[ph15] mv chats.clsc.md → chats/_index.clsc.md"
  run mv "\"$OLD_CLSC\"" "\"$NEW_CLSC\""
  # Backward-compat symlink: Ocean/原檔海床/chats.clsc.md → chats/_index.clsc.md
  if [ "$DRY_RUN" = "0" ] && [ ! -L "$OLD_CLSC" ]; then
    ln -s "chats/_index.clsc.md" "$OLD_CLSC"
    echo "[ph15] symlink chats.clsc.md → chats/_index.clsc.md (90-day compat)"
  else
    echo "[dry-run] ln -s chats/_index.clsc.md \"$OLD_CLSC\""
  fi
elif [ -f "$OLD_CLSC" ] && [ -f "$NEW_CLSC" ]; then
  run rm "\"$OLD_CLSC\""
  if [ "$DRY_RUN" = "0" ] && [ ! -L "$OLD_CLSC" ]; then
    ln -s "chats/_index.clsc.md" "$OLD_CLSC"
  fi
fi

# ── Step 4: Move Currents/*/Seabed/ → Seabed/reef/{current}-{reef}/ ──────────
# Use tmpfile to avoid find|while subshell (which swallows set -e errors)
_FIND_TMP="$(mktemp)"
find "$OCEAN/Currents" -name "Seabed" -type d > "$_FIND_TMP" 2>/dev/null || true

while IFS= read -r seabed_dir; do
  [ -n "$seabed_dir" ] || continue
  reef_dir="$(dirname "$seabed_dir")"
  reef="$(basename "$reef_dir")"
  current="$(basename "$(dirname "$reef_dir")")"
  entity="$(printf '%s-%s' "$current" "$reef" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  dest="$SEABED/reef/$entity"
  if [ ! -d "$dest" ]; then
    echo "[ph15] mv Currents/$current/$reef/Seabed → Seabed/reef/$entity"
    if [ "$DRY_RUN" = "0" ]; then
      mv "$seabed_dir" "$dest" || { echo "ERROR: mv failed for $seabed_dir"; rm -f "$_FIND_TMP"; exit 1; }
    else
      echo "[dry-run] mv \"$seabed_dir\" \"$dest\""
    fi
  else
    echo "[ph15] reef/$entity already exists, merging from $seabed_dir"
    if [ "$DRY_RUN" = "0" ]; then
      cp -rn "$seabed_dir"/. "$dest"/ 2>/dev/null || true
      rm -rf "$seabed_dir" || { echo "ERROR: rm failed for $seabed_dir"; rm -f "$_FIND_TMP"; exit 1; }
    else
      echo "[dry-run] cp+rm \"$seabed_dir\" → \"$dest\""
    fi
  fi
done < "$_FIND_TMP"
rm -f "$_FIND_TMP"

# ── Step 5: 90-day backward-compat symlinks (YYYY-MM) ──────────────────────────
for chats_month in "$SEABED/chats"/????-??; do
  [ -d "$chats_month" ] || continue
  base="$(basename "$chats_month")"
  link="$SEABED/$base"
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    echo "[ph15] symlink Seabed/$base → chats/$base (90-day compat)"
    run ln -s "chats/$base" "\"$link\""
  fi
done

# ── Syncthing resume (after all file ops) ──────────────────────────────────────
syncthing_resume

echo "[ph15] Migration complete."
echo ""
echo "Next steps:"
echo "  1. Restart tg-daily-ingest cron if it was running"
echo "  2. Re-import Ocean/ into GBrain: gbrain import Ocean/ (if gbrain installed)"
echo "  3. Run: python3 shared/scripts/ocean_seabed_rebuild.py --verify"
echo "  4. After 90 days: remove symlinks in Ocean/原檔海床/YYYY-MM/ and chats.clsc.md"

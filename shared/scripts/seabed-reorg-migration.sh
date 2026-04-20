#!/bin/sh
# seabed-reorg-migration.sh — Seabed Phase 1.5 one-shot migration
#
# Moves:
#   Ocean/Seabed/YYYY-MM/   → Ocean/Seabed/chats/YYYY-MM/
#   Ocean/Seabed/chats.clsc.md → Ocean/Seabed/chats/_index.clsc.md
#   Ocean/Currents/*/Seabed/ → Ocean/Seabed/reef/{entity}/
# Creates: docs/{spec,pdf,release-note}/ raw/ scaffold
# Creates: 90-day backward-compat symlinks for old paths
#
# Idempotent: re-running skips already-moved items.
# Usage: sh seabed-reorg-migration.sh [--dry-run]

set -e

OCEAN="$HOME/Documents/Obsidian Vault/Ocean"
SEABED="$OCEAN/Seabed"
BACKUP_DIR="$HOME/.claude-bots/backups"
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; echo "[dry-run] No files will be moved."; fi

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else eval "$@"; fi
}

echo "[ph15] Starting Seabed Phase 1.5 migration..."

# ── Step 0: Backup ─────────────────────────────────────────────────────────────
BACKUP_TAR="$BACKUP_DIR/seabed-reorg-$(date +%Y%m%d-%H%M%S).tar.gz"
run mkdir -p "$BACKUP_DIR"
if [ "$DRY_RUN" = "0" ]; then
  echo "[ph15] Creating backup → $BACKUP_TAR"
  tar -czf "$BACKUP_TAR" \
    -C "$HOME/Documents/Obsidian Vault" \
    "Ocean/Seabed" \
    $(find "$OCEAN/Currents" -name "Seabed" -type d -exec echo "Ocean/Currents/{}" \; 2>/dev/null | sed "s|$HOME/Documents/Obsidian Vault/||" | tr '\n' ' ') \
    2>/dev/null || true
  echo "[ph15] Backup done."
fi

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
  base="$(basename "$month_dir")"
  # Only move pure YYYY-MM dirs (not chats/ docs/ reef/ raw/)
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9])
      dest="$SEABED/chats/$base"
      if [ -d "$month_dir" ] && [ ! -d "$dest" ]; then
        echo "[ph15] mv Seabed/$base → Seabed/chats/$base"
        run mv "\"$month_dir\"" "\"$dest\""
      elif [ -d "$month_dir" ] && [ -d "$dest" ]; then
        # Both exist — merge (chats/ dir already has newer writes)
        echo "[ph15] merge Seabed/$base → Seabed/chats/$base"
        run "cp -n \"$month_dir\"/*.md \"$dest\"/ 2>/dev/null || true"
        run rmdir "\"$month_dir\"" 2>/dev/null || echo "[ph15] $month_dir not empty after merge, leaving"
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
elif [ -f "$OLD_CLSC" ] && [ -f "$NEW_CLSC" ]; then
  echo "[ph15] chats/_index.clsc.md already exists, removing old chats.clsc.md"
  run rm "\"$OLD_CLSC\""
fi

# ── Step 4: Move Currents/*/Seabed/ → Seabed/reef/{current}-{reef}/ ──────────
# Use qualified "{current}-{reef}" to avoid collisions (e.g. NOXCAT/Product
# and ChannelLab/Product would both map to "product" without qualification).
find "$OCEAN/Currents" -name "Seabed" -type d | while IFS= read -r seabed_dir; do
  reef_dir="$(dirname "$seabed_dir")"
  reef="$(basename "$reef_dir")"
  current="$(basename "$(dirname "$reef_dir")")"
  # Build entity: "{current}-{reef}" lowercased, spaces→dashes
  entity="$(printf '%s-%s' "$current" "$reef" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  dest="$SEABED/reef/$entity"
  if [ ! -d "$dest" ]; then
    echo "[ph15] mv Currents/$current/$reef/Seabed → Seabed/reef/$entity"
    run mv "\"$seabed_dir\"" "\"$dest\""
  else
    echo "[ph15] reef/$entity already exists, merging from $seabed_dir"
    run "cp -rn \"$seabed_dir\"/. \"$dest\"/ 2>/dev/null || true"
    run rm -rf "\"$seabed_dir\""
  fi
done

# ── Step 5: 90-day backward-compat symlinks ────────────────────────────────────
# Symlink old root-level YYYY-MM → chats/YYYY-MM for any existing external refs
for chats_month in "$SEABED/chats"/????-??; do
  base="$(basename "$chats_month")"
  link="$SEABED/$base"
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    echo "[ph15] symlink Seabed/$base → chats/$base (90-day compat)"
    run ln -s "chats/$base" "\"$link\""
  fi
done

echo "[ph15] Migration complete."
echo ""
echo "Next steps:"
echo "  1. Restart tg-daily-ingest cron if it was running"
echo "  2. Re-import Ocean/ into GBrain: gbrain import Ocean/ (if gbrain installed)"
echo "  3. Run ocean_seabed_rebuild.py --verify to confirm rebuild works"
echo "  4. After 90 days: remove symlinks in Ocean/Seabed/YYYY-MM/"

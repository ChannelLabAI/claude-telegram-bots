#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# backup.sh
# Back up all claude-telegram-bots data before migration or upgrades
#
# What gets backed up:
#   ~/.claude-bots/bots/          — bot workspaces (CLAUDE.md, settings)
#   ~/.claude-bots/state/         — bot state (tokens, access.json)
#   ~/.claude-bots/shared/        — server.patched.ts
#   ~/.claude/projects/*claude-bots* — bot memory (conversation history)
#
# Usage: ./backup.sh [output_dir]
#   output_dir defaults to ~/claude-bots-backup-<timestamp>.tar.gz
# ─────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT="${1:-$HOME/claude-bots-backup-${TIMESTAMP}.tar.gz}"

CLAUDE_BOTS_DIR="$HOME/.claude-bots"
PROJECTS_DIR="$HOME/.claude/projects"

info()  { echo "→ $1"; }
warn()  { echo "⚠ $1"; }
die()   { echo "ERROR: $1" >&2; exit 1; }

# ─── Collect paths to back up ───

PATHS=()

# Bot workspaces
if [[ -d "$CLAUDE_BOTS_DIR/bots" ]]; then
  PATHS+=("$CLAUDE_BOTS_DIR/bots")
  info "Found: bots/"
else
  warn "bots/ not found, skipping"
fi

# State directories (tokens, access.json)
if [[ -d "$CLAUDE_BOTS_DIR/state" ]]; then
  PATHS+=("$CLAUDE_BOTS_DIR/state")
  info "Found: state/"
else
  warn "state/ not found (no bots set up yet)"
fi

# Patched server
if [[ -f "$CLAUDE_BOTS_DIR/shared/server.patched.ts" ]]; then
  PATHS+=("$CLAUDE_BOTS_DIR/shared/server.patched.ts")
  info "Found: shared/server.patched.ts"
else
  warn "shared/server.patched.ts not found, skipping"
fi

# Bot memory directories under ~/.claude/projects/
# Memory paths are derived from workspace absolute paths (slashes → hyphens)
if [[ -d "$PROJECTS_DIR" ]]; then
  ENCODED_PREFIX=$(echo "$CLAUDE_BOTS_DIR/bots" | sed 's|^/||; s|/|-|g')
  FOUND_MEMORY=0
  while IFS= read -r -d '' dir; do
    BASENAME=$(basename "$dir")
    if [[ "$BASENAME" == *"claude-bots"* ]]; then
      PATHS+=("$dir")
      info "Found memory: $BASENAME"
      FOUND_MEMORY=1
    fi
  done < <(find "$PROJECTS_DIR" -maxdepth 1 -type d -print0 2>/dev/null)
  if [[ $FOUND_MEMORY -eq 0 ]]; then
    warn "No bot memory directories found in $PROJECTS_DIR"
  fi
else
  warn "~/.claude/projects/ not found, skipping memory backup"
fi

# ─── Bail if nothing to back up ───

if [[ ${#PATHS[@]} -eq 0 ]]; then
  die "Nothing to back up."
fi

# ─── Create tarball ───

info "Creating backup: $OUTPUT"
tar -czf "$OUTPUT" "${PATHS[@]}"

echo ""
echo "========================================="
echo " Backup complete"
echo "========================================="
echo ""
echo "  File: $OUTPUT"
echo "  Size: $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "To restore:"
echo "  tar -xzf $OUTPUT -C /"
echo ""
warn "state/ contains bot tokens — keep this backup secure."

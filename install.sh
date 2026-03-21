#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# install.sh
# One-line installer for claude-telegram-bots
# Usage: curl -fsSL https://raw.githubusercontent.com/ChannelLabAI/claude-telegram-bots/main/install.sh | bash
# ─────────────────────────────────────────────

INSTALL_DIR="$HOME/.claude-bots"
REPO_URL="https://github.com/ChannelLabAI/claude-telegram-bots.git"

echo "Installing claude-telegram-bots to $INSTALL_DIR..."

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "→ Existing installation found. Pulling latest..."
  cd "$INSTALL_DIR" && git pull --ff-only
else
  # Preserve user data (bot workspaces, patched server) before re-cloning
  BOTS_BACKUP=""
  SHARED_BACKUP=""
  if [[ -d "$INSTALL_DIR/bots" ]]; then
    BOTS_BACKUP="/tmp/claude-bots-bots-backup.$$"
    cp -r "$INSTALL_DIR/bots" "$BOTS_BACKUP"
    echo "→ Preserved bots/ directory"
  fi
  if [[ -f "$INSTALL_DIR/shared/server.patched.ts" ]]; then
    SHARED_BACKUP="/tmp/claude-bots-shared-backup.$$"
    mkdir -p "$SHARED_BACKUP"
    cp "$INSTALL_DIR/shared/server.patched.ts" "$SHARED_BACKUP/server.patched.ts"
    echo "→ Preserved shared/server.patched.ts"
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    echo "→ Backing up existing $INSTALL_DIR to ${INSTALL_DIR}.bak"
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
  fi
  git clone "$REPO_URL" "$INSTALL_DIR"

  # Restore preserved data
  if [[ -n "$BOTS_BACKUP" && -d "$BOTS_BACKUP" ]]; then
    cp -r "$BOTS_BACKUP"/* "$INSTALL_DIR/bots/" 2>/dev/null || true
    rm -rf "$BOTS_BACKUP"
    echo "→ Restored bots/ directory"
  fi
  if [[ -n "$SHARED_BACKUP" && -d "$SHARED_BACKUP" ]]; then
    cp "$SHARED_BACKUP/server.patched.ts" "$INSTALL_DIR/shared/server.patched.ts"
    rm -rf "$SHARED_BACKUP"
    echo "→ Restored shared/server.patched.ts"
  fi
fi

chmod +x "$INSTALL_DIR/setup-claude-bot.sh"
chmod +x "$INSTALL_DIR/patch-server.sh"

# Copy skill to global Claude skills directory so /deploy-bot works from any workspace
mkdir -p "$HOME/.claude/skills"
cp "$INSTALL_DIR/.claude/skills/deploy-bot.md" "$HOME/.claude/skills/deploy-bot.md"
echo "→ Installed /deploy-bot skill"

echo ""
echo "========================================="
echo " Installed to $INSTALL_DIR"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Create a bot with @BotFather on Telegram"
echo "  2. Run: ~/.claude-bots/setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>"
echo ""

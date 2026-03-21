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
  if [[ -d "$INSTALL_DIR" ]]; then
    # Directory exists but isn't a git repo — back up existing files
    echo "→ Backing up existing $INSTALL_DIR to ${INSTALL_DIR}.bak"
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
  fi
  git clone "$REPO_URL" "$INSTALL_DIR"
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

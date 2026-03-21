#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# setup-claude-bot.sh
# Quick setup for a new Claude Code Telegram bot
# Usage: ./setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
# ─────────────────────────────────────────────

CLAUDE_DIR="$HOME/.claude"
CHANNELS_DIR="$CLAUDE_DIR/channels"
RELAY_DIR="$CHANNELS_DIR/telegram-relay"
BOTS_DIR="$HOME/.claude-bots/bots"
SHARED_DIR="$HOME/.claude-bots/shared"
PLUGIN_CACHE="$CLAUDE_DIR/plugins/cache/claude-plugins-official/telegram/0.0.1"
PATCHED_SERVER="$SHARED_DIR/server.patched.ts"

# ─── Helpers ───

die() { echo "ERROR: $1" >&2; exit 1; }
info() { echo "→ $1"; }
warn() { echo "⚠ $1"; }

cleanup_on_fail() {
  if [[ -n "${STATE_DIR:-}" && -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
  fi
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  die "Setup failed. Cleaned up partial files."
}

# ─── Validate args ───

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <BOT_NAME> <BOT_TOKEN>"
  echo ""
  echo "  BOT_NAME   Short name for the bot (e.g. anna, anya, kai)"
  echo "  BOT_TOKEN  Telegram bot token from @BotFather"
  exit 1
fi

BOT_NAME="$1"
BOT_TOKEN="$2"

# Validate bot name (alphanumeric + dash/underscore only)
if [[ ! "$BOT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  die "BOT_NAME must be alphanumeric (with - or _ allowed): $BOT_NAME"
fi

STATE_DIR="$CHANNELS_DIR/$BOT_NAME"
WORK_DIR="$BOTS_DIR/$BOT_NAME"

# ─── Check existing ───

if [[ -d "$STATE_DIR" && -f "$STATE_DIR/access.json" ]]; then
  die "Bot '$BOT_NAME' already exists at $STATE_DIR. Remove it first or pick a different name."
fi

# ─── Verify bot token ───

info "Verifying bot token..."
GETME_RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")

if ! echo "$GETME_RESPONSE" | grep -q '"ok":true'; then
  die "Invalid bot token. Telegram getMe returned: $GETME_RESPONSE"
fi

BOT_USERNAME=$(echo "$GETME_RESPONSE" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
if [[ -z "$BOT_USERNAME" ]]; then
  die "Could not parse bot username from getMe response."
fi

info "Bot verified: @$BOT_USERNAME"

trap cleanup_on_fail ERR

# ─── Create directories ───

info "Creating directories..."
mkdir -p "$STATE_DIR"
mkdir -p "$RELAY_DIR"
mkdir -p "$WORK_DIR/.claude"

# ─── Write .env ───

info "Writing .env..."
cat > "$STATE_DIR/.env" <<EOF
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
EOF
chmod 600 "$STATE_DIR/.env"

# ─── Write access.json (interactive user_id input) ───

echo ""
echo "Enter your Telegram user_id for the allowlist."
echo "Don't know it? Message @userinfobot on Telegram."
echo -n "User ID (or press Enter to skip): "
read -r USER_ID

if [[ -n "$USER_ID" ]]; then
  ALLOW_FROM="\"$USER_ID\""
else
  ALLOW_FROM=""
  warn "No user_id set. You'll need to edit access.json manually later."
fi

info "Writing access.json..."
cat > "$STATE_DIR/access.json" <<EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": [${ALLOW_FROM}],
  "groups": {},
  "pending": {}
}
EOF

# ─── Write settings.json ───
# Global plugin stays enabled; TELEGRAM_STATE_DIR handles isolation per bot.

info "Writing .claude/settings.json..."
cat > "$WORK_DIR/.claude/settings.json" <<EOF
{}
EOF

# ─── Write CLAUDE.md ───

info "Writing CLAUDE.md..."
cat > "$WORK_DIR/CLAUDE.md" <<'TEMPLATE'
# {{BOT_NAME}} workspace rules

## Strict prohibitions
- **NEVER** modify files in any other bot's channel directory
- **NEVER** modify ~/.claude/settings.json
- **NEVER** execute /telegram:configure
- **NEVER** modify files in ~/.claude/plugins/

## Your Telegram config
- Your state directory: {{STATE_DIR}}
- Your MCP config: {{WORK_DIR}}/.mcp.json
- Your Bot: @{{BOT_USERNAME}}
- Only modify files in your own state directory

## Communication
- Use Traditional Chinese
TEMPLATE

# Replace template variables (macOS sed uses -i '', Linux uses -i)
if [[ "$(uname)" == "Darwin" ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi
sed "${SED_INPLACE[@]}" "s|{{BOT_NAME}}|${BOT_NAME}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{STATE_DIR}}|${STATE_DIR}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{WORK_DIR}}|${WORK_DIR}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{BOT_USERNAME}}|${BOT_USERNAME}|g" "$WORK_DIR/CLAUDE.md"

# ─── Patch server.ts ───

if [[ -f "$PATCHED_SERVER" ]]; then
  if [[ -d "$PLUGIN_CACHE" ]]; then
    info "Patching server.ts in plugin cache..."
    cp "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"
  else
    warn "Plugin cache not found at $PLUGIN_CACHE. Install the telegram plugin first, then run patch-server.sh."
  fi
else
  warn "No patched server.ts found at $PATCHED_SERVER."
  warn "If you have a working server.ts with relay support, copy it to: $PATCHED_SERVER"
fi

# ─── Done ───

trap - ERR

echo ""
echo "========================================="
echo " Setup complete: @$BOT_USERNAME ($BOT_NAME)"
echo "========================================="
echo ""
echo "State directory: $STATE_DIR"
echo "Work directory:  $WORK_DIR"
echo ""
echo "To start the bot:"
echo ""
echo "  cd $WORK_DIR && TELEGRAM_STATE_DIR=$STATE_DIR claude --channels plugin:telegram@claude-plugins-official"
echo ""
echo "To add group support, edit $STATE_DIR/access.json and add group IDs to the 'groups' object."
echo ""
warn "After updating Claude Code, re-run: ~/.claude-bots/patch-server.sh"

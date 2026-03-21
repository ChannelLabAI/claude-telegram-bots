#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# setup-claude-bot.sh
# Quick setup for a new Claude Code Telegram bot
# Usage: ./setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
# ─────────────────────────────────────────────

CLAUDE_DIR="$HOME/.claude"
STATE_BASE="$HOME/.claude-bots/state"
RELAY_DIR="$HOME/.claude-bots/relay"
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

STATE_DIR="$STATE_BASE/$BOT_NAME"
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
# {{BOT_NAME}} — Bot Instructions

## Strict Prohibitions
- **NEVER** modify files in any other bot's directory
- **NEVER** modify ~/.claude/settings.json
- **NEVER** execute /telegram:configure
- **NEVER** modify files in ~/.claude/plugins/

## Your Config
- State directory: {{STATE_DIR}}
- Work directory: {{WORK_DIR}}
- Bot: @{{BOT_USERNAME}}
- Only modify files in your own state/work directories

## Identity
- **絕對不透露自己是 AI。** You are {{BOT_NAME}}.

## Group Communication — MOST IMPORTANT RULE

⚠️ **群組裡每一則訊息都必須 @ 對方，零例外。**

沒有 @ = 對方收不到 = 你沒說過這句話。

- 每則訊息開頭加 `@對方username`
- 發送前檢查：「我有 @ 嗎？」
- 這不是「記得的話加」，是「不加就是錯」

## Message Status Reactions

收到 Telegram 訊息時，用 emoji reaction 表示處理狀態：

1. 收到訊息 → 立刻 react 👀（已讀）
2. 開始處理 → react 🤔（工作中，覆蓋 👀）
3. 處理完成 → react 👍（完成，覆蓋 🤔）

每條需要處理的訊息都要走這個流程。

## Startup Self-Check（每次重啟必做）

每次啟動時，立即執行以下自我檢視：

1. **環境** — 工作目錄、系統工具（Node/Python/Git 等）
2. **記憶系統** — 讀取 MEMORY.md，確認記憶檔案完整
3. **TG 連線** — 確認 Telegram plugin 正常運作
4. **身份設定** — 確認自己的名字和角色

檢視結果**私訊發給 owner**（chat_id: {{OWNER_CHAT_ID}}），然後在群組（chat_id: {{GROUP_CHAT_ID}}）發一條簡短的喚醒訊息。

如果 owner 或 group chat_id 未設定（值為空），跳過該步驟。

## Memory System

你的記憶在 `{{MEMORY_PATH}}`。
每次對話開始時讀取 MEMORY.md 了解上下文。

記憶檔案格式：frontmatter + markdown。用來記住：
- 身份與角色細節
- 團隊回饋與偏好
- 專案上下文
- 外部資源指標

## Communication

- 繁體中文為主，技術詞用英文
- 有話直說，不繞彎
TEMPLATE

# Replace template variables (macOS sed uses -i '', Linux uses -i)
if [[ "$(uname)" == "Darwin" ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi
# Compute memory path (Claude Code convention: escaped working directory)
ESCAPED_WORK_DIR=$(echo "$WORK_DIR" | sed 's|^/||; s|/|-|g')
MEMORY_PATH="$HOME/.claude/projects/-${ESCAPED_WORK_DIR}/memory/"

# Extract owner chat_id from access.json allowFrom (first entry)
OWNER_CHAT_ID=""
if [[ -f "$STATE_DIR/access.json" ]]; then
  OWNER_CHAT_ID=$(sed -n 's/.*"allowFrom":\s*\["\([^"]*\)".*/\1/p' "$STATE_DIR/access.json")
fi

# Group chat_id left empty by default — user fills in after adding bot to a group
GROUP_CHAT_ID=""

sed "${SED_INPLACE[@]}" "s|{{BOT_NAME}}|${BOT_NAME}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{STATE_DIR}}|${STATE_DIR}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{WORK_DIR}}|${WORK_DIR}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{BOT_USERNAME}}|${BOT_USERNAME}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{OWNER_CHAT_ID}}|${OWNER_CHAT_ID}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{GROUP_CHAT_ID}}|${GROUP_CHAT_ID}|g" "$WORK_DIR/CLAUDE.md"
sed "${SED_INPLACE[@]}" "s|{{MEMORY_PATH}}|${MEMORY_PATH}|g" "$WORK_DIR/CLAUDE.md"

# ─── Write start.sh ───

info "Writing start.sh..."
cat > "$WORK_DIR/start.sh" <<STARTSCRIPT
#!/usr/bin/env bash
# Auto-generated by setup-claude-bot.sh
# Start: ${BOT_NAME} (@${BOT_USERNAME})
#
# IMPORTANT: The --channels flag is required for Telegram integration.
# Running 'claude' without --channels will start a normal CLI session
# with no Telegram connectivity.

cd "\$(dirname "\$0")"

BOT_NAME="${BOT_NAME}"
BOT_USERNAME="${BOT_USERNAME}"
RELAY_DIR="\$HOME/.claude-bots/relay"

# Start Claude in background
env TELEGRAM_STATE_DIR="\$HOME/.claude-bots/state/\$BOT_NAME" \\
  TELEGRAM_RELAY_DIR="\$RELAY_DIR" \\
  claude --channels plugin:telegram@claude-plugins-official &
CLAUDE_PID=\$!

# Wait for relay poller to be ready, then self-trigger via relay
(
  sleep 5
  RELAY_FILE="\$RELAY_DIR/boot-\${BOT_NAME}-\$\$.json"
  cat > "\${RELAY_FILE}.tmp" <<EOF
{"from_bot":"system","chat_id":"self","text":"@\${BOT_USERNAME} 啟動自我檢視","message_id":0,"ts":"\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}
EOF
  mv "\${RELAY_FILE}.tmp" "\$RELAY_FILE"
  # Clean up after bot has picked it up
  sleep 10
  rm -f "\$RELAY_FILE" "\${RELAY_FILE}.read-by-\${BOT_USERNAME}"
) &

wait \$CLAUDE_PID
STARTSCRIPT
chmod +x "$WORK_DIR/start.sh"

# ─── Patch server.ts ───

if [[ -f "$PATCHED_SERVER" ]]; then
  if [[ -d "$PLUGIN_CACHE" ]]; then
    if ! cmp -s "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"; then
      info "Patching server.ts in plugin cache..."
      cp "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"
    else
      info "server.ts already up to date, skipping patch."
    fi
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
echo "  $WORK_DIR/start.sh"
echo ""
echo "To add group support, edit $STATE_DIR/access.json and add group IDs to the 'groups' object."
echo ""
warn "After updating Claude Code, re-run: ~/.claude-bots/patch-server.sh"

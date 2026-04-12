#!/usr/bin/env bash
# setup-team.sh — 建立新同事的 bot 團隊
# 用法：bash setup-team.sh <teammate_name>
# 例如：bash setup-team.sh alice

set -euo pipefail

# When run with sudo, $HOME becomes /root — use the invoking user's home
SCRIPT_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}" 
SCRIPT_HOME="${SCRIPT_HOME:-$HOME}"

TEAMMATE="${1:-}"
if [[ -z "$TEAMMATE" ]]; then
    echo "Usage: $0 <teammate_name>"
    echo "Example: $0 alice"
    exit 1
fi

TEAMMATE_LOWER=$(echo "$TEAMMATE" | tr '[:upper:]' '[:lower:]')
TEMPLATES_DIR="$SCRIPT_HOME/.claude-bots/shared/templates"
SHARED_HOOKS_DIR="$SCRIPT_HOME/.claude-bots/shared/hooks"

echo "=============================="
echo " 建立 bot 團隊：$TEAMMATE"
echo "=============================="

# 1. 建立 Linux user（如果不存在）
if id "$TEAMMATE_LOWER" &>/dev/null; then
    echo "[SKIP] Linux user '$TEAMMATE_LOWER' 已存在"
    TARGET_HOME=$(eval echo "~$TEAMMATE_LOWER")
else
    echo "[CREATE] 建立 Linux user: $TEAMMATE_LOWER"
    sudo useradd -m -s /bin/bash "$TEAMMATE_LOWER"
    TARGET_HOME="/home/$TEAMMATE_LOWER"
    echo "[OK] 建立完成：$TARGET_HOME"
fi

BOT_BASE="$TARGET_HOME/.claude-bots"

# 2. 建立目錄結構
echo ""
echo "--- 建立目錄結構 ---"
DIRS=(
    "$BOT_BASE/bots/assistant/.claude"
    "$BOT_BASE/bots/builder/.claude"
    "$BOT_BASE/bots/reviewer/.claude"
    "$BOT_BASE/state/assistant"
    "$BOT_BASE/state/builder"
    "$BOT_BASE/state/reviewer"
    "$BOT_BASE/tasks/pending"
    "$BOT_BASE/tasks/in_progress"
    "$BOT_BASE/tasks/review"
    "$BOT_BASE/tasks/rejected"
    "$BOT_BASE/tasks/done"
    "$BOT_BASE/relay"
    "$BOT_BASE/shared/hooks"
)
for d in "${DIRS[@]}"; do
    mkdir -p "$d"
    echo "[OK] $d"
done

# 3. 複製模板 CLAUDE.md
echo ""
echo "--- 複製 CLAUDE.md 模板 ---"
for role in assistant builder reviewer; do
    TEMPLATE="$TEMPLATES_DIR/${role}.CLAUDE.md"
    TARGET="$BOT_BASE/bots/${role}/CLAUDE.md"
    if [[ -f "$TEMPLATE" ]]; then
        # Replace {{BOT_NAME}} with role, {{MEMORY_PATH}} with path placeholder
        sed \
            -e "s|{{BOT_NAME}}|${role}|g" \
            -e "s|{{BOT_DISPLAY_NAME}}|${TEAMMATE} $(echo ${role^})|g" \
            -e "s|{{BOT_USERNAME}}|${TEAMMATE_LOWER}_${role}_bot|g" \
            -e "s|{{OWNER_NAME}}|$TEAMMATE|g" \
            -e "s|{{OWNER_BOT_USERNAME}}|${TEAMMATE_LOWER}_assistant_bot|g" \
            -e "s|{{ASSISTANT_BOT_USERNAME}}|${TEAMMATE_LOWER}_assistant_bot|g" \
            -e "s|{{BUILDER_BOT_USERNAME}}|${TEAMMATE_LOWER}_builder_bot|g" \
            -e "s|{{REVIEWER_BOT_USERNAME}}|${TEAMMATE_LOWER}_reviewer_bot|g" \
            -e "s|{{MEMORY_PATH}}|-home-${TEAMMATE_LOWER}--claude-bots-bots-${role}|g" \
            "$TEMPLATE" > "$TARGET"
        echo "[OK] $TARGET"
    else
        echo "[WARN] 找不到模板：$TEMPLATE"
    fi
done

# 4. 複製 settings.json
echo ""
echo "--- 複製 settings.json ---"
for role in assistant builder reviewer; do
    cp "$TEMPLATES_DIR/settings.json" "$BOT_BASE/bots/${role}/.claude/settings.json"
    echo "[OK] $BOT_BASE/bots/${role}/.claude/settings.json"
done

# 5. 複製 start.sh（填入 BOT_NAME 和 BOT_USERNAME）
echo ""
echo "--- 複製 start.sh ---"
for role in assistant builder reviewer; do
    sed \
        -e "s|{{BOT_NAME}}|${role}|g" \
        -e "s|{{BOT_USERNAME}}|${TEAMMATE_LOWER}_${role}_bot|g" \
        "$TEMPLATES_DIR/start.sh" > "$BOT_BASE/bots/${role}/start.sh"
    chmod +x "$BOT_BASE/bots/${role}/start.sh"
    echo "[OK] $BOT_BASE/bots/${role}/start.sh"
done

# 6. symlink hooks → 指向中央共用目錄（不複製，改一處全員生效）
echo ""
echo "--- symlink hooks ---"
# 刪除 setup 建立的空目錄，換成 symlink
rmdir "$BOT_BASE/shared/hooks" 2>/dev/null || true
if [[ -d "$SHARED_HOOKS_DIR" ]]; then
    ln -sfn "$SHARED_HOOKS_DIR" "$BOT_BASE/shared/hooks"
    echo "[OK] symlink: $BOT_BASE/shared/hooks -> $SHARED_HOOKS_DIR"
else
    echo "[WARN] 找不到 hooks 目錄：$SHARED_HOOKS_DIR"
fi

# 7. 初始化 session.json
echo ""
echo "--- 初始化 session.json ---"
for role in assistant builder reviewer; do
    cat > "$BOT_BASE/state/${role}/session.json" << 'JSON'
{
  "lastActiveAt": "",
  "currentWork": "待命",
  "pendingTasks": [],
  "completedToday": [],
  "blockedOn": null,
  "notes": ""
}
JSON
    echo "[OK] $BOT_BASE/state/${role}/session.json"
done

# 8. 建立 .env 佔位檔
echo ""
echo "--- 建立 .env 佔位檔 ---"
for role in assistant builder reviewer; do
    cat > "$BOT_BASE/state/${role}/.env" << ENV
# ${TEAMMATE} ${role^} Bot — Telegram Token
TELEGRAM_BOT_TOKEN=
TELEGRAM_BOT_USERNAME=${TEAMMATE_LOWER}_${role}_bot
ENV
    echo "[OK] $BOT_BASE/state/${role}/.env"
done

# 9. 建立 Obsidian Vault 基本結構
echo ""
echo "--- 建立 Obsidian Vault ---"
OBSIDIAN_VAULT="$TARGET_HOME/Documents/Obsidian Vault"
for vault_dir in "00-Inbox" "08-Daily" "Templates"; do
    mkdir -p "$OBSIDIAN_VAULT/$vault_dir"
    echo "[OK] $OBSIDIAN_VAULT/$vault_dir"
done

# 10. 設定目錄權限（如果 botadmin 群組存在）
echo ""
echo "--- 設定權限 ---"
if getent group botadmin &>/dev/null; then
    sudo chown -R "$TEAMMATE_LOWER:botadmin" "$BOT_BASE"
    sudo chmod -R g+rw "$BOT_BASE"
    echo "[OK] 設定 botadmin 群組權限"
else
    sudo chown -R "$TEAMMATE_LOWER:$TEAMMATE_LOWER" "$BOT_BASE" 2>/dev/null || chown -R "$TEAMMATE_LOWER" "$BOT_BASE" 2>/dev/null || true
    echo "[SKIP] botadmin 群組不存在，跳過群組設定"
fi

# 10. 輸出 Checklist
echo ""
echo "=============================="
echo " 完成！需要手動填入的項目："
echo "=============================="
echo ""
echo "[ ] 1. 在 BotFather 建立 3 個 bot，填入 token："
echo "       $BOT_BASE/state/assistant/.env → TELEGRAM_BOT_TOKEN="
echo "       $BOT_BASE/state/builder/.env   → TELEGRAM_BOT_TOKEN="
echo "       $BOT_BASE/state/reviewer/.env  → TELEGRAM_BOT_TOKEN="
echo ""
echo "[ ] 2. 更新 BOT_USERNAME（如果 BotFather 給的不同）："
echo "       每個 .env 的 TELEGRAM_BOT_USERNAME"
echo "       每個 start.sh 的 BOT_USERNAME 變數"
echo ""
echo "[ ] 3. 填入 TG 群組 ID（在各 CLAUDE.md 的 chat_id 位置）："
echo "       群組 chat_id（-xxxxxxxxxxxx）"
echo "       owner chat_id（用於私訊回報）"
echo ""
echo "[ ] 4. 更新 shared/hooks/workspace-protect.sh — 加入新 bot 目錄的保護規則"
echo ""
echo "[ ] 5. 安裝 Claude Code 並設定 plugin（claude plugin install ...）"
echo ""
echo "[ ] 6. Obsidian 同步（可選）：安裝 Syncthing，設定雙向同步到同事手機/電腦"
echo "       Vault 路徑：$OBSIDIAN_VAULT"
echo ""
echo "[ ] 7. 啟動測試：cd $BOT_BASE/bots/assistant && bash start.sh"
echo ""

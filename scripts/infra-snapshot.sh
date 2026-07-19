#!/usr/bin/env bash
# infra-snapshot.sh — VPS 全機配置快照入 git（可重建性基線；cron 每日跑）
# 收集：crontab / systemd user units / bot 啟動與權限配置 / shared 關鍵腳本 / pod 配置
# 不收集：secrets（.env.backup 排除）、db、logs
set -euo pipefail
REPO="$HOME/.claude-bots/infra"
mkdir -p "$REPO"
cd "$REPO"
[ -d .git ] || { git init -q; git config user.name pod-ops; git config user.email pod-ops@channellab.local; }

mkdir -p crontab systemd bots shared/bin shared/scripts shared/hooks shared/config pod-system/pods mvp

crontab -l > crontab/crontab.txt 2>/dev/null || true
cp -f "$HOME/.config/systemd/user/"*.service systemd/ 2>/dev/null || true
for d in "$HOME/.config/systemd/user/"*.service.d; do
  [ -d "$d" ] && mkdir -p "systemd/$(basename "$d")" && cp -f "$d"/*.conf "systemd/$(basename "$d")/" 2>/dev/null
done

for b in "$HOME/.claude-bots/bots/"*/; do
  name=$(basename "$b")
  mkdir -p "bots/$name"
  for f in start.sh access.json; do
    [ -f "$b/$f" ] && cp -f "$b/$f" "bots/$name/"
  done
  [ -f "$b/.claude/settings.json" ] && mkdir -p "bots/$name/.claude" && cp -f "$b/.claude/settings.json" "bots/$name/.claude/"
done

cp -rf "$HOME/.claude-bots/shared/bin/"*.sh shared/bin/ 2>/dev/null || true
cp -rf "$HOME/.claude-bots/shared/scripts/"*.{sh,py,ts} shared/scripts/ 2>/dev/null || true
cp -rf "$HOME/.claude-bots/shared/hooks/"* shared/hooks/ 2>/dev/null || true
cp -f "$HOME/.claude-bots/shared/config/"*.yml shared/config/ 2>/dev/null || true
cp -f "$HOME/.claude-bots/pod-system/pods/"*.json pod-system/pods/ 2>/dev/null || true
cp -f "$HOME/.claude-bots/pod-system/"*.{ts,sh} pod-system/ 2>/dev/null || true
cp -f "$HOME/.claude-bots/mvp/"*.{ts,html} mvp/ 2>/dev/null || true
cp -f "$HOME/.claude-bots/bots-active.txt" . 2>/dev/null || true
cp -f "$HOME/.claude-bots/start-bots.sh" . 2>/dev/null || true

# secrets 防呆：任何看起來像 token/key 的檔案不入庫
cat > .gitignore <<'EOF'
**/.env*
**/*token*
**/*secret*
**/users.db*
EOF

if [ ! -f BOOTSTRAP.md ]; then
cat > BOOTSTRAP.md <<'EOF'
# VPS 重建手冊（災難恢復）
1. Debian 12 + bun + node/npm-global(claude) + gcloud auth + sqlite3
2. 還原 ~/.claude-bots 目錄骨架；本 repo 內容按路徑放回
3. secrets：GCP Secret Manager（tg-token-*/anthropic-api-key）＋ claude 訂閱 OAuth 登入
4. crontab: `crontab crontab/crontab.txt`
5. systemd: cp systemd/* ~/.config/systemd/user/ && systemctl --user daemon-reload
   && enable --now pod@{assist-*,builder,designer,reviewer} memocean-dashboard mvp-server
6. 資料庫：memory.db 等從 backups/ 最新快照還原（見 backups/ 命名慣例）
7. 驗證：Diana heartbeat 全綠 + 各 pod polling 零 409 + morning-todo 試發
EOF
fi

git add -A
git commit -qm "infra snapshot $(date -u +%Y-%m-%dT%H:%M)" 2>/dev/null && echo "snapshot committed" || echo "no changes"

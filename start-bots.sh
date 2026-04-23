#!/usr/bin/env bash
# start-bots.sh — 啟動所有 bots-active.txt 裡的 bot（用 tmux，確保有 pseudo-tty）
# 用法：
#   ./start-bots.sh              # 啟動全部 active bots
#   ./start-bots.sh anya anna    # 只啟動指定 bot
#   ./start-bots.sh --restart    # 強制重啟所有（先 kill 再啟）

set -euo pipefail

BOTS_DIR="$HOME/.claude-bots/bots"
ACTIVE_LIST="$HOME/.claude-bots/bots-active.txt"
FORCE_RESTART=false

# Parse args
REQUESTED=()
for arg in "$@"; do
  case "$arg" in
    --restart) FORCE_RESTART=true ;;
    *) REQUESTED+=("$arg") ;;
  esac
done

# Build bot list
if [[ ${#REQUESTED[@]} -gt 0 ]]; then
  BOTS=("${REQUESTED[@]}")
else
  mapfile -t BOTS < <(grep -v '^\s*#' "$ACTIVE_LIST" | grep -v '^\s*$' | awk '{print $1}')
fi

echo "[$(date '+%H:%M:%S')] Starting ${#BOTS[@]} bots via tmux..."

for bot in "${BOTS[@]}"; do
  BOT_START="$BOTS_DIR/$bot/start.sh"

  if [[ ! -f "$BOT_START" ]]; then
    echo "  SKIP $bot — no start.sh found"
    continue
  fi

  if $FORCE_RESTART && tmux has-session -t "$bot" 2>/dev/null; then
    echo "  KILL $bot (--restart)"
    tmux kill-session -t "$bot" 2>/dev/null || true
    sleep 1
  fi

  if tmux has-session -t "$bot" 2>/dev/null; then
    echo "  SKIP $bot — tmux session already exists"
  else
    # 不重定向 stdin/stdout/stderr — 讓 Claude 保有完整 pseudo-tty
    # start.sh 自己的 echo 輸出會留在 tmux session，不收進 log（這樣 isTTY 才 true）
    tmux new-session -d -s "$bot" \
      bash -c "cd '$BOTS_DIR/$bot' && bash start.sh"
    echo "  START $bot"
    sleep 0.5  # 避免同時搶 API 連線
  fi
done

echo "[$(date '+%H:%M:%S')] Done."

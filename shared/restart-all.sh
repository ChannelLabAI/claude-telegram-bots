#!/usr/bin/env bash
# Restart all persistent bots with new Claude Code version

BOTS_DIR="$HOME/.claude-bots/bots"
BOTS=(Bella anna anya caijie-zhuchu chltao interns lilai-fengfeng nicky-builder nicky-zhanglinghe ron-assistant ron-builder ron-reviewer sancai wes-buddy yitang)

echo "=== Stopping all bot sessions ==="
for bot in "${BOTS[@]}"; do
  if tmux has-session -t "$bot" 2>/dev/null; then
    tmux kill-session -t "$bot"
    echo "  killed: $bot"
  fi
done

sleep 2

echo "=== Starting all bot sessions ==="
for bot in "${BOTS[@]}"; do
  BOT_DIR="$BOTS_DIR/$bot"
  if [[ ! -f "$BOT_DIR/start.sh" ]]; then
    echo "  SKIP (no start.sh): $bot"
    continue
  fi
  tmux new-session -d -s "$bot" -c "$BOT_DIR" "bash start.sh"
  echo "  started: $bot"
  sleep 0.5
done

echo "=== Done ==="
tmux ls

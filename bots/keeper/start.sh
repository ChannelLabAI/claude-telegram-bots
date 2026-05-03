#!/bin/bash
SESSION="diana"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Diana already running"
  exit 0
fi
tmux new-session -d -s "$SESSION" -c "/home/oldrabbit/.claude-bots/bots/keeper" \
  "bun run relay-listener.ts >> /home/oldrabbit/.claude-bots/logs/diana-relay.log 2>&1"
echo $! > /home/oldrabbit/.claude-bots/bots/keeper/keeper.pid
echo "Diana started in tmux:$SESSION"

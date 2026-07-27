#!/usr/bin/env bash
# Losing either child is a service failure, so Restart=always recovers both.
set -euo pipefail
root=${DIANA_ROOT:-/home/oldrabbit/.claude-bots}
bun_bin=${DIANA_BUN_BIN:-"$HOME/.bun/bin/bun"}
log=${DIANA_LOG:-"$root/logs/diana-relay.log"}
listener_pid=
watcher_pid=
cleanup() {
  local rc=$?
  [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null || true
  [[ -n "$watcher_pid" ]] && kill "$watcher_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM
cd "$root/bots/keeper"
"$bun_bin" run relay-listener.ts >> "$log" 2>&1 &
listener_pid=$!
bash "$root/bots/keeper/vault-watch.sh" >> "$log" 2>&1 &
watcher_pid=$!
while true; do
  if ! kill -0 "$listener_pid" 2>/dev/null; then
    wait "$listener_pid" || true
    echo "[diana resident] relay listener exited; requesting systemd restart" >> "$log"
    exit 1
  fi
  if ! kill -0 "$watcher_pid" 2>/dev/null; then
    wait "$watcher_pid" || true
    echo "[diana resident] vault watcher exited; requesting systemd restart" >> "$log"
    exit 1
  fi
  sleep 2
done

#!/usr/bin/env bash
# Losing either child is a service failure, so Restart=always recovers both.
set -euo pipefail
root=${DIANA_ROOT:-/home/oldrabbit/.claude-bots}
bun_bin=${DIANA_BUN_BIN:-"$HOME/.bun/bin/bun"}
log=${DIANA_LOG:-"$root/logs/diana-relay.log"}
listener_pid=
watcher_pid=
stop_child_group() {
  local pid=$1
  [[ -n "$pid" ]] || return 0

  # Each child starts in its own session below, so this also reaches its
  # foreground pipeline and any descendants instead of leaving them orphaned.
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  # Do not probe with kill -0 here: it also reports a zombie as alive, which
  # can consume the whole shutdown budget before its parent reaps it.  The
  # fixed grace period is the explicit bound; escalation makes wait safe.
  sleep 1
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  stop_child_group "$listener_pid"
  stop_child_group "$watcher_pid"
  exit "$rc"
}
trap cleanup EXIT INT TERM
cd "$root/bots/keeper"
setsid "$bun_bin" run relay-listener.ts >> "$log" 2>&1 &
listener_pid=$!
setsid bash "$root/bots/keeper/vault-watch.sh" >> "$log" 2>&1 &
watcher_pid=$!
# wait -n reaps the child that ended.  Polling kill -0 alone treats an
# unreaped zombie as alive, which can hide both an immediate exec failure and
# a killed listener forever.
wait -n "$listener_pid" "$watcher_pid" || true
if ! kill -0 "$listener_pid" 2>/dev/null; then
  echo "[diana resident] relay listener exited; requesting systemd restart" >> "$log"
else
  echo "[diana resident] vault watcher exited; requesting systemd restart" >> "$log"
fi
exit 1

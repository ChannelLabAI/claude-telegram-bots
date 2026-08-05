#!/usr/bin/env bash
# Host-only destructive proof. Uses a unique transient user unit; never touches
# keeper-diana.service. Run after applying the reviewed patch.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
unit="keeper-diana-selftest-${$}.service"
supervisor="$root/shared/diana-resident/resident-supervisor.sh"
cleanup() {
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user reset-failed "$unit" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
mkdir -p "$tmp/bots/keeper" "$tmp/home/.bun/bin" "$tmp/logs"
cat > "$tmp/home/.bun/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$DIANA_TEST_LISTENER_PID"
while :; do sleep 1; done
EOF
cat > "$tmp/bots/keeper/vault-watch.sh" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$DIANA_TEST_WATCHER_PID"
cleanup() { :; }
trap cleanup INT TERM EXIT
while :; do sleep 1; done
EOF
chmod +x "$tmp/home/.bun/bin/bun" "$tmp/bots/keeper/vault-watch.sh"
systemd-run --user --unit="$unit" --property=Restart=always --property=RestartSec=1 \
  --setenv="HOME=$tmp/home" --setenv="DIANA_ROOT=$tmp" --setenv="DIANA_LOG=$tmp/logs/diana.log" \
  --setenv="DIANA_TEST_LISTENER_PID=$tmp/listener.pid" --setenv="DIANA_TEST_WATCHER_PID=$tmp/watcher.pid" \
  "$supervisor"
wait_pid_file() { for _ in 1 2 3 4 5 6 7 8; do [[ -s "$1" ]] && return 0; sleep 1; done; return 1; }
restart_proof() {
  local target=$1 before after restarts
  wait_pid_file "$tmp/$target.pid"
  before=$(systemctl --user show "$unit" -p MainPID --value)
  restarts=$(systemctl --user show "$unit" -p NRestarts --value)
  kill -KILL "$(< "$tmp/$target.pid")"
  for _ in 1 2 3 4 5 6 7 8; do
    after=$(systemctl --user show "$unit" -p MainPID --value)
    [[ "$after" != "$before" && "$after" != 0 ]] && break
    sleep 1
  done
  after=$(systemctl --user show "$unit" -p MainPID --value)
  local next_restarts
  next_restarts=$(systemctl --user show "$unit" -p NRestarts --value)
  [[ "$after" != "$before" && "$after" != 0 && "$next_restarts" -gt "$restarts" ]]
  echo "PASS: $target kill MainPID $before -> $after; NRestarts $restarts -> $next_restarts"
}
restart_proof listener
restart_proof watcher
cg=$(systemctl --user show "$unit" -p ControlGroup --value)
for pid_file in "$tmp/listener.pid" "$tmp/watcher.pid"; do
  grep -qx "$(< "$pid_file")" "/sys/fs/cgroup$cg/cgroup.procs"
done
echo "PASS: both restarted children remain in $unit cgroup; cleanup stops only $unit"

#!/usr/bin/env bash
# Offline policy fixture. Host apply must separately kill the live listener.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
unit="$root/shared/systemd/keeper-diana.service"
health="$root/shared/diana-resident/health-check.sh"
supervisor="$root/shared/diana-resident/resident-supervisor.sh"
tmp=$(mktemp -d)
supervisor_pid=
listener_pid=
watcher_pid=
cleanup() {
  [[ -n "$supervisor_pid" ]] && kill "$supervisor_pid" 2>/dev/null || true
  [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null || true
  [[ -n "$watcher_pid" ]] && kill "$watcher_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
wait_for_file() {
  local file=$1
  for _ in 1 2 3 4 5; do
    [[ -s "$file" ]] && return 0
    sleep 1
  done
  return 1
}
assert_supervisor_failure() {
  local label=$1
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$supervisor_pid" 2>/dev/null; then
      if wait "$supervisor_pid"; then
        fail "$label exited successfully"
      fi
      supervisor_pid=
      return 0
    fi
    sleep 1
  done
  fail "$label did not exit"
}
prepare_supervisor_root() {
  local case_root=$1
  mkdir -p "$case_root/bots/keeper" "$case_root/logs" "$case_root/home/.bun/bin"
  cat > "$case_root/home/.bun/bin/bun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$$" > "$DIANA_TEST_LISTENER_PID"
while :; do sleep 1; done
EOF
  cat > "$case_root/bots/keeper/vault-watch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$$" > "$DIANA_TEST_WATCHER_PID"
while :; do sleep 1; done
EOF
  chmod +x "$case_root/home/.bun/bin/bun" "$case_root/bots/keeper/vault-watch.sh"
}
run_supervisor_case() {
  local case_root=$1
  HOME="$case_root/home" DIANA_ROOT="$case_root" DIANA_LOG="$case_root/logs/diana-relay.log" \
    DIANA_TEST_LISTENER_PID="$case_root/listener.pid" DIANA_TEST_WATCHER_PID="$case_root/watcher.pid" \
    "$supervisor" &
  supervisor_pid=$!
  wait_for_file "$case_root/listener.pid" || fail 'listener stub was not started'
  wait_for_file "$case_root/watcher.pid" || fail 'vault watcher stub was not started'
  listener_pid=$(< "$case_root/listener.pid")
  watcher_pid=$(< "$case_root/watcher.pid")
}
grep -qx 'Type=simple' "$unit" && grep -qx 'Restart=always' "$unit" && pass 'restart policy replaces oneshot false-green'
grep -qx 'MemoryHigh=1200M' "$unit" && grep -qx 'MemoryMax=2000M' "$unit" && pass 'resident memory limits present'
prepare_supervisor_root "$tmp/listener-case"
run_supervisor_case "$tmp/listener-case"
pass 'supervisor starts listener and vault watcher stubs'
kill "$listener_pid"
assert_supervisor_failure 'supervisor after listener death'
listener_pid= watcher_pid=
pass 'listener death triggers non-zero supervisor exit'
prepare_supervisor_root "$tmp/watcher-case"
run_supervisor_case "$tmp/watcher-case"
kill "$watcher_pid"
assert_supervisor_failure 'supervisor after vault watcher death'
listener_pid= watcher_pid=
pass 'vault watcher death triggers non-zero supervisor exit'
prepare_supervisor_root "$tmp/bad-bun-case"
bad_supervisor="$tmp/bad-bun-case/resident-supervisor-wrong-bun.sh"
sed 's|"\$HOME/.bun/bin/bun"|"/does/not/exist"|' "$supervisor" > "$bad_supervisor"
chmod +x "$bad_supervisor"
HOME="$tmp/bad-bun-case/home" DIANA_ROOT="$tmp/bad-bun-case" \
  DIANA_LOG="$tmp/bad-bun-case/logs/diana-relay.log" "$bad_supervisor" &
supervisor_pid=$!
assert_supervisor_failure 'supervisor with a deliberately invalid Bun path'
pass 'deliberately wrong Bun path fails the executable supervisor check'
mkdir -p "$tmp/cgroup/keeper-diana.service" "$tmp/proc/4242"
printf '4242\n' > "$tmp/cgroup/keeper-diana.service/cgroup.procs"
printf 'bun\0relay-listener.ts\0' > "$tmp/proc/4242/cmdline"
printf '{"last_run":"2026-07-27T04:00:00Z"}\n' > "$tmp/state.json"
printf '#!/usr/bin/env bash\nprintf "/keeper-diana.service\\n"\n' > "$tmp/systemctl"; chmod +x "$tmp/systemctl"
DIANA_BATCH_STATE="$tmp/state.json" DIANA_SYSTEMCTL_BIN="$tmp/systemctl" DIANA_CGROUP_ROOT="$tmp/cgroup" DIANA_PROC_ROOT="$tmp/proc" "$health" | grep -q 'listener_in_cgroup=1'
pass 'health requires batch state plus listener in unit cgroup'
rm "$tmp/proc/4242/cmdline"
if DIANA_BATCH_STATE="$tmp/state.json" DIANA_SYSTEMCTL_BIN="$tmp/systemctl" DIANA_CGROUP_ROOT="$tmp/cgroup" DIANA_PROC_ROOT="$tmp/proc" "$health" >/dev/null 2>&1; then
  echo 'FAIL: health falsely passed without listener' >&2; exit 1
fi
pass 'health rejects false-green cgroup without listener'

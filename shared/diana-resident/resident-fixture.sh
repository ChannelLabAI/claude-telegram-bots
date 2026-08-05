#!/usr/bin/env bash
# Offline policy fixture. Host apply must separately kill the live listener.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
unit="$root/shared/systemd/keeper-diana.service"
health="$root/shared/diana-resident/health-check.sh"
supervisor="$root/shared/diana-resident/resident-supervisor.sh"
run_action="$root/shared/diana-resident/run-action.sh"
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
if [[ "${1:-}" == run && "${2:-}" == *authorize-action.ts ]]; then
  [[ "${DIANA_TEST_AUTHORIZE_ALLOW:-0}" == 1 ]] || exit 2
  exit 0
fi
echo "$$" > "$DIANA_TEST_LISTENER_PID"
while :; do sleep 1; done
EOF
  cat > "$case_root/bots/keeper/vault-watch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$$" > "$DIANA_TEST_WATCHER_PID"
cleanup() { :; }
trap cleanup INT TERM EXIT
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
kill -KILL "$watcher_pid"
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
# Exercise the actual B1 shell entry point, not just authorize() in isolation.
# The Bun stub accepts authorize-action.ts only when explicitly enabled, proving
# that run-action uses DIANA_BUN_BIN and reaches the authorization subprocess.
run_action_root="$tmp/run-action-case"
prepare_supervisor_root "$run_action_root"
# Do not inject DIANA_BUN_BIN here: this exercises the production fallback
# resolution from HOME, which must stay in lockstep with the supervisor.
if ! HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 \
  DIANA_OPS_AUDIT_DIR="$run_action_root/audit" DIANA_OPS_EXECUTE=0 "$run_action" clean_disk; then
  fail 'run-action default Bun path did not reach the dry-run authorization path'
fi
grep -q 'action=clean_disk result=DRY_RUN reason=explicit_execute_required' "$run_action_root/audit/actions.log" || fail 'run-action dry-run did not audit DRY_RUN'
pass 'run-action resolves default Bun path from HOME then audits dry-run'
# Execution is now the default.  The fake systemctl and pod manifest keep this
# proof wholly inside the fixture while exercising the real allowlist checks.
mkdir -p "$run_action_root/pod-system/pods" "$run_action_root/bin"
printf '{}\n' > "$run_action_root/pod-system/pods/assist-anya.json"
cat > "$run_action_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DIANA_TEST_SYSTEMCTL_LOG"
EOF
chmod +x "$run_action_root/bin/systemctl"
HOME="$run_action_root/home" PATH="$run_action_root/bin:$PATH" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 \
  DIANA_OPS_AUDIT_DIR="$run_action_root/execute-audit" DIANA_TEST_SYSTEMCTL_LOG="$run_action_root/systemctl.log" "$run_action" restart_approved_pod assist-anya
grep -qx -- '--user restart pod@assist-anya.service' "$run_action_root/systemctl.log" || fail 'assist-anya restart did not reach isolated systemctl'
grep -q 'action=restart_approved_pod result=OK reason=pod@assist-anya mode=execute' "$run_action_root/execute-audit/actions.log" || fail 'default execute mode was not audited as OK'
pass 'run-action defaults to execute and authorizes assist-anya in isolation'
missing_bun_root="$tmp/run-action-missing-bun-case"
mkdir -p "$missing_bun_root"
if HOME="$missing_bun_root/home" DIANA_ROOT="$missing_bun_root" DIANA_OPS_AUDIT_DIR="$missing_bun_root/audit" DIANA_OPS_EXECUTE=0 "$run_action" clean_disk >/dev/null 2>&1; then
  fail 'run-action falsely passed with no default Bun executable'
fi
grep -q 'action=clean_disk result=DENY reason=authorization_rejected' "$missing_bun_root/audit/actions.log" || fail 'run-action missing default Bun was not audited as DENY'
pass 'run-action fails closed when HOME has no Bun and DIANA_BUN_BIN is unset'
# A live pod process is never eligible: the orphan action needs all three
# positive proofs (dead parent, outside pod@ cgroup, stale activity marker).
orphan_root="$tmp/orphan-case"; mkdir -p "$orphan_root/proc/4242" "$orphan_root/activity" "$orphan_root/audit"
printf 'Name:\tbun\nPPid:\t1\n' > "$orphan_root/proc/4242/status"
printf '0::/user.slice/pod@assist-anya.service\n' > "$orphan_root/proc/4242/cgroup"
touch -d '@0' "$orphan_root/activity/4242.last_activity"
touch -d '@1000' "$orphan_root/activity/4242.last_sampled"
if HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
  DIANA_OPS_AUDIT_DIR="$orphan_root/audit" DIANA_OPS_CIRCUIT_DB="$orphan_root/pod-memory.db" DIANA_PROC_ROOT="$orphan_root/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$orphan_root/activity" DIANA_NOW_EPOCH=1000 "$run_action" terminate_verified_orphan 4242 >/dev/null 2>&1; then
  fail 'healthy pod process was misclassified as orphan'
fi
grep -q 'action=terminate_verified_orphan result=DENY reason=parent_still_alive\|action=terminate_verified_orphan result=DENY reason=belongs_to_pod_cgroup' "$orphan_root/audit/actions.log" || fail 'healthy pod process denial was not audited'
pass 'orphan action rejects a healthy pod process'
printf '0::/user.slice/keeper-diana.service\n' > "$orphan_root/proc/4242/cgroup"
HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
  DIANA_OPS_AUDIT_DIR="$orphan_root/audit-positive" DIANA_OPS_CIRCUIT_DB="$orphan_root/positive-memory.db" DIANA_PROC_ROOT="$orphan_root/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$orphan_root/activity" DIANA_NOW_EPOCH=1000 "$run_action" terminate_verified_orphan 4242
grep -q 'action=terminate_verified_orphan result=DRY_RUN reason=verified_orphan' "$orphan_root/audit-positive/actions.log" || fail 'verified orphan did not reach dry-run'
pass 'orphan action requires the complete positive evidence intersection'
touch -d '@999' "$orphan_root/activity/4242.last_activity"
touch -d '@1000' "$orphan_root/activity/4242.last_sampled"
if HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
  DIANA_OPS_AUDIT_DIR="$orphan_root/audit-fresh" DIANA_OPS_CIRCUIT_DB="$orphan_root/fresh-memory.db" DIANA_PROC_ROOT="$orphan_root/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$orphan_root/activity" DIANA_NOW_EPOCH=1000 "$run_action" terminate_verified_orphan 4242 >/dev/null 2>&1; then
  fail 'fresh activity evidence was wrongly treated as idle enough'
fi
grep -q 'action=terminate_verified_orphan result=DENY reason=not_idle_long_enough' "$orphan_root/audit-fresh/actions.log" || fail 'fresh-evidence denial was not audited'
pass 'orphan action still blocks when evidence is too fresh to be idle'
touch -d '@0' "$orphan_root/activity/4242.last_activity"
touch -d '@0' "$orphan_root/activity/4242.last_sampled"
if HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
  DIANA_OPS_AUDIT_DIR="$orphan_root/audit-stale-sampler" DIANA_OPS_CIRCUIT_DB="$orphan_root/stale-sampler-memory.db" DIANA_PROC_ROOT="$orphan_root/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$orphan_root/activity" DIANA_NOW_EPOCH=1000 "$run_action" terminate_verified_orphan 4242 >/dev/null 2>&1; then
  fail 'stale orphan sampler was wrongly trusted as idle evidence'
fi
grep -q 'action=terminate_verified_orphan result=DENY reason=sampler_stale' "$orphan_root/audit-stale-sampler/actions.log" || fail 'stale sampler denial was not audited'
pass 'orphan action fails closed when the activity sampler is stale'
# The action circuit records every attempt in SQLite.  Three failed attempts
# are allowed; the fourth is blocked, and a fresh process sees the same state.
circuit_root="$tmp/circuit-case"; mkdir -p "$circuit_root"
for now in 1 2 3; do
  HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
    DIANA_OPS_AUDIT_DIR="$circuit_root/audit" DIANA_OPS_CIRCUIT_DB="$circuit_root/memory.db" DIANA_NOW_EPOCH="$now" "$run_action" clean_disk >/dev/null 2>&1 || fail 'circuit unexpectedly blocked a threshold attempt'
done
if HOME="$run_action_root/home" DIANA_ROOT="$run_action_root" DIANA_TEST_AUTHORIZE_ALLOW=1 DIANA_OPS_EXECUTE=0 \
  DIANA_OPS_AUDIT_DIR="$circuit_root/audit" DIANA_OPS_CIRCUIT_DB="$circuit_root/memory.db" DIANA_NOW_EPOCH=4 "$run_action" clean_disk >/dev/null 2>&1; then
  fail 'circuit did not block the fourth action attempt'
fi
grep -q 'action=clean_disk result=DENY reason=circuit_open' "$circuit_root/audit/actions.log" || fail 'circuit open was not audited'
pass 'action circuit persists attempts and blocks retry loops'
# Activity evidence is written only after the kernel CPU ticks change.  The
# first sample creates a baseline; the second proves a real activity signal.
activity_sample="$tmp/activity-sample"; mkdir -p "$activity_sample/proc/5151" "$activity_sample/activity"
printf '5151 (worker) S 1 1 1 0 0 0 0 0 0 0 0 0 7 9\n' > "$activity_sample/proc/5151/stat"
HEARTBEAT_TEST_ORPHAN_ACTIVITY=1 DIANA_ORPHAN_PROC_ROOT="$activity_sample/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$activity_sample/activity" \
  "$HOME/.bun/bin/bun" run "$root/shared/scripts/heartbeat.ts"
[[ ! -e "$activity_sample/activity/5151.last_activity" ]] || fail 'initial CPU sample falsely created activity evidence'
[[ -s "$activity_sample/activity/5151.last_sampled" ]] || fail 'initial CPU sample did not record sampler freshness'
printf '5151 (worker) S 1 1 1 2 3 4 5 6 7 8 9 10 11 12 13\n' > "$activity_sample/proc/5151/stat"
HEARTBEAT_TEST_ORPHAN_ACTIVITY=1 DIANA_ORPHAN_PROC_ROOT="$activity_sample/proc" DIANA_ORPHAN_ACTIVITY_ROOT="$activity_sample/activity" \
  "$HOME/.bun/bin/bun" run "$root/shared/scripts/heartbeat.ts"
[[ -s "$activity_sample/activity/5151.last_activity" ]] || fail 'changed CPU ticks did not create activity evidence'
pass 'orphan activity sampler writes evidence only for real CPU activity'
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

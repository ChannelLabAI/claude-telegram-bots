#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/fatq-heartbeat-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { if "$@"; then pass "$*"; else fail "$*"; fi; }

make_cron_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$ROOT/shared/bin/fatq-dispatch-cron.sh" "$dir/fatq-dispatch-cron.sh"
  cat > "$dir/fatq-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${DISPATCH_PROBE:-}" ]] && touch "$DISPATCH_PROBE"
echo "[$(TZ=Asia/Taipei date +%Y-%m-%dT%H:%M:%S+08:00)] scan start (dry_run=0, root=x, relay=y)"
echo "[$(TZ=Asia/Taipei date +%Y-%m-%dT%H:%M:%S+08:00)] scan done: 0 dispatched, 0 nudged, 0 escalated, 0 completion_notified, 0 reject_notified, 0 skipped"
exit "${DISPATCH_EXIT:-0}"
EOF
  chmod +x "$dir/"*.sh
}

lock="$TMPROOT/dispatch.lock"
fixture="$TMPROOT/lock-fixture"
make_cron_fixture "$fixture"
(
  exec 8>"$lock"
  /usr/bin/flock 8
  echo held > "$TMPROOT/held"
  while [[ ! -e "$TMPROOT/release" ]]; do sleep 0.02; done
) &
holder=$!
while [[ ! -e "$TMPROOT/held" ]]; do sleep 0.02; done
FATQ_DISPATCH_LOCK="$lock" bash "$fixture/fatq-dispatch-cron.sh" > "$TMPROOT/lock.out" 2>&1
lock_rc=$?
touch "$TMPROOT/release"
wait "$holder"
check test "$lock_rc" -ne 0
check grep -q 'source=cron-fallback outcome=skipped-lock-held' "$TMPROOT/lock.out"
echo "lock-held forward rc=$lock_rc: $(cat "$TMPROOT/lock.out")"

mutant="$TMPROOT/mutant"
make_cron_fixture "$mutant"
sed -i '/round_log skipped-lock-held/d' "$mutant/fatq-dispatch-cron.sh"
(
  exec 8>"$lock"
  /usr/bin/flock 8
  echo held > "$TMPROOT/held2"
  while [[ ! -e "$TMPROOT/release2" ]]; do sleep 0.02; done
) &
holder=$!
while [[ ! -e "$TMPROOT/held2" ]]; do sleep 0.02; done
FATQ_DISPATCH_LOCK="$lock" bash "$mutant/fatq-dispatch-cron.sh" > "$TMPROOT/mutant.out" 2>&1
mutant_rc=$?
touch "$TMPROOT/release2"
wait "$holder"
if grep -q 'source=cron-fallback outcome=skipped-lock-held' "$TMPROOT/mutant.out"; then
  fail 'lock-held mutant unexpectedly passed'
else
  pass 'lock-held mutant rejected'
fi
echo "lock-held mutant rc=$mutant_rc output=$(cat "$TMPROOT/mutant.out")"

snap="$TMPROOT/snapshot-fixture"
make_cron_fixture "$snap"
mkdir -p "$TMPROOT/fake-bin"
cat > "$TMPROOT/fake-bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 37
EOF
chmod +x "$TMPROOT/fake-bin/ps"
PATH="$TMPROOT/fake-bin:$PATH" FATQ_DISPATCH_LOCK="$TMPROOT/snapshot.lock" DISPATCH_PROBE="$TMPROOT/dispatcher-ran" bash "$snap/fatq-dispatch-cron.sh" > "$TMPROOT/snapshot.out" 2>&1
snapshot_rc=$?
check test "$snapshot_rc" -eq 37
check grep -q 'source=cron-fallback outcome=snapshot-failed stage=ps-pipeline exit=37' "$TMPROOT/snapshot.out"
check test ! -e "$TMPROOT/dispatcher-ran"
echo "snapshot-failed rc=$snapshot_rc: $(tr '\n' ' ' < "$TMPROOT/snapshot.out")"

normal="$TMPROOT/normal-fixture"
make_cron_fixture "$normal"
FATQ_DISPATCH_LOCK="$TMPROOT/normal.lock" bash "$normal/fatq-dispatch-cron.sh" > "$TMPROOT/normal.out" 2>&1
normal_rc=$?
check test "$normal_rc" -eq 0
if grep -q 'scan start (dry_run=0, root=x, relay=y)' "$TMPROOT/normal.out" && grep -q 'scan done: 0 dispatched, 0 nudged, 0 escalated, 0 completion_notified, 0 reject_notified, 0 skipped' "$TMPROOT/normal.out"; then
  pass 'normal scan start/done format preserved'
else
  fail 'normal scan start/done format preserved'
fi
check grep -q 'source=cron-fallback outcome=dispatcher-exit-zero exit=0' "$TMPROOT/normal.out"

DISPATCH_EXIT=23 FATQ_DISPATCH_LOCK="$TMPROOT/child-fail.lock" bash "$normal/fatq-dispatch-cron.sh" > "$TMPROOT/child-fail.out" 2>&1
child_rc=$?
check test "$child_rc" -eq 23
check grep -q 'source=cron-fallback outcome=dispatcher-exit-nonzero exit=23' "$TMPROOT/child-fail.out"

cron_log="$TMPROOT/cron.log"
watch_log="$TMPROOT/watch.log"
: > "$cron_log"
cat > "$watch_log" <<'EOF'
[2026-08-27T18:20:00+08:00] scan start (dry_run=0, root=x, relay=y)
[2026-08-27T18:20:04+08:00] scan done: 0 dispatched, 0 nudged, 0 escalated, 0 completion_notified, 0 reject_notified, 0 skipped
EOF
bash "$ROOT/shared/bin/fatq-dispatch-round-audit.sh" --hours 1 --now 2026-08-27T18:40:00+08:00 --cron-log "$cron_log" --watch-log "$watch_log" > "$TMPROOT/audit-covered.out"
covered_rc=$?
check test "$covered_rc" -eq 0
check grep -q 'COVERED window=2026-08-27T18:07:00+08:00 source=event-watch' "$TMPROOT/audit-covered.out"
echo 'audit covered:'
cat "$TMPROOT/audit-covered.out"

# The audit promises at least one complete reconciliation per :07-anchored
# hourly window, not one close to :07. Tightening this :30 case to GAP would
# require a new SLO and task; it must not be done by changing this assertion.
cat > "$watch_log" <<'EOF'
[2026-08-27T15:30:00+08:00] scan start (dry_run=0, root=x, relay=y)
[2026-08-27T15:30:04+08:00] scan done: 0 dispatched, 0 nudged, 0 escalated, 0 completion_notified, 0 reject_notified, 0 skipped
EOF
bash "$ROOT/shared/bin/fatq-dispatch-round-audit.sh" --hours 1 --now 2026-08-27T15:50:00+08:00 --cron-log "$cron_log" --watch-log "$watch_log" > "$TMPROOT/audit-hourly-slo.out"
hourly_slo_rc=$?
check test "$hourly_slo_rc" -eq 0
check grep -q 'COVERED window=2026-08-27T15:07:00+08:00 source=event-watch' "$TMPROOT/audit-hourly-slo.out"
echo 'audit hourly SLO at :30:'
cat "$TMPROOT/audit-hourly-slo.out"

: > "$watch_log"
bash "$ROOT/shared/bin/fatq-dispatch-round-audit.sh" --hours 2 --now 2026-08-27T18:40:00+08:00 --cron-log "$cron_log" --watch-log "$watch_log" > "$TMPROOT/audit-gap.out"
gap_rc=$?
check test "$gap_rc" -ne 0
check grep -q 'GAP window=2026-08-27T17:07:00+08:00' "$TMPROOT/audit-gap.out"
check grep -q 'GAP window=2026-08-27T18:07:00+08:00' "$TMPROOT/audit-gap.out"
echo 'audit gaps:'
cat "$TMPROOT/audit-gap.out"

# A zero-result assertion must prove its query is discriminating (AC7).
if grep -q '^GAP ' "$TMPROOT/audit-covered.out"; then fail 'covered output has zero gaps'; else pass 'covered output has zero gaps'; fi
if grep -q '^GAP ' "$TMPROOT/audit-gap.out"; then pass 'reverse sample makes gap query non-zero'; else fail 'reverse sample makes gap query non-zero'; fi

# Installer is idempotent and removes the silent outer flock.
fake_crontab="$TMPROOT/fake-crontab"
state="$TMPROOT/crontab.state"
cat > "$fake_crontab" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then cat "$CRONTAB_STATE" 2>/dev/null || true; else cat > "$CRONTAB_STATE"; fi
EOF
chmod +x "$fake_crontab"
printf '%s\n' '7 * * * * /usr/bin/flock -n /tmp/cron-fatq-dispatch.lock bash /home/oldrabbit/.claude-bots/shared/bin/fatq-dispatch-cron.sh >> /home/oldrabbit/.claude-bots/logs/fatq-dispatch.log 2>&1' > "$state"
CRONTAB_BIN="$fake_crontab" CRONTAB_STATE="$state" bash "$ROOT/shared/bin/install-fatq-dispatch-cron.sh"
CRONTAB_BIN="$fake_crontab" CRONTAB_STATE="$state" bash "$ROOT/shared/bin/install-fatq-dispatch-cron.sh"
check test "$(grep -c 'fatq-dispatch-cron.sh' "$state")" -eq 1
if grep -q 'flock.*fatq-dispatch-cron.sh' "$state"; then fail 'installer retained outer flock'; else pass 'installer moved flock into observable wrapper'; fi

baseline="$TMPROOT/baseline.out"
bash "$ROOT/shared/tests/fatq-dispatch-test.sh" > "$baseline" 2>&1
baseline_rc=$?
check test "$baseline_rc" -eq 0
if grep -q 'RESULT: 128 pass, 0 fail' "$baseline"; then pass 'baseline 128 pass / 0 fail'; else fail 'baseline 128 pass / 0 fail'; tail -20 "$baseline"; fi

echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${POD_MOVE_SCRIPT_UNDER_TEST:-${SCRIPT_DIR}/../bin/pod-move.sh}"
PRODUCTION_PODS_DIR="/home/oldrabbit/.claude-bots/pod-system/pods"

pass_count=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $*"
}

production_pods_snapshot() {
  if [[ ! -d "$PRODUCTION_PODS_DIR" ]]; then
    echo "__production_pods_missing__"
    return 0
  fi
  find "$PRODUCTION_PODS_DIR" -maxdepth 1 -type f -name '*.json' -print | sort | while IFS= read -r file; do
    sha256sum "$file"
  done
}

assert_production_pods_unchanged() {
  local before="$1" after
  after="$(production_pods_snapshot)"
  [[ "$before" == "$after" ]] || fail "production pods directory changed during fixture test"
}

make_fixture() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/root/pod-system/pods" "$FIXTURE/root/pod-system/pods-db" "$FIXTURE/root/logs" "$FIXTURE/bin"
  cat >"$FIXTURE/root/pod-system/pods/builder.json" <<'JSON'
{
  "podName": "builder",
  "bots": [
    {
      "name": "alpha",
      "username": "Alpha_bot",
      "tokenSecret": "tg-token-alpha",
      "dir": "/tmp/alpha",
      "model": "claude-sonnet-5"
    },
    {
      "name": "beta",
      "username": "Beta_bot",
      "tokenSecret": "tg-token-beta",
      "dir": "/tmp/beta",
      "model": "claude-sonnet-5"
    }
  ],
  "maxConcurrent": 3,
  "dbPath": "__FIXTURE__/root/pod-system/pods-db/gateway-builder.db"
}
JSON
  sed -i "s#__FIXTURE__#$FIXTURE#g" "$FIXTURE/root/pod-system/pods/builder.json"
  cat >"$FIXTURE/root/pod-system/pods/assist-beta.json" <<'JSON'
{
  "podName": "assist-beta",
  "bots": [],
  "maxConcurrent": 2,
  "dbPath": "__FIXTURE__/root/pod-system/pods-db/gateway-assist-beta.db"
}
JSON
  sed -i "s#__FIXTURE__#$FIXTURE#g" "$FIXTURE/root/pod-system/pods/assist-beta.json"
  sqlite3 "$FIXTURE/root/pod-system/pods-db/gateway-builder.db" \
    "create table tasks(status text, started_at text, finished_at text);"
  sqlite3 "$FIXTURE/root/pod-system/pods-db/gateway-assist-beta.db" \
    "create table tasks(status text, started_at text, finished_at text);"
  cat >"$FIXTURE/bin/systemctl-mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$POD_MOVE_MOCK_CALLS"
unit="${*: -1}"
pod="${unit#*@}"
pod="${pod%.service}"
case "$*" in
  *"enable --now"*)
    if [[ "${POD_MOVE_FAIL_ENABLE:-0}" == "1" ]]; then
      exit 42
    fi
    touch "$(printf "$POD_MOVE_HEARTBEAT_TEMPLATE" "$pod")"
    echo "secrets loaded: ${POD_MOVE_TEST_BOT:-alpha}" >>"$(printf "$POD_MOVE_LOG_TEMPLATE" "$pod")"
    ;;
  restart*)
    if [[ "${POD_MOVE_FAIL_SOURCE_RESTART:-0}" == "1" && "$pod" == "builder" && ! -f "$POD_MOVE_ROLLBACK_MARK" ]]; then
      exit 44
    fi
    if [[ "${POD_MOVE_FAIL_ROLLBACK_RESTART:-0}" == "1" && "$pod" == "builder" && -f "$POD_MOVE_ROLLBACK_MARK" ]]; then
      exit 43
    fi
    touch "$(printf "$POD_MOVE_HEARTBEAT_TEMPLATE" "$pod")"
    ;;
  stop*)
    touch "$POD_MOVE_ROLLBACK_MARK"
    ;;
  is-active*|is-enabled*)
    exit 0
    ;;
esac
MOCK
  chmod +x "$FIXTURE/bin/systemctl-mock"
  cat >"$FIXTURE/bin/mm_post" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$POD_MOVE_MOCK_ALERTS"
MOCK
  chmod +x "$FIXTURE/bin/mm_post"

  export POD_MOVE_ROOT="$FIXTURE/root"
  export POD_MOVE_GATEWAY_DIR="$FIXTURE/root/pod-system"
  export POD_MOVE_PODS_DIR="$FIXTURE/root/pod-system/pods"
  export POD_MOVE_LOGS_DIR="$FIXTURE/root/logs"
  export POD_MOVE_AUDIT_LOG="$FIXTURE/root/logs/pod-moves.jsonl"
  export POD_MOVE_LOCK_FILE="$FIXTURE/root/pod-move.lock"
  export POD_MOVE_SYSTEMCTL_CMD="$FIXTURE/bin/systemctl-mock"
  export POD_MOVE_MM_POST_CMD="$FIXTURE/bin/mm_post"
  export POD_MOVE_MOCK_CALLS="$FIXTURE/calls.log"
  export POD_MOVE_MOCK_ALERTS="$FIXTURE/alerts.log"
  export POD_MOVE_ROLLBACK_MARK="$FIXTURE/rollback.mark"
  export POD_MOVE_HEARTBEAT_TEMPLATE="$FIXTURE/root/pod-system/heartbeat-%s.txt"
  export POD_MOVE_LOG_TEMPLATE="$FIXTURE/root/pod-system/gateway-%s.log"
  export POD_MOVE_DB_PATH_TEMPLATE="$FIXTURE/root/pod-system/pods-db/gateway-%s.db"
  export POD_MOVE_SKIP_SELF_CHECK=1
  export POD_MOVE_DRAIN_TIMEOUT_SEC=5
  export POD_MOVE_DRAIN_POLL_SEC=1
  export POD_MOVE_VERIFY_TIMEOUT_SEC=2
  [[ "$POD_MOVE_PODS_DIR" != "$PRODUCTION_PODS_DIR" ]] || fail "fixture points at production pods dir"
  : >"$POD_MOVE_MOCK_CALLS"
  : >"$POD_MOVE_MOCK_ALERTS"
}

run_pod_move() {
  bash "$SCRIPT_UNDER_TEST" "$@"
}

test_dry_run_zero_mutation() {
  make_fixture
  before="$(sha256sum "$POD_MOVE_PODS_DIR/builder.json" "$POD_MOVE_PODS_DIR/assist-beta.json")"
  run_pod_move alpha assist-alpha >/tmp/pod-move-dry.out
  after="$(sha256sum "$POD_MOVE_PODS_DIR/builder.json" "$POD_MOVE_PODS_DIR/assist-beta.json")"
  [[ "$before" == "$after" ]] || fail "dry-run mutated config"
  [[ ! -f "$POD_MOVE_PODS_DIR/assist-alpha.json" ]] || fail "dry-run created target pod"
  grep -q '"result":"dry_run"' "$POD_MOVE_AUDIT_LOG" || fail "dry-run audit missing"
  [[ ! -s "$POD_MOVE_MOCK_CALLS" ]] || fail "dry-run called systemctl"
  pass "dry-run performs zero mutation and audits"
}

test_running_task_refuses() {
  make_fixture
  prod_before="$(production_pods_snapshot)"
  sqlite3 "$FIXTURE/root/pod-system/pods-db/gateway-builder.db" \
    "insert into tasks(status,started_at,finished_at) values('running','2026-07-11T00:00:00',null);"
  if run_pod_move alpha assist-alpha --execute --confirm=alpha >/tmp/pod-move-running.out 2>&1; then
    fail "running task move unexpectedly succeeded"
  fi
  grep -q 'running task' /tmp/pod-move-running.out || fail "running task refusal not explained"
  [[ ! -s "$POD_MOVE_MOCK_CALLS" ]] || fail "running task refusal called systemctl"
  assert_production_pods_unchanged "$prod_before"
  pass "running task blocks move before mutation"
}

test_drain_waits_and_moves() {
  make_fixture
  prod_before="$(production_pods_snapshot)"
  sqlite3 "$FIXTURE/root/pod-system/pods-db/gateway-builder.db" \
    "insert into tasks(status,started_at,finished_at) values('running','2026-07-11T00:00:00',null);"
  ( sleep 1; sqlite3 "$FIXTURE/root/pod-system/pods-db/gateway-builder.db" "update tasks set status='done', finished_at='2026-07-11T00:00:01';" ) &
  run_pod_move alpha assist-alpha --execute --drain --confirm=alpha >/tmp/pod-move-drain.out
  wait
  jq -e '.bots[] | select(.name=="alpha")' "$POD_MOVE_PODS_DIR/assist-alpha.json" >/dev/null || fail "alpha not moved to target"
  ! jq -e '.bots[] | select(.name=="alpha")' "$POD_MOVE_PODS_DIR/builder.json" >/dev/null || fail "alpha still in source"
  expected=$'restart pod@builder.service\nenable --now pod@assist-alpha.service'
  [[ "$(sed -n '1,2p' "$POD_MOVE_MOCK_CALLS")" == "$expected" ]] || fail "restart order wrong"
  grep -q '"result":"success"' "$POD_MOVE_AUDIT_LOG" || fail "success audit missing"
  assert_production_pods_unchanged "$prod_before"
  pass "--drain waits, rechecks, moves, and keeps restart order"
}

test_rollback_stop_target_first() {
  make_fixture
  prod_before="$(production_pods_snapshot)"
  export POD_MOVE_FAIL_ENABLE=1
  if run_pod_move alpha assist-alpha --execute --confirm=alpha >/tmp/pod-move-rollback.out 2>&1; then
    fail "failed enable unexpectedly succeeded"
  fi
  jq -e '.bots[] | select(.name=="alpha")' "$POD_MOVE_PODS_DIR/builder.json" >/dev/null || fail "alpha not restored to source"
  [[ ! -f "$POD_MOVE_PODS_DIR/assist-alpha.json" ]] || fail "created target not removed on rollback"
  grep -n 'stop pod@assist-alpha.service' "$POD_MOVE_MOCK_CALLS" >/tmp/stop-line
  grep -n 'restart pod@builder.service' "$POD_MOVE_MOCK_CALLS" >/tmp/restart-lines
  stop_line="$(cut -d: -f1 /tmp/stop-line | tail -1)"
  rollback_restart_line="$(cut -d: -f1 /tmp/restart-lines | tail -1)"
  ((stop_line < rollback_restart_line)) || fail "rollback did not stop target before restarting source"
  grep -q '"result":"rollback"' "$POD_MOVE_AUDIT_LOG" || fail "rollback audit missing"
  assert_production_pods_unchanged "$prod_before"
  unset POD_MOVE_FAIL_ENABLE
  pass "rollback restores configs and stops target before source restart"
}

test_source_restart_failure_rolls_back_before_target_enable() {
  make_fixture
  prod_before="$(production_pods_snapshot)"
  export POD_MOVE_FAIL_SOURCE_RESTART=1
  if run_pod_move alpha assist-alpha --execute --confirm=alpha >/tmp/pod-move-source-restart-fail.out 2>&1; then
    fail "source restart failure unexpectedly succeeded"
  fi
  jq -e '.bots[] | select(.name=="alpha")' "$POD_MOVE_PODS_DIR/builder.json" >/dev/null || fail "alpha not restored after source restart failure"
  [[ ! -f "$POD_MOVE_PODS_DIR/assist-alpha.json" ]] || fail "target config not removed after source restart failure"
  ! grep -q 'enable --now pod@assist-alpha.service' "$POD_MOVE_MOCK_CALLS" || fail "target was enabled after source restart failed"
  grep -q '"result":"rollback"' "$POD_MOVE_AUDIT_LOG" || fail "rollback audit missing for source restart failure"
  assert_production_pods_unchanged "$prod_before"
  unset POD_MOVE_FAIL_SOURCE_RESTART
  pass "source restart failure rolls back before target enable"
}

test_rollback_fail_alerts_and_stops() {
  make_fixture
  prod_before="$(production_pods_snapshot)"
  export POD_MOVE_FAIL_ENABLE=1
  export POD_MOVE_FAIL_ROLLBACK_RESTART=1
  if run_pod_move alpha assist-alpha --execute --confirm=alpha >/tmp/pod-move-failfail.out 2>&1; then
    fail "fail-of-fail unexpectedly succeeded"
  fi
  grep -q '"result":"rollback_failed"' "$POD_MOVE_AUDIT_LOG" || fail "rollback_failed audit missing"
  grep -q 'CRITICAL pod-move rollback failed' "$POD_MOVE_MOCK_ALERTS" || fail "critical alert missing"
  assert_production_pods_unchanged "$prod_before"
  unset POD_MOVE_FAIL_ENABLE POD_MOVE_FAIL_ROLLBACK_RESTART
  pass "rollback fail-of-fail audits and alerts without retry loop"
}

test_dry_run_zero_mutation
test_running_task_refuses
test_drain_waits_and_moves
test_rollback_stop_target_first
test_source_restart_failure_rolls_back_before_target_enable
test_rollback_fail_alerts_and_stops

echo "PASS: $pass_count pod-move fixture checks"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/shared/bin/long-task-manifest.sh"
RESTART="$ROOT/pod-system/a9e4-safe-restart.sh"
TMP="$(mktemp -d)"
trap 'kill "${DETACHED_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

pass=0
assert() {
  local label="$1"; shift
  if "$@"; then
    pass=$((pass + 1))
    printf 'ok %02d - %s\n' "$pass" "$label"
  else
    printf 'not ok - %s\n' "$label" >&2
    exit 1
  fi
}

json_eq() {
  local file="$1" expression="$2" expected="$3"
  [[ "$(jq -r "$expression" "$file")" == "$expected" ]]
}

STATE="$TMP/state"
export LONG_TASK_STATE_DIR="$STATE"

assert "helper exposes --help" "$HELPER" --help
assert "register rejects incomplete input" bash -c '! "$1" register --id bad >/dev/null 2>&1' _ "$HELPER"
assert "register rejects traversal id" bash -c '! "$1" register --id ../bad --owner-bot anna --pod builder --pid 1 --pgid 1 --expected-duration 1 --desc bad >/dev/null 2>&1' _ "$HELPER"
for bot in anna anya bella buddy elon eric fengfeng huizhang kk orange panda sancai spark stargazer twinkle yitang zhanglinghe zhuchu; do
  assert "block symlink resolves for $bot" test -f "$ROOT/bots/$bot/blocks/block-long-task-keepalive.md"
done

LONG_TASK_NOW_EPOCH=1000 "$HELPER" register --id fixture --owner-bot anna --pod builder \
  --pid 111 --pgid 111 --expected-duration 900 --desc "fixture task" >/dev/null
MANIFEST="$STATE/fixture.json"
assert "register writes valid schema" jq -e '.schema_version==1 and .heartbeat_ts=="1970-01-01T00:16:40Z"' "$MANIFEST"
assert "manifest fields are complete" json_eq "$MANIFEST" '.owner_bot+":"+.pod+":"+(.pid|tostring)+":"+(.pgid|tostring)' "anna:builder:111:111"
assert "atomic register leaves no temporary JSON" bash -c '! find "$1" -maxdepth 1 -name ".long-task.*" | grep -q .' _ "$STATE"

touch -d '@1' "$MANIFEST"
assert "freshness ignores old file mtime" bash -c 'LONG_TASK_NOW_EPOCH=1100 "$1" has-active --pod builder --stale-after 300' _ "$HELPER"
touch -d '@999999' "$MANIFEST"
assert "stale decision ignores future file mtime" bash -c '! LONG_TASK_NOW_EPOCH=1300 "$1" has-active --pod builder --stale-after 300' _ "$HELPER"

LONG_TASK_NOW_EPOCH=1200 "$HELPER" heartbeat --id fixture >/dev/null
assert "heartbeat refreshes recorded timestamp" json_eq "$MANIFEST" '.heartbeat_ts' "1970-01-01T00:20:00Z"
assert "refreshed heartbeat is active" bash -c 'LONG_TASK_NOW_EPOCH=1499 "$1" has-active --pod builder --stale-after 300' _ "$HELPER"
assert "threshold equality is stale" bash -c '! LONG_TASK_NOW_EPOCH=1500 "$1" has-active --pod builder --stale-after 300' _ "$HELPER"
"$HELPER" clear --id fixture
assert "clear removes exact manifest" test ! -e "$MANIFEST"
assert "clear missing manifest fails closed" bash -c '! "$1" clear --id fixture >/dev/null 2>&1' _ "$HELPER"

printf '{broken\n' >"$STATE/broken.json"
assert "malformed manifest fails closed as active" bash -c 'LONG_TASK_NOW_EPOCH=2000 "$1" has-active --pod builder --stale-after 300' _ "$HELPER"
rm "$STATE/broken.json"

# Real process check: setsid creates a new session/process group and the child
# remains alive after the short-lived launcher shell has exited.
READY="$TMP/setsid.ready"
setsid bash -c '
  set -u
  helper="$1"; ready="$2"
  cleanup() { "$helper" clear --id setsid-fixture >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  trap "exit 143" TERM
  trap "exit 130" INT
  trap "exit 129" HUP
  "$helper" register --id setsid-fixture --owner-bot anna --pod builder \
    --pid "$$" --pgid "$(ps -o pgid= -p "$$" | tr -d " ")" \
    --expected-duration 60 --desc "setsid fixture" >/dev/null
  echo "$$" >"$ready"
  while :; do sleep 1; done
' _ "$HELPER" "$READY" </dev/null >"$TMP/setsid.log" 2>&1 &
for _ in {1..50}; do [[ -s "$READY" ]] && break; sleep 0.02; done
DETACHED_PID="$(<"$READY")"
assert "setsid child survives launcher return" kill -0 "$DETACHED_PID"
assert "setsid child owns its session" bash -c '[[ "$(ps -o sid= -p "$1" | tr -d " ")" == "$1" ]]' _ "$DETACHED_PID"
assert "setsid child owns its process group" bash -c '[[ "$(ps -o pgid= -p "$1" | tr -d " ")" == "$1" ]]' _ "$DETACHED_PID"
kill -TERM -- "-$DETACHED_PID"
for _ in {1..50}; do [[ ! -e "$STATE/setsid-fixture.json" ]] && break; sleep 0.02; done
assert "detached wrapper clears manifest on signal" test ! -e "$STATE/setsid-fixture.json"
wait "$DETACHED_PID" 2>/dev/null || true
DETACHED_PID=""

MOCK_PROC="$TMP/proc"
mkdir -p "$MOCK_PROC/4321"
printf 'bun\n' >"$MOCK_PROC/4321/comm"
printf 'POD_CONFIG=/home/oldrabbit/.claude-bots/pod-system/pods/builder.json\0' >"$MOCK_PROC/4321/environ"
KIDS="$TMP/kids"
NOW="$TMP/now"
SYSTEMCTL_LOG="$TMP/systemctl.log"
A9E4_LOG="$TMP/a9e4.log"
printf '0\n' >"$KIDS"
printf '1000\n' >"$NOW"
cat >"$TMP/systemctl-mock" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$A9E4_TEST_SYSTEMCTL_LOG"
[[ "${A9E4_TEST_SYSTEMCTL_FAIL:-0}" != "1" ]]
SH
chmod +x "$TMP/systemctl-mock"

run_restart() {
  A9E4_TEST_MODE=1 A9E4_NOW_FILE="$NOW" A9E4_KIDS_FILE="$KIDS" A9E4_PROC_ROOT="$MOCK_PROC" \
    A9E4_MAX_WAIT_SECONDS="${A9E4_TEST_MAX_WAIT:-120}" A9E4_POLL_SECONDS=60 \
    A9E4_MANIFEST_STALE_AFTER_SECONDS=300 A9E4_MANIFEST_HELPER="$HELPER" \
    A9E4_SYSTEMCTL_BIN="$TMP/systemctl-mock" A9E4_LOG_FILE="$A9E4_LOG" \
    A9E4_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    A9E4_TEST_SYSTEMCTL_FAIL="${A9E4_TEST_SYSTEMCTL_FAIL:-0}" \
    A9E4_POLL_HOOK="${A9E4_POLL_HOOK:-}" "$RESTART" builder
}
expect_restart_failure() {
  ! run_restart
}

assert "no-manifest idle pod keeps immediate behavior" run_restart
assert "idle restart does not advance wait clock" bash -c '[[ "$(<"$1")" == 1000 ]]' _ "$NOW"
assert "restart target remains pod@builder" grep -Fxq -- '--user restart pod@builder' "$SYSTEMCTL_LOG"

LONG_TASK_NOW_EPOCH=1000 "$HELPER" register --id stale --owner-bot anna --pod builder \
  --pid 222 --pgid 222 --expected-duration 900 --desc stale >/dev/null
printf '1400\n' >"$NOW"
: >"$SYSTEMCTL_LOG"
: >"$A9E4_LOG"
assert "stale manifest does not delay restart" run_restart
assert "stale restart remains immediate" bash -c '[[ "$(<"$1")" == 1400 ]]' _ "$NOW"
"$HELPER" clear --id stale

LONG_TASK_NOW_EPOCH=2000 "$HELPER" register --id live --owner-bot anna --pod builder \
  --pid 333 --pgid 333 --expected-duration 900 --desc live >/dev/null
printf '2000\n' >"$NOW"
: >"$SYSTEMCTL_LOG"
: >"$A9E4_LOG"
cat >"$TMP/heartbeat-hook" <<'SH'
#!/usr/bin/env bash
LONG_TASK_NOW_EPOCH="$(<"$A9E4_NOW_FILE")" "$A9E4_MANIFEST_HELPER" heartbeat --id live >/dev/null
SH
chmod +x "$TMP/heartbeat-hook"
A9E4_TEST_MAX_WAIT=120 A9E4_POLL_HOOK="$TMP/heartbeat-hook" assert \
  "continuously refreshed manifest cannot defeat hard deadline" run_restart
assert "hard deadline is exactly bounded" bash -c '[[ "$(<"$1")" == 2120 ]]' _ "$NOW"
assert "forced restart logs sacrificed manifest" grep -Eq 'HARD_DEADLINE.*\"id\":\"live\"' "$A9E4_LOG"
"$HELPER" clear --id live

printf '1\n' >"$KIDS"
printf '3000\n' >"$NOW"
: >"$A9E4_LOG"
cat >"$TMP/clear-kids-hook" <<'SH'
#!/usr/bin/env bash
printf '0\n' >"$A9E4_KIDS_FILE"
SH
chmod +x "$TMP/clear-kids-hook"
A9E4_POLL_HOOK="$TMP/clear-kids-hook" assert \
  "existing kid wait still exits when children clear" run_restart
assert "kid-only regression waits one poll" bash -c '[[ "$(<"$1")" == 3060 ]]' _ "$NOW"

printf '0\n' >"$KIDS"
printf '4000\n' >"$NOW"
: >"$A9E4_LOG"
A9E4_TEST_SYSTEMCTL_FAIL=1 assert "systemctl failure is propagated" expect_restart_failure
assert "failed restart is never logged as success" bash -c '! grep -q "restarted pod@builder" "$1"' _ "$A9E4_LOG"
assert "failed restart has explicit log evidence" grep -q 'restart FAILED pod@builder' "$A9E4_LOG"

bash -n "$HELPER"
bash -n "$RESTART"
printf '1..%d\n' "$pass"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCHER="$ROOT/shared/bin/mailbox-watch.sh"
HEALTH="$ROOT/shared/bin/mailbox-watch-health.sh"
FIXTURE="$(mktemp -d /tmp/mailbox-watch-fixture.XXXXXX)"
trap 'jobs -pr | xargs -r kill >/dev/null 2>&1 || true; rm -rf "$FIXTURE"' EXIT

MAILBOX="$FIXTURE/shared/mac-bridge/to-vps"
RELAY="$FIXTURE/relay"
STATE="$FIXTURE/state"
HEALTH_FILE="$FIXTURE/logs/health.json"
mkdir -p "$MAILBOX" "$RELAY/read" "$RELAY/quarantine" "$STATE" "$(dirname "$HEALTH_FILE")"

for n in $(seq -w 1 56); do
  printf 'stock %s\n' "$n" > "$MAILBOX/stock-$n.md"
done

mailbox_relays() {
  find "$RELAY" -maxdepth 1 -type f -name 'mailbox-message-*.json' | wc -l | tr -d ' '
}

mailbox_relay_count_is() {
  [[ "$(mailbox_relays)" -eq "$1" ]]
}

wait_for() {
  local description="$1"; shift
  for _ in $(seq 1 100); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  echo "FAIL timeout: $description" >&2
  return 1
}

launch_supervised() {
  local pid_file="$1"
  (
    set +e
    MAILBOX_ROOT="$FIXTURE" MAILBOX_TO_VPS_DIR="$MAILBOX" MAILBOX_RELAY_DIR="$RELAY" \
      MAILBOX_WATCH_STATE_DIR="$STATE" MAILBOX_WATCH_HEALTH_FILE="$HEALTH_FILE" \
      MAILBOX_WATCH_HEALTH_HELPER="$HEALTH" MAILBOX_WATCH_POLL_SECONDS=1 \
      "$WATCHER" &
    child=$!
    printf '%s\n' "$child" > "$pid_file"
    wait "$child"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      result=success; code=exited; status=0
    elif [[ "$rc" -ge 128 ]]; then
      result=signal; code=killed; status=$((rc - 128))
    else
      result=exit-code; code=exited; status="$rc"
    fi
    MAILBOX_ROOT="$FIXTURE" MAILBOX_RELAY_DIR="$RELAY" MAILBOX_WATCH_STATE_DIR="$STATE" \
      MAILBOX_WATCH_HEALTH_FILE="$HEALTH_FILE" "$HEALTH" stopped "$result" "$code" "$status"
    exit "$rc"
  ) &
  SUPERVISOR_PID=$!
}

before="$(mailbox_relays)"
launch_supervised "$FIXTURE/watcher.pid"
supervisor_one="$SUPERVISOR_PID"
wait_for 'first watcher healthy' jq -e '.status == "healthy"' "$HEALTH_FILE"
after_start="$(mailbox_relays)"
baseline_count="$(tr '\0' '\n' < "$STATE/baseline-v1.nul" | grep -c '^stock-')"
[[ "$before" == 0 && "$after_start" == 0 && "$baseline_count" == 56 ]]
echo "STOCK_ISOLATION before=$before after_start=$after_start baseline_count=$baseline_count"

printf 'new from mac\n' > "$FIXTURE/new.tmp"
mv "$FIXTURE/new.tmp" "$MAILBOX/20260816-acceptance-new.md"
wait_for 'new mailbox relay' mailbox_relay_count_is 1
relay_file="$(find "$RELAY" -maxdepth 1 -type f -name 'mailbox-message-*.json' -print -quit)"
jq -e '.from_bot == "mailbox-watch" and .recipient == "anya" and (.recipient | length > 0) and (.text | contains("20260816-acceptance-new.md"))' "$relay_file" >/dev/null
echo "NEW_RELAY file=$(basename "$relay_file")"
jq -c . "$relay_file"

first_pid="$(<"$FIXTURE/watcher.pid")"
kill -TERM "$first_pid"
wait "$supervisor_one" || true
launch_supervised "$FIXTURE/watcher.pid"
supervisor_two="$SUPERVISOR_PID"
wait_for 'restarted watcher healthy' jq -e '.status == "healthy"' "$HEALTH_FILE"
sleep 1.2
after_restart="$(mailbox_relays)"
[[ "$after_restart" == 1 ]]
echo "RESTART_IDEMPOTENCY before_restart=1 after_restart=$after_restart"

second_pid="$(<"$FIXTURE/watcher.pid")"
health_before_kill="$(jq -c '{status,last_failure}' "$HEALTH_FILE")"
kill -KILL "$second_pid"
wait "$supervisor_two" || true
wait_for 'kill reflected in health state' jq -e '.status == "unhealthy" and .last_failure.service_result == "signal" and .last_alert_file != null' "$HEALTH_FILE"
health_after_kill="$(jq -c '{status,last_failure,last_alert_file}' "$HEALTH_FILE")"
alert_file="$RELAY/$(jq -r .last_alert_file "$HEALTH_FILE")"
jq -e '.from_bot == "mailbox-watch" and .recipient == "anya" and (.text | contains("異常停止"))' "$alert_file" >/dev/null
echo "KILL_SIGNAL before=$health_before_kill"
echo "KILL_SIGNAL after=$health_after_kill"
echo "KILL_ALERT file=$(basename "$alert_file") recipient=$(jq -r .recipient "$alert_file")"

set +e
MAILBOX_ROOT="$FIXTURE/missing" MAILBOX_TO_VPS_DIR="$FIXTURE/missing/to-vps" \
  MAILBOX_WATCH_STATE_DIR="$FIXTURE/missing/state" MAILBOX_RELAY_DIR="$FIXTURE/missing/relay" \
  MAILBOX_WATCH_HEALTH_HELPER="$HEALTH" "$WATCHER" >/dev/null 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" -eq 2 ]]
echo "ERROR_PATH missing_mailbox_exit=$missing_rc"
echo "PASS mailbox-watch fixture"

#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
state="$fixture/state"
logs="$fixture/logs"
relay="$fixture/relay-diana"
inbox="$fixture/diana/inbox/messages"
mkdir -p "$state" "$logs" "$relay" "$inbox"

run="$repo/shared/scripts/pm-mechanical-run.sh"
monitor="$repo/shared/scripts/pm-mechanical-monitor.ts"
export PM_MECHANICAL_STATE_DIR="$state" PM_MECHANICAL_LOG_DIR="$logs" PM_MECHANICAL_RELAY_DIR="$relay"
export PM_MECHANICAL_NOW_EPOCH=2000000000 PM_MECHANICAL_THROTTLE_SECONDS=21600

for job in pipeline render reconcile; do
  PM_MECHANICAL_STATE_DIR="$state" "$run" "$job" -- true
  # Give deterministic fresh timestamps without changing the wrapper behavior under test.
  jq --argjson now "$PM_MECHANICAL_NOW_EPOCH" '.finished_epoch=$now' "$state/$job.json" > "$state/$job.tmp"
  mv "$state/$job.tmp" "$state/$job.json"
done
printf '%s\n' 'projection done 2033-05-18' 'pm-pipeline v2 done 2033-05-18T03:33:20+00:00' > "$logs/pm-pipeline.log"
printf '%s\n' 'heartbeat ts=2033-05-18T03:33:20Z inbox=0 calendar=0 exit=0' > "$logs/pm-reconcile.log"

healthy="$(bun run "$monitor")"
jq -e '.healthy == true and .alert == "none"' <<< "$healthy" >/dev/null
[[ "$(find "$relay" -maxdepth 1 -name '*-pm-mechanical-monitor.json' | wc -l)" == 0 ]]

# Non-zero reconcile must alert within this monitor cycle.
jq '.exit_code=7' "$state/reconcile.json" > "$state/reconcile.tmp" && mv "$state/reconcile.tmp" "$state/reconcile.json"
set +e
failed="$(bun run "$monitor")"; rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e '.healthy == false and .alert == "sent" and any(.findings[]; .check == "reconcile" and (.detail | contains("exit=7")))' <<< "$failed" >/dev/null
alert_file="$(find "$relay" -maxdepth 1 -name '*-pm-mechanical-monitor.json' -print -quit)"
jq -e '.route == "diana-chat" and (.text | startswith("diana:urgent"))' "$alert_file" >/dev/null

# Same failure is throttled, so a */3 cron cannot wash the owner with alerts.
set +e
again="$(bun run "$monitor")"; rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e '.alert == "throttled"' <<< "$again" >/dev/null
[[ "$(find "$relay" -maxdepth 1 -name '*.json' | wc -l)" == 1 ]]

# A stale job's age changes every cycle, but the unresolved failure category
# is stable and must remain throttled across the real */3-minute interval.
jq '.exit_code=0 | .finished_epoch=1999999400' "$state/reconcile.json" > "$state/reconcile.tmp" && mv "$state/reconcile.tmp" "$state/reconcile.json"
printf '%s\n' 'heartbeat ts=2033-05-18T03:23:20Z inbox=0 calendar=0 exit=0' > "$logs/pm-reconcile.log"
PM_MECHANICAL_NOW_EPOCH=2000000600
export PM_MECHANICAL_NOW_EPOCH
set +e
stale_first="$(bun run "$monitor")"; rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e '.alert == "sent" and any(.findings[]; .category == "stale")' <<< "$stale_first" >/dev/null
stale_alert_count="$(find "$relay" -maxdepth 1 -name '*.json' | wc -l)"

PM_MECHANICAL_NOW_EPOCH=2000000780
export PM_MECHANICAL_NOW_EPOCH
set +e
stale_again="$(bun run "$monitor")"; rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e '.alert == "throttled" and any(.findings[]; .category == "stale")' <<< "$stale_again" >/dev/null
[[ "$(find "$relay" -maxdepth 1 -name '*.json' | wc -l)" == "$stale_alert_count" ]]

# The existing relay-listener moves the relay to read/ and writes diana-chat's disk inbox.
DIANA_RELAY_DIR="$relay" DIANA_CHAT_INBOX_DIR="$inbox" bun run "$repo/bots/keeper/relay-listener.ts" --process-once "$alert_file"
inbox_file="$(find "$inbox" -maxdepth 1 -name '*.json' -print -quit)"
jq -e '.params.content | startswith("diana:urgent")' "$inbox_file" >/dev/null
[[ -f "$relay/read/$(basename "$alert_file")" ]]

# A successful 0-item heartbeat is healthy after status recovery.
PM_MECHANICAL_NOW_EPOCH=2000000000
export PM_MECHANICAL_NOW_EPOCH
jq --argjson now "$PM_MECHANICAL_NOW_EPOCH" '.exit_code=0 | .finished_epoch=$now' "$state/reconcile.json" > "$state/reconcile.tmp" && mv "$state/reconcile.tmp" "$state/reconcile.json"
printf '%s\n' 'heartbeat ts=2033-05-18T03:33:20Z inbox=0 calendar=0 exit=0' > "$logs/pm-reconcile.log"
recovered="$(bun run "$monitor")"
jq -e '.healthy == true' <<< "$recovered" >/dev/null

# Projector is not a fourth cron: its latest pipeline log segment is the signal.
printf '%s\n' 'projection done old' 'pm-pipeline v2 done old' '[CHL] token FAIL: denied' 'pm-pipeline v2 done current' > "$logs/pm-pipeline.log"
PM_MECHANICAL_NOW_EPOCH=2000000001
export PM_MECHANICAL_NOW_EPOCH
set +e
projector="$(bun run "$monitor")"; rc=$?
set -e
[[ "$rc" == 1 ]]
jq -e 'any(.findings[]; .check == "projector" and (.detail | contains("token FAIL")))' <<< "$projector" >/dev/null

# Wrapper preserves the command exit code and records it atomically.
set +e
PM_MECHANICAL_STATE_DIR="$state" "$run" render -- bash -c 'exit 9'
wrapper_rc=$?
set -e
[[ "$wrapper_rc" == 9 ]]
jq -e '.schema == "pm-mechanical-status-v1" and .job == "render" and .exit_code == 9' "$state/render.json" >/dev/null

report="$(bun run "$monitor" --report)"
grep -q 'Mode: alert-only; no automatic repair or crontab ownership migration' <<< "$report"
echo "PASS pm-mechanical-monitor: freshness/exit, idle heartbeat, projector log, relay route, throttle, report"

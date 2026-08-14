#!/usr/bin/env bash
# Isolated evidence for hold semantics across patrol, spec drift, and closeout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATROL_SH="$SCRIPT_DIR/../bin/patrol-scan.sh"
WATCH_SH="$SCRIPT_DIR/../bin/fatq-watch.sh"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"
SWEEP_SH="$SCRIPT_DIR/../bin/fatq-closeout-sweep.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

probe_line_present() {
  local lines="$1" needle="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<< "$lines"
  return 1
}

probe_line_absent() {
  ! probe_line_present "$1" "$2"
}

probe_exact_equal() {
  [[ "$1" == "$2" ]]
}

probe_exact_not_equal() {
  [[ "$1" != "$2" ]]
}

require_probe() {
  local label="$1"
  shift
  if "$@"; then
    printf '[hold-monitor-fixture] PROBE PASS: %s\n' "$label"
  else
    printf '[hold-monitor-fixture] PROBE FAIL: %s\n' "$label" >&2
    return 1
  fi
}

require_negative_probe() {
  local label="$1"
  shift
  if "$@"; then
    printf '[hold-monitor-fixture] NEGATIVE PROBE UNEXPECTEDLY PASSED: %s\n' "$label" >&2
    return 1
  fi
  printf '[hold-monitor-fixture] NEGATIVE PROBE PASS (exit non-zero): %s\n' "$label"
}

run_patrol_cases() {
  local root="$TMPROOT/patrol" now now_iso old_iso active_until expired_until output failures checks
  root="$TMPROOT/patrol"
  now_iso="2026-08-14T12:00:00+08:00"
  old_iso="2026-08-14T00:00:00+08:00"
  active_until="2026-09-01T00:00:00+08:00"
  expired_until="2026-08-14T11:00:00+08:00"
  now="$(date -d "$now_iso" +%s)"
  mkdir -p "$root"/{tasks/{pending,in_progress,review},relay,logs,shared/config,pod-system/pods}
  printf '%s\n' '{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":100,"in_progress":100,"review":100,"relay_unconsumed":100,"event_injection":100},"gateway":{"expected_processes":0,"tolerance":0},"whitelist":[],"true_bot_recipients_fallback":["anya","bella"]}' > "$root/shared/config/patrol-scan.json"
  : > "$root/ps.txt"
  jq -n --arg id "patrol-unheld-overdue" --arg ts "$old_iso" '{task_id:$id,status:"review",assigned:"anna",reviewer:"bella",history:[{ts:$ts,action:"submit",from:"in_progress/",to:"review/"}]}' > "$root/tasks/review/unheld.json"
  jq -n --arg id "patrol-active-hold" --arg ts "$old_iso" --arg hold "$active_until" '{task_id:$id,status:"review",assigned:"anna",reviewer:"bella",not_before:$hold,history:[{ts:$ts,action:"submit",from:"in_progress/",to:"review/"}]}' > "$root/tasks/review/active.json"
  jq -n --arg id "patrol-expired-hold" --arg ts "$old_iso" --arg hold "$expired_until" '{task_id:$id,status:"review",assigned:"anna",reviewer:"bella",not_before:$hold,history:[{ts:$ts,action:"submit",from:"in_progress/",to:"review/"}]}' > "$root/tasks/review/expired.json"

  PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$root/relay" PATROL_INOTIFY_LOG="$root/no-inotify.log" PATROL_PODS_DIR="$root/pod-system/pods" PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH="$now" bash "$PATROL_SH" > "$root/output.json"
  output="$(jq -c . "$root/output.json")"
  failures="$(jq -r '.failures[]' "$root/output.json")"
  checks="$(jq -r '.checks[] | "\(.check): \(.status): \(.evidence)"' "$root/output.json")"
  printf '[hold-monitor-fixture] PATROL ACTUAL: %s\n' "$output"

  local unheld_alert="task_review: $root/tasks/review/unheld.json task_id=patrol-unheld-overdue event_age=43200s threshold=100s assigned=anna"
  local active_alert="task_review: $root/tasks/review/active.json task_id=patrol-active-hold event_age=43200s threshold=100s assigned=anna"
  local active_suppression="task_review: pass: patrol-active-hold held_until=$active_until"
  local expired_alert="task_review: $root/tasks/review/expired.json task_id=patrol-expired-hold event_age=43200s threshold=100s assigned=anna"
  require_probe "patrol unheld overdue emits full alert" probe_line_present "$failures" "$unheld_alert"
  require_negative_probe "patrol unheld inverse full alert probe" probe_line_absent "$failures" "$unheld_alert"
  require_probe "patrol active hold suppresses full alert" probe_line_absent "$failures" "$active_alert"
  require_probe "patrol active hold prints suppression evidence" probe_line_present "$checks" "$active_suppression"
  require_negative_probe "patrol active-hold inverse full alert probe" probe_line_present "$failures" "$active_alert"
  require_probe "patrol expired hold emits full alert" probe_line_present "$failures" "$expired_alert"
  require_negative_probe "patrol expired-hold inverse full alert probe" probe_line_absent "$failures" "$expired_alert"
}

run_watch_case() {
  local root="$TMPROOT/watch" tid task_file relay_file actual expected
  tid="20260814-0000-hold-watch"
  mkdir -p "$root/tasks"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending} "$root/relay"
  printf '%s\n' '{"assistants":[{"state_dir":"interns"}],"shared_pools":{"builder":[{"state_dir":"interns"}],"reviewer":[{"state_dir":"bella"}]},"external_identities":["anya"]}' > "$root/team-config.json"
  jq -n --arg tid "$tid" '{task_id:$tid,slug:"hold-watch",status:"pending",assigned:"interns",reviewer:"bella",goal:"original goal",context:"original context",acceptance_criteria:["original acceptance"],deliverables:["original deliverable"],out_of_scope:["original out of scope"],not_before:"2026-09-01T00:00:00+08:00",history:[]}' > "$root/tasks/pending/$tid.json"
  FATQ_ROOT="$root/tasks" FATQ_TEAM_CONFIG="$root/team-config.json" FATQ_MATTERMOST_DISABLE=1 bash "$CLI_SH" claim "$tid" --as interns >/dev/null
  task_file="$root/tasks/in_progress/$tid.json"
  jq '.context="changed during active hold"' "$task_file" > "$task_file.tmp"
  mv "$task_file.tmp" "$task_file"
  FATQ_ROOT="$root/tasks" FATQ_RELAY_DIR="$root/relay" FATQ_WATCH_LOG="$root/watch.log" FATQ_WATCH_SKIP_INITIAL_DISPATCH=1 FATQ_WATCH_RUN_ONCE=1 INOTIFYWAIT_BIN=/bin/true bash "$WATCH_SH" >/dev/null
  relay_file="$(find "$root/relay" -maxdepth 1 -type f -name '*.json' -print -quit)"
  actual="$(jq -r '.text' "$relay_file")"
  expected="[FATQ spec 變更通知] 任務 ${tid} 在 claim 後 spec 欄位已變更。\n變更欄位：context\n任務檔：${task_file}\n請在 submit 前重新讀取最新 goal/context/acceptance_criteria/deliverables/out_of_scope/workflow。"
  printf '[hold-monitor-fixture] WATCH ACTUAL:\n%s\n' "$actual"
  require_probe "watch active hold keeps the complete spec-integrity alert" probe_exact_equal "$actual" "$expected"
  require_negative_probe "watch active-hold inverse complete alert probe" probe_exact_not_equal "$actual" "$expected"
}

run_closeout_cases() {
  local root="$TMPROOT/closeout" relay_file items unheld_item active_item expired_item
  root="$TMPROOT/closeout"
  mkdir -p "$root/tasks/done" "$root/relay"
  make_done() {
    local tid="$1" not_before="$2"
    jq -n --arg tid "$tid" --arg hold "$not_before" '{task_id:$tid,status:"done",not_before:(if $hold=="" then null else $hold end),closeout:{state:"pending"},history:[{ts:"2026-08-12T12:00:00+08:00",by:"bella",action:"verdict_approve",from:"review/",to:"done/"}]}' > "$root/tasks/done/$tid.json"
  }
  make_done "closeout-unheld-overdue" ""
  make_done "closeout-active-hold" "2026-09-01T00:00:00+08:00"
  make_done "closeout-expired-hold" "2026-08-14T11:00:00+08:00"
  FATQ_ROOT="$root/tasks" FATQ_RELAY_DIR="$root/relay" FATQ_CLOSEOUT_SWEEP_STATE="$root/state.json" FATQ_NOW_ISO="2026-08-14T12:00:00+08:00" bash "$SWEEP_SH" > "$root/output.log"
  relay_file="$(find "$root/relay" -maxdepth 1 -type f -name '*.json' -print -quit)"
  items="$(jq -r '.tasks[] | "task_id=\(.task_id) done_ts=\(.done_ts) closeout_state=\(.closeout_state) age_secs=\(.age_secs)"' "$relay_file")"
  printf '[hold-monitor-fixture] CLOSEOUT ACTUAL: %s\n' "$(jq -c . "$relay_file")"
  unheld_item="task_id=closeout-unheld-overdue done_ts=2026-08-12T12:00:00+08:00 closeout_state=pending age_secs=172800"
  active_item="task_id=closeout-active-hold done_ts=2026-08-12T12:00:00+08:00 closeout_state=pending age_secs=172800"
  expired_item="task_id=closeout-expired-hold done_ts=2026-08-12T12:00:00+08:00 closeout_state=pending age_secs=172800"
  require_probe "closeout unheld overdue emits full task item" probe_line_present "$items" "$unheld_item"
  require_negative_probe "closeout unheld inverse full item probe" probe_line_absent "$items" "$unheld_item"
  require_probe "closeout active hold suppresses full task item" probe_line_absent "$items" "$active_item"
  require_negative_probe "closeout active-hold inverse full item probe" probe_line_present "$items" "$active_item"
  require_probe "closeout expired hold emits full task item" probe_line_present "$items" "$expired_item"
  require_negative_probe "closeout expired-hold inverse full item probe" probe_line_absent "$items" "$expired_item"
}

run_patrol_cases
run_watch_case
run_closeout_cases
printf '[hold-monitor-fixture] PASS: patrol and closeout honor active/expired holds; watch preserves spec-integrity alerts; every scenario has a full-string negative probe\n'

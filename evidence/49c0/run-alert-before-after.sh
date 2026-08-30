#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_COMMIT="${PATROL_AB_BASE_COMMIT:-a52651bb128b1ed17104df1c6cfd7411a75d4bda}"
OUT_DIR="${PATROL_ALERT_AB_OUT_DIR:-$REPO_ROOT/evidence/49c0/alert-before-after}"
NOW=1785000000
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf -- "$FIXTURE"; }
trap cleanup EXIT

make_root() {
  local root="$1"
  mkdir -p "$root"/tasks/{pending,in_progress,review} "$root"/{logs,relay,pod-system/pods,shared/config}
  printf '%s\n' '{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":10,"in_progress":10,"review":10,"relay_unconsumed":10,"event_injection":10},"gateway":{"expected_processes":0,"tolerance":0},"whitelist":[],"true_bot_recipients_fallback":["anya","orange","twinkle"]}' > "$root/shared/config/patrol-scan.json"
  : > "$root/ps.txt"
  jq -n '{task_id:"05c1-SHAPE",status:"in_progress",assigned:"twinkle",created_by:"orange",deliver_to:"orange",reviewer:"bella",history:[{ts:"2026-07-25T17:19:40+00:00",action:"claim",from:"pending/",to:"in_progress/"},{ts:"2026-07-25T17:19:55+00:00",by:"twinkle",action:"comment",text:"delivery ready; waiting for user confirmation"}]}' > "$root/tasks/in_progress/05c1.json"
}
run_scan() {
  local script="$1" root="$2" output="$3"
  PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
    PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$root/relay" \
    PATROL_INOTIFY_LOG="$root/missing.log" PATROL_PODS_DIR="$root/pod-system/pods" \
    PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH="$NOW" \
    PATROL_BLOCKING_LIB="$REPO_ROOT/shared/lib/fatq-blocking.sh" bash "$script" > "$output"
}

mkdir -p "$OUT_DIR"
git -C "$REPO_ROOT" show "$BASE_COMMIT:shared/bin/patrol-scan.sh" > "$FIXTURE/baseline.sh"
make_root "$FIXTURE/before"
make_root "$FIXTURE/after"
run_scan "$FIXTURE/baseline.sh" "$FIXTURE/before" "$OUT_DIR/before-record.json"
run_scan "$REPO_ROOT/shared/bin/patrol-scan.sh" "$FIXTURE/after" "$OUT_DIR/after-record.json"
find "$FIXTURE/before/relay" -maxdepth 1 -type f -name '*-twinkle.json' -exec jq -r '.text' {} \; -quit > "$OUT_DIR/before-alert.txt"
find "$FIXTURE/after/relay" -maxdepth 1 -type f -name '*-orange.json' -exec jq -r '.text' {} \; -quit > "$OUT_DIR/after-alert.txt"

printf 'AC1 before alert:\n%s\n' "$(cat "$OUT_DIR/before-alert.txt")"
printf 'AC1 after alert:\n%s\n' "$(cat "$OUT_DIR/after-alert.txt")"

#!/usr/bin/env bash
# Isolated patrol fixtures. Never read production tasks or enqueue live relay.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATROL_SH="${PATROL_SCAN_SH:-$SCRIPT_DIR/../bin/patrol-scan.sh}"
PASS=0; FAIL=0; TMPROOT=""
ok() { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
setup() {
  TMPROOT="$(mktemp -d)"
  mkdir -p "$TMPROOT"/{tasks/review,tasks/in_progress,relay,logs,shared/config,pod-system/pods}
  cat > "$TMPROOT/shared/config/patrol-scan.json" <<'EOF'
{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":7200,"in_progress":100,"review":100,"relay_unconsumed":900,"event_injection":120},"gateway":{"expected_processes":0,"tolerance":0},"whitelist":[],"true_bot_recipients_fallback":["anya","bella","eric"]}
EOF
  : > "$TMPROOT/ps.txt"
}
teardown() { [[ -n "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
run_patrol() {
  PATROL_ROOT="$TMPROOT" PATROL_CONFIG="$TMPROOT/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$TMPROOT/logs" PATROL_RELAY_DIR="$TMPROOT/relay" \
  PATROL_INOTIFY_LOG="$TMPROOT/missing-inotify.log" PATROL_PODS_DIR="$TMPROOT/pod-system/pods" \
  PATROL_PS_FILE="$TMPROOT/ps.txt" PATROL_NOW_EPOCH="$1" bash "$PATROL_SH" > "$TMPROOT/run-$1.json"
}
make_review() {
  local file="$1" reviewer="$2" id="${3:-fixture-review}"
  jq -n --arg reviewer "$reviewer" --arg id "$id" '{task_id:$id,status:"review",reviewer:$reviewer,history:[{ts:"2026-07-01T00:00:00+00:00",by:"eric",action:"submit",from:"in_progress/",to:"review/"}]}' > "$file"
}

echo "patrol scan isolated fixtures"
setup
f="$TMPROOT/tasks/review/stalled.json"; make_review "$f" bella
run_patrol 1782950500
first_bella="$(find "$TMPROOT/relay" -name '*-bella.json' -print -quit)"
first_anya="$(find "$TMPROOT/relay" -name '*-anya.json' -print -quit)"
jq '.history += [{ts:"2026-07-20T00:00:00+00:00",by:"anya",action:"comment",text:"human intervention"}]' "$f" > "$f.next" && mv "$f.next" "$f"
run_patrol 1782954201
second_bella_count="$(find "$TMPROOT/relay" -name '*-bella.json' | wc -l | tr -d ' ')"
if [[ -n "$first_bella" && -n "$first_anya" && "$second_bella_count" == 2 ]] &&
   jq -e '.recipient == "bella"' "$first_bella" >/dev/null &&
   grep -q 'event_age=' "$TMPROOT/run-1782950500.json" &&
   grep -q 'event_age=' "$TMPROOT/run-1782954201.json"; then
  ok "event age ignores human comment mtime and notifies reviewer plus owner"
else
  bad "event age or direct review relay failed"
fi
teardown

setup
f="$TMPROOT/tasks/in_progress/stalled.json"
jq -n '{task_id:"fixture-progress",status:"in_progress",assigned:"eric",history:[{ts:"2026-07-01T00:00:00+00:00",by:"eric",action:"claim",from:"pending/",to:"in_progress/"}]}' > "$f"
run_patrol 1782950500
direct="$(find "$TMPROOT/relay" -name '*-eric.json' -print -quit)"
if [[ -n "$direct" ]] && jq -e '.recipient == "eric"' "$direct" >/dev/null; then
  ok "in-progress alert relays directly to assignee"
else
  bad "in-progress assignee did not receive relay"
fi
teardown

setup
make_review "$TMPROOT/tasks/review/bella.json" bella fixture-review-bella
make_review "$TMPROOT/tasks/review/yitang.json" yitang fixture-review-yitang
run_patrol 1782950500
bella_alert="$(find "$TMPROOT/relay" -name '*-bella.json' -print -quit)"
yitang_alert="$(find "$TMPROOT/relay" -name '*-yitang.json' -print -quit)"
owner_alert="$(find "$TMPROOT/relay" -name '*-anya.json' -print -quit)"
if [[ -n "$bella_alert" && -n "$yitang_alert" && -n "$owner_alert" ]] &&
   jq -e '.text | contains("fixture-review-bella") and (contains("fixture-review-yitang") | not)' "$bella_alert" >/dev/null &&
   jq -e '.text | contains("fixture-review-yitang") and (contains("fixture-review-bella") | not)' "$yitang_alert" >/dev/null &&
   jq -e '.text | contains("fixture-review-bella") and contains("fixture-review-yitang")' "$owner_alert" >/dev/null; then
  ok "task-party relays isolate failures by recipient while owner retains full summary"
else
  bad "task-party relay payload leaked another recipient's task"
fi
teardown

setup
f="$TMPROOT/tasks/review/missing-recipient.json"; make_review "$f" ""
run_patrol 1782950500
if grep -q 'recipient_missing' "$TMPROOT/run-1782950500.json" &&
   find "$TMPROOT/relay" -name '*-anya.json' -print -quit | grep -q . &&
   ! find "$TMPROOT/relay" -name '*-.json' -print -quit | grep -q .; then
  ok "missing task recipient remains visibly recorded while owner is alerted"
else
  bad "missing recipient was silently ignored"
fi
teardown

echo "RESULT: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]]

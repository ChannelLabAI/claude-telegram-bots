#!/usr/bin/env bash
# Isolated E2E fixture for reviewer retry/redelivery. Never reads production
# tasks or sends to real bot sessions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_SH="${FATQ_DISPATCH_CRON_SH:-$SCRIPT_DIR/../bin/fatq-dispatch-cron.sh}"
BASE_EPOCH=1784937600
PASS=0
FAIL=0
TMPROOT=""

ok() { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

setup() {
  TMPROOT="$(mktemp -d)"
  export FATQ_ROOT="$TMPROOT/tasks"
  export FATQ_RELAY_DIR="$TMPROOT/relay"
  export FATQ_STATE_DIR="$TMPROOT/state"
  export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
  export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
  export FATQ_TRUST_LEDGER="$TMPROOT/missing-trust.tsv"
  export FATQ_MATTERMOST_DISABLE=1
  export FATQ_CREATE_GATE_DISABLED=1
  export FATQ_REVIEW_ACK_SECS=300
  export FATQ_REVIEW_MAX_DISPATCH=2
  export FATQ_CLAIM_TTL_SECS=14400
  export FATQ_MAX_DISPATCH=3
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review,reviews,proposals}
  mkdir -p "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"

  printf '%s\n' \
    '{"assistants":[{"state_dir":"anya","bot_username":"Anyachl_bot"}],"shared_pools":{"builder":[{"state_dir":"anna"}],"reviewer":[{"state_dir":"bella"},{"state_dir":"yitang"}]},"external_identities":[]}' \
    > "$FATQ_TEAM_CONFIG"
  printf '%s\n' \
    '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' \
    > "$FATQ_DISPATCH_AFFINITY"
}

teardown() {
  [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"
}

make_review_task() {
  local tid="$1" f
  f="$FATQ_ROOT/review/$tid.json"
  jq -n --arg tid "$tid" \
    '{task_id:$tid,slug:"fixture",status:"review",assigned:"anna",reviewer:"bella",created_by:"anya",history:[{ts:"2026-07-25T00:00:00+08:00",by:"anna",action:"submit",to:"review/"}]}' \
    > "$f"
  printf '%s\n' "$f"
}

make_pending_task() {
  local tid="$1" f
  f="$FATQ_ROOT/pending/$tid.json"
  jq -n --arg tid "$tid" \
    '{task_id:$tid,slug:"fixture",status:"pending",assigned:"anna",reviewer:"bella",created_by:"anya",history:[{ts:"2026-07-25T00:00:00+08:00",by:"anya",action:"create",to:"pending/"}]}' \
    > "$f"
  printf '%s\n' "$f"
}

run_cron() {
  bash "$CRON_SH" >>"$TMPROOT/dispatch.log" 2>&1
}

consume_relays() {
  mkdir -p "$FATQ_RELAY_DIR/read"
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' -exec mv {} "$FATQ_RELAY_DIR/read/" \;
}

append_event() {
  local f="$1" by="$2" action="$3" text="$4" tmp
  tmp="$(mktemp "$(dirname "$f")/.fixture.XXXXXX")"
  jq --arg ts "$(TZ=Asia/Taipei date -d "@$FATQ_NOW_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')" \
    --arg by "$by" --arg action "$action" --arg text "$text" \
    '.history += [{ts:$ts,by:$by,action:$action,text:$text}]' "$f" > "$tmp" &&
    mv -f "$tmp" "$f"
}

dispatch_count() {
  jq '[.history[] | select(.by=="fatq-dispatch-cron" and .action=="dispatch")] | length' "$1"
}

echo "fatq reviewer retry/redelivery E2E"

# Canary: the fixture must not scan or mutate an unrelated tree.
setup
CANARY="$TMPROOT/canary/tasks/review/canary.json"
mkdir -p "$(dirname "$CANARY")"
printf '%s\n' '{"task_id":"canary","history":[]}' > "$CANARY"
CANARY_HASH="$(sha256sum "$CANARY" | awk '{print $1}')"
f="$(make_review_task 20260725-0000-dd31-session-limit)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
consume_relays
append_event "$f" bella comment "You've hit your session limit · resets 1:40am (Asia/Taipei)"
export FATQ_NOW_EPOCH=$((BASE_EPOCH+60))
run_cron
if [[ "$(dispatch_count "$f")" == 2 ]] &&
   jq -e '[.history[] | select(.action=="dispatch")] | last | .attempt==2 and .retry_reason=="reviewer_failure" and .target=="bella"' "$f" >/dev/null; then
  ok "explicit session-limit response redelivers to the same reviewer next cron"
else
  bad "explicit session-limit response did not produce bounded redelivery"
fi
if [[ "$(sha256sum "$CANARY" | awk '{print $1}')" == "$CANARY_HASH" ]] &&
   ! grep -Rqs '"fatq_task_id":"canary"' "$FATQ_RELAY_DIR"; then
  ok "fixture canary proves task/relay isolation"
else
  bad "fixture touched canary state"
fi
teardown

# A persistent builder authority/spec blocker is not recoverable by sending the
# same assignment again. A later Anya instruction is a new event and reopens it.
setup
f="$(make_pending_task 20260725-0000-dd31-stable-builder-block)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
consume_relays
append_event "$f" anna comment "[BLOCKED-AUTH] identity is not authorized to claim"
export FATQ_NOW_EPOCH=$((BASE_EPOCH+60))
run_cron
export FATQ_NOW_EPOCH=$((BASE_EPOCH+120))
run_cron
blocked_count="$(dispatch_count "$f")"
append_event "$f" anya comment "Authorization corrected; retry claim now."
export FATQ_NOW_EPOCH=$((BASE_EPOCH+180))
run_cron
if [[ "$blocked_count" == 1 && "$(dispatch_count "$f")" == 2 ]] &&
   grep -q 'decision=skip:stable_builder_block' "$TMPROOT/dispatch.log"; then
  ok "unchanged builder blocker is damped until authority posts a resolution"
else
  bad "stable builder blocker caused redispatch ping-pong"
fi
teardown

# No response: wait for the review-specific ack window, not the 4h builder TTL.
setup
f="$(make_review_task 20260725-0000-dd31-no-ack)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
consume_relays
export FATQ_NOW_EPOCH=$((BASE_EPOCH+FATQ_REVIEW_ACK_SECS-1))
run_cron
before="$(dispatch_count "$f")"
export FATQ_NOW_EPOCH=$((BASE_EPOCH+FATQ_REVIEW_ACK_SECS+1))
run_cron
after="$(dispatch_count "$f")"
if [[ "$before" == 1 && "$after" == 2 ]] &&
   jq -e '[.history[] | select(.action=="dispatch")] | last | .retry_reason=="reviewer_no_ack"' "$f" >/dev/null; then
  ok "no-response waits for ack TTL then redelivers"
else
  bad "no-response TTL behavior is wrong (before=$before after=$after)"
fi
teardown

# A normal reviewer checkpoint is an ack; merely discussing 429 must not be
# misclassified as a session failure.
setup
f="$(make_review_task 20260725-0000-dd31-normal-ack)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
consume_relays
append_event "$f" bella comment "Review started; fixture covers normal HTTP 429 behavior."
export FATQ_NOW_EPOCH=$((BASE_EPOCH+FATQ_REVIEW_ACK_SECS+30))
run_cron
if [[ "$(dispatch_count "$f")" == 1 ]] &&
   grep -q 'decision=skip:acked' "$TMPROOT/dispatch.log"; then
  ok "normal reviewer ack and receipt damping produce no duplicate review"
else
  bad "normal reviewer ack was redelivered"
fi
teardown

# Pending relay is authoritative: even a concurrent failure comment cannot
# create a second live delivery before the gateway consumes the first.
setup
f="$(make_review_task 20260725-0000-dd31-live-relay)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
append_event "$f" bella comment "You've hit your weekly limit · resets tomorrow"
export FATQ_NOW_EPOCH=$((BASE_EPOCH+60))
run_cron
live_count="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ "$live_count" == 1 && "$(dispatch_count "$f")" == 1 ]]; then
  ok "live relay no-clobber prevents double-review dispatch"
else
  bad "pending relay allowed duplicate dispatch"
fi
teardown

# Exhaustion emits one owner escalation and never loops forever.
setup
f="$(make_review_task 20260725-0000-dd31-exhausted)"
export FATQ_NOW_EPOCH=$BASE_EPOCH
run_cron
consume_relays
append_event "$f" bella comment "You've hit your session limit · resets later"
export FATQ_NOW_EPOCH=$((BASE_EPOCH+60))
run_cron
consume_relays
append_event "$f" bella comment '{"api_error_status":429,"is_error":true}'
export FATQ_NOW_EPOCH=$((BASE_EPOCH+120))
run_cron
consume_relays
export FATQ_NOW_EPOCH=$((BASE_EPOCH+180))
run_cron
esc_count="$(jq '[.history[] | select(.action=="escalate")] | length' "$f")"
esc_relay_count="$(find "$FATQ_RELAY_DIR" -type f -name '*escalate.json' | wc -l | tr -d ' ')"
if [[ "$(dispatch_count "$f")" == 2 && "$esc_count" == 1 && "$esc_relay_count" == 1 ]] &&
   find "$FATQ_RELAY_DIR" -type f -name '*escalate.json' -exec jq -e '.recipient=="anya"' {} \; >/dev/null; then
  ok "retry cap escalates to Anya exactly once"
else
  bad "retry exhaustion was not bounded (dispatch=$(dispatch_count "$f") escalate=$esc_count relay=$esc_relay_count)"
fi
teardown

echo "RESULT: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]]

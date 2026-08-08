#!/usr/bin/env bash
# Focused regression for assignee-owned nudge staleness and the daily cap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_STATE_DIR="$TMPROOT/state"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_WORKER_PS_FILE="$TMPROOT/workers"
export FATQ_NOW_EPOCH=1786200000
export FATQ_STALE_SECS=7200
export FATQ_NUDGE_COOLDOWN_SECS=7200
export FATQ_MAX_NUDGES=3
export FATQ_DAILY_NUDGE_LIMIT=2
export FATQ_CREATE_GATE_DISABLED=1
export FATQ_MATTERMOST_DISABLE=1

mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review,reviews,proposals}
mkdir -p "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"
printf '%s\n' gateway-builder-eric gateway-builder-sara gateway-builder-anna > "$FATQ_WORKER_PS_FILE"

cat > "$FATQ_TEAM_CONFIG" <<'JSON'
{
  "assistants": [{"state_dir":"anya"}],
  "shared_pools": {
    "builder": [{"state_dir":"anna"},{"state_dir":"eric"},{"state_dir":"sara"}],
    "reviewer": [{"state_dir":"bella"},{"state_dir":"yitang"}]
  },
  "external_identities": []
}
JSON

iso_at() {
  TZ=Asia/Taipei date -d "@$1" '+%Y-%m-%dT%H:%M:%S+08:00'
}

old_ts="$(iso_at $((FATQ_NOW_EPOCH - 10800)))"
recent_ts="$(iso_at $((FATQ_NOW_EPOCH - 60)))"
nudge_one_ts="$(iso_at $((FATQ_NOW_EPOCH - 7100)))"
nudge_two_ts="$(iso_at $((FATQ_NOW_EPOCH - 3500)))"

# assigned: a fresh orchestrator comment must not mask the assignee's old claim.
jq -n --arg old "$old_ts" --arg recent "$recent_ts" '{
  task_id:"20260808-0000-a1a1-assigned-external-comment", status:"in_progress",
  assigned:"eric", reviewer:"yitang",
  history:[
    {ts:$old,by:"eric",action:"claim"},
    {ts:$recent,by:"anya",action:"comment",text:"host evidence supplied"}
  ]
}' > "$FATQ_ROOT/in_progress/20260808-0000-a1a1-assigned-external-comment.json"

# assigned_to: the assignee's own fresh checkpoint must reset staleness.
jq -n --arg old "$old_ts" --arg recent "$recent_ts" '{
  task_id:"20260808-0000-b2b2-assigned-to-self-checkpoint", status:"in_progress",
  assigned_to:"sara", reviewer:"yitang",
  history:[
    {ts:$old,by:"sara",action:"claim"},
    {ts:$recent,by:"sara",action:"checkpoint",text:"still working"}
  ]
}' > "$FATQ_ROOT/in_progress/20260808-0000-b2b2-assigned-to-self-checkpoint.json"

# Two same-day cron nudges must retain the existing daily limit of two.
jq -n --arg old "$old_ts" --arg n1 "$nudge_one_ts" --arg n2 "$nudge_two_ts" '{
  task_id:"20260808-0000-c3c3-daily-nudge-cap", status:"in_progress",
  assigned:"anna", reviewer:"yitang",
  history:[
    {ts:$old,by:"anna",action:"claim"},
    {ts:$n1,by:"fatq-dispatch-cron",action:"nudge"},
    {ts:$n2,by:"fatq-dispatch-cron",action:"nudge"}
  ]
}' > "$FATQ_ROOT/in_progress/20260808-0000-c3c3-daily-nudge-cap.json"

dispatch_output="$(bash "$DISPATCH_SH" 2>&1)"
printf '%s\n' "$dispatch_output"

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$name"
    fail=$((fail + 1))
  fi
}

check assigned_external_comment_nudges test -f "$FATQ_RELAY_DIR/fatq-20260808-0000-a1a1-assigned-external-comment-in_progress-e1-a1-nudge.json"
check assigned_to_self_checkpoint_suppresses test ! -e "$FATQ_RELAY_DIR/fatq-20260808-0000-b2b2-assigned-to-self-checkpoint-in_progress-e1-a1-nudge.json"
check daily_nudge_limit_suppresses_third grep -q 'task=20260808-0000-c3c3-daily-nudge-cap decision=skip:daily_nudge_limit' <<<"$dispatch_output"
check isolated_root test "$FATQ_ROOT" = "$TMPROOT/tasks"
check isolated_relay test "$FATQ_RELAY_DIR" = "$TMPROOT/relay"

printf 'RESULT pass=%d fail=%d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

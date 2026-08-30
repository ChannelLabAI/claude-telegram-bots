#!/usr/bin/env bash
set -uo pipefail

cli="${1:?usage: same-shape-flag-repro.sh /path/to/fatq-cli.sh}"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export FATQ_ROOT="$root/tasks"
export FATQ_RELAY_DIR="$root/relay"
export FATQ_TEAM_CONFIG="$root/team-config.json"
export FATQ_DISPATCH_AFFINITY="$root/dispatch-affinity.json"
export FATQ_BOT_ROUTING="$root/bot-routing.yml"
export FATQ_CREATE_GATE_DISABLED=1
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review} "$FATQ_RELAY_DIR"

printf '%s\n' '{"assistants":[{"state_dir":"anya"}],"shared_pools":{"builder":[{"state_dir":"anna"}],"reviewer":[{"state_dir":"bella"}],"designer":[]},"external_identities":[]}' > "$FATQ_TEAM_CONFIG"
printf '%s\n' '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"
printf '%s\n' 'bot_roster: []' > "$FATQ_BOT_ROUTING"

make_task() {
  local path="$1" task_id="$2" status="$3"
  jq -n --arg task_id "$task_id" --arg status "$status" \
    '{task_id:$task_id,slug:$task_id,status:$status,assigned:"anna",reviewer:"bella",history:[],verify_commands:[]}' > "$path"
}

run_case() {
  local label="$1" task_id="$2" task_file
  shift 2
  local output rc
  set +e
  output="$(bash "$cli" "$@" 2>&1)"
  rc=$?
  set -e
  task_file="$(find "$FATQ_ROOT" -mindepth 2 -maxdepth 2 -type f -name "${task_id}.json" -print -quit)"
  printf 'CASE=%s\nCLI_OUTPUT=%s\nEXIT_CODE=%s\nTASK_JSON=%s\n' \
    "$label" "$output" "$rc" "$(jq -c '{status,assigned,attachments,history}' "$task_file")"
}

make_task "$FATQ_ROOT/in_progress/repro-reassign.json" repro-reassign in_progress
run_case REASSIGN repro-reassign \
  reassign repro-reassign --as anya --to --reason 'some real reason text'

make_task "$FATQ_ROOT/pending/repro-comment.json" repro-comment pending
run_case COMMENT repro-comment \
  comment repro-comment --text --as anya 'real closeout evidence text must not disappear'

make_task "$FATQ_ROOT/pending/repro-attach.json" repro-attach pending
run_case ATTACH_FILE repro-attach \
  attach repro-attach --as anna --file --mime image/png --name screenshot.png --mime image/png --size 1

make_task "$FATQ_ROOT/pending/repro-attach-name.json" repro-attach-name pending
run_case ATTACH_NAME repro-attach-name \
  attach repro-attach-name --as anna --name --mime image/png --mime image/png --file screenshot.png --size 1

make_task "$FATQ_ROOT/pending/repro-attach-mime.json" repro-attach-mime pending
run_case ATTACH_MIME repro-attach-mime \
  attach repro-attach-mime --as anna --mime --size 999 --size 1 --name screenshot.png --file screenshot.png

jq -n '{task_id:"repro-approval",slug:"repro-approval",status:"approval_pending",assigned:"anna",reviewer:"bella",history:[],verify_commands:[],approval:{status:"pending",approvers:["anya"],return_state:"pending"}}' \
  > "$FATQ_ROOT/approval_pending/repro-approval.json"
run_case APPROVAL_EVIDENCE repro-approval \
  approval approve repro-approval --as anya --evidence --reason 'real approval evidence must not disappear'

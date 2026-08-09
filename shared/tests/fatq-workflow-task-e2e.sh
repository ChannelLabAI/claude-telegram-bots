#!/usr/bin/env bash
# Isolated create -> relay -> foreground graph -> result/comment -> review -> deliver_to E2E.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../bin/fatq-cli.sh"
RUNNER="$SCRIPT_DIR/../bin/fatq-workflow-task.sh"
DISPATCH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"
WATCH="$SCRIPT_DIR/../bin/fatq-watch.sh"
PROD_ROOT="/home/oldrabbit/.claude-bots/tasks"
PASS=0
FAIL=0
TMPROOT=""

ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1" >&2; }
assert() { local name="$1"; shift; if "$@" >/dev/null; then ok "$name"; else bad "$name"; fi; }

cleanup() { [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

TMPROOT="$(mktemp -d)"
export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_STATE_DIR="$TMPROOT/dispatch-state"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_TRUST_LEDGER="$TMPROOT/trust.tsv"
export FATQ_TRUST_LEDGER_AUDIT="$TMPROOT/trust-audit.jsonl"
export FATQ_OVERRIDE_AUDIT="$TMPROOT/override-audit.jsonl"
export FATQ_CREATE_GATE_DISABLED=1
export FATQ_MATTERMOST_DISABLE=1
export FATQ_WORKFLOW_RUNNERS=codex-collaboration

[[ "$(realpath -m "$FATQ_ROOT")" != "$(realpath -m "$PROD_ROOT")" ]] || {
  echo "FATAL isolated FATQ_ROOT guard failed" >&2
  exit 2
}
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived,assets} \
  "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"

jq -n '{
  assistants:[{state_dir:"anya",bot_username:"@anya"}],
  shared_pools:{
    builder:[{state_dir:"anna",bot_username:"@anna"}],
    reviewer:[{state_dir:"bella",bot_username:"@bella"}],
    designer:[]
  }, external_identities:["laotu"]
}' > "$FATQ_TEAM_CONFIG"
jq -n '{infra_patterns:[],lines:{default:{builder:"anna",reviewer:"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"
# Avoid completion backlog seeding in this fresh fixture; the task under test is new.
: > "$FATQ_STATE_DIR/completion_notify_seeded"

run_cli() { timeout 30 bash "$CLI" "$@"; }
run_runner() { timeout 30 bash "$RUNNER" "$@"; }
run_dispatch() { timeout 30 bash "$DISPATCH"; }

workflow_json() {
  local body="$1" sha="$2" deadline_ms="${3:-5000}"
  jq -cn --arg body "$body" --arg sha "$sha" --argjson deadline "$deadline_ms" '{
    schema:"fatq.workflow/v1", runner:"codex-collaboration",
    source:{kind:"inline",body:$body,sha256:$sha}, args:{fixture:true},
    budget:{deadlineMs:$deadline,maxParallelAgents:2},
    outputs:{
      root:"/home/oldrabbit/.claude-bots/tasks/assets/${task_id}",
      attemptDir:"attempt-${attempt}", agentDir:"agents",
      resultManifest:"/home/oldrabbit/.claude-bots/tasks/assets/${task_id}/result.json"
    },
    failure:{workerLoss:"restart-from-zero",automaticAttempts:1,preservePartialAttempts:true}
  }'
}

create_task() {
  local slug="$1" workflow="$2" output task_id
  output="$(run_cli create --as anya --slug "$slug" --assigned anna --reviewer bella --deliver_to anya \
    --goal "workflow fixture $slug" --background fixture --context isolated \
    --deliverables '["result"]' --acceptance_criteria '["terminal"]' --out_of_scope '["production"]' \
    --review_focus workflow --workflow "$workflow" --no-live-verify "isolated E2E fixture")" || return 1
  task_id="$(sed -n 's/.*create OK: \([^ ]*\).*/\1/p' <<< "$output")"
  [[ -n "$task_id" ]] || return 1
  printf '%s\n' "$task_id"
}

# Success path: dispatcher is invoked synchronously, so this test has no dependency
# on the d710 watcher/cron timing path.
body='{"nodes":["left","right"]}'
sha="$(printf '%s' "$body" | sha256sum | awk '{print $1}')"
workflow="$(workflow_json "$body" "$sha")"
if create_task workflow-invalid 'not-json' >/dev/null 2>&1; then bad malformed_workflow_rejected; else ok malformed_workflow_rejected; fi
task_id="$(create_task workflow-success "$workflow")" || { echo "FATAL create failed" >&2; exit 1; }
task_pending="$FATQ_ROOT/pending/$task_id.json"
assert create_preserves_workflow jq -e --arg sha "$sha" '.workflow.source.sha256==$sha' "$task_pending"

run_dispatch >/dev/null
assert explicit_dispatch_created_relay bash -c 'compgen -G "$1/fatq-*pending*d1*a1*dispatch.json" >/dev/null' _ "$FATQ_RELAY_DIR"
run_cli claim "$task_id" --as anna >/dev/null
task_in_progress="$FATQ_ROOT/in_progress/$task_id.json"
assert workflow_in_spec_hash jq -e '[.history[]|select(.action=="claim")][-1].spec_fields|index("workflow")' "$task_in_progress"

attempt_dir="$(run_runner prepare "$task_id" --as anna --attempt 1)" || { echo "FATAL prepare failed" >&2; exit 1; }
start_ms="$(date +%s%3N)"
timeout 3 bash -c 'sleep 0.4; printf left > "$1"' _ "$attempt_dir/agents/left.txt" &
p1=$!
timeout 3 bash -c 'sleep 0.4; printf right > "$1"' _ "$attempt_dir/agents/right.txt" &
p2=$!
wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
elapsed_ms=$(( $(date +%s%3N) - start_ms ))
assert parallel_nodes_succeeded test "$rc1" -eq 0
assert parallel_nodes_succeeded_2 test "$rc2" -eq 0
assert graph_was_parallel test "$elapsed_ms" -lt 900

result_input="$attempt_dir/result-input.json"
jq -n --arg task "$task_id" --arg root "$FATQ_ROOT/assets/$task_id" --arg sha "$sha" '{
  schema:"fatq.workflow-result/v1",taskId:$task,attempt:1,runner:"codex-collaboration",
  runId:"fixture-success",status:"succeeded",startedAt:"fixture",finishedAt:"fixture",
  sourceSha256:$sha,
  nodes:[
    {key:"left",status:"succeeded",artifacts:[$root+"/attempt-1/agents/left.txt"]},
    {key:"right",status:"succeeded",artifacts:[$root+"/attempt-1/agents/right.txt"]}
  ], artifacts:[$root+"/result.json"], error:null, summary:"two nodes complete"
}' > "$result_input"
result_path="$(run_runner commit "$task_id" --as anna --attempt 1 --result "$result_input")" || { echo "FATAL commit failed" >&2; exit 1; }
assert result_manifest_exists test -f "$result_path"
assert workflow_comment_once bash -c '[[ $(jq '\''[.history[]|select(.action=="comment" and (.text|startswith("[WORKFLOW RESULT]")))]|length'\'' "$1") -eq 1 ]]' _ "$task_in_progress"
run_cli submit "$task_id" --as anna >/dev/null
assert submitted_to_review test -f "$FATQ_ROOT/review/$task_id.json"
run_cli verdict approve "$task_id" --as bella --reason "fixture approve" >/dev/null
assert approved_to_done test -f "$FATQ_ROOT/done/$task_id.json"
run_dispatch >/dev/null
delivery_relay="$(grep -l -- "$result_path" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -n 1)"
assert deliver_to_relay_contains_result test -n "$delivery_relay"
assert delivery_targets_anya jq -e '.recipient=="anya"' "$delivery_relay"

# SHA mismatch: fail closed before attempt/agent directories exist.
bad_workflow="$(workflow_json 'sha mismatch body' '0000000000000000000000000000000000000000000000000000000000000000')"
bad_id="$(create_task workflow-sha-mismatch "$bad_workflow")"
run_cli claim "$bad_id" --as anna >/dev/null
if run_runner prepare "$bad_id" --as anna --attempt 1 >/dev/null 2>&1; then bad sha_mismatch_fails_closed; else ok sha_mismatch_fails_closed; fi
assert sha_mismatch_has_no_agent_artifacts test ! -d "$FATQ_ROOT/assets/$bad_id/attempt-1/agents"
assert sha_mismatch_task_stays_in_progress test -f "$FATQ_ROOT/in_progress/$bad_id.json"
assert sha_mismatch_comment jq -e 'any(.history[]; .action=="comment" and (.text|contains("source_sha_mismatch")))' "$FATQ_ROOT/in_progress/$bad_id.json"

# Node failure: publish an auditable failed manifest, but never submit/deliver.
fail_id="$(create_task workflow-node-failure "$workflow")"
run_cli claim "$fail_id" --as anna >/dev/null
fail_attempt="$(run_runner prepare "$fail_id" --as anna --attempt 1)"
printf ok > "$fail_attempt/agents/a.txt"
fail_input="$fail_attempt/failure-input.json"
jq -n --arg task "$fail_id" --arg root "$FATQ_ROOT/assets/$fail_id" --arg sha "$sha" '{
  schema:"fatq.workflow-result/v1",taskId:$task,attempt:1,runner:"codex-collaboration",
  runId:"fixture-failure",status:"failed",startedAt:"fixture",finishedAt:"fixture",sourceSha256:$sha,
  nodes:[{key:"a",status:"succeeded",artifacts:[$root+"/attempt-1/agents/a.txt"]},{key:"b",status:"failed",artifacts:[]}],
  artifacts:[],error:{node:"b",message:"fixture exit 7"},summary:"node b failed"
}' > "$fail_input"
run_runner commit "$fail_id" --as anna --attempt 1 --result "$fail_input" >/dev/null
assert node_failure_manifest jq -e '.status=="failed" and .error.node=="b"' "$FATQ_ROOT/assets/$fail_id/result.json"
if run_cli submit "$fail_id" --as anna >/dev/null 2>&1; then bad node_failure_submit_blocked; else ok node_failure_submit_blocked; fi
assert node_failure_not_submitted test -f "$FATQ_ROOT/in_progress/$fail_id.json"
assert node_failure_no_delivery bash -c '! grep -R -q -- "$1" "$2"' _ "$fail_id" "$FATQ_RELAY_DIR"

# Cap simulation: production is 5,400,000 ms in gateway; fixture injects a 1s
# outer timeout. prepare happens first, so kill cannot erase partial evidence.
cap_workflow="$(workflow_json "$body" "$sha" 1000)"
cap_id="$(create_task workflow-cap "$cap_workflow")"
run_cli claim "$cap_id" --as anna >/dev/null
cap_attempt="$(run_runner prepare "$cap_id" --as anna --attempt 1)"
if timeout 1 bash -c 'sleep 2'; then bad cap_timeout_triggered; else [[ $? -eq 124 ]] && ok cap_timeout_triggered || bad cap_timeout_triggered; fi
run_cli comment "$cap_id" --as anna --text '[gateway worker terminated] reason=wall_clock_cap fixture_deadline_ms=1000 production_worker_cap_ms=5400000' >/dev/null
assert cap_preserves_partial jq -e '.status=="running" and .deadlineMs==1000' "$cap_attempt/partial-attempt.json"
assert cap_is_diagnosable jq -e 'any(.history[]; .action=="comment" and (.text|contains("reason=wall_clock_cap")))' "$FATQ_ROOT/in_progress/$cap_id.json"

# Rollout compatibility: an old five-field claim must not become stale merely
# because workflow joined the new hash. A new workflow claim must detect edits.
legacy_id="legacy-five-field-claim"
legacy_file="$FATQ_ROOT/in_progress/$legacy_id.json"
legacy_payload='{"acceptance_criteria":[],"context":"c","deliverables":[],"goal":"g","out_of_scope":[]}'
legacy_hash="$(printf '%s\n' "$legacy_payload" | sha256sum | awk '{print $1}')"
jq -n --arg id "$legacy_id" --arg hash "$legacy_hash" '{
  task_id:$id,status:"in_progress",assigned:"anna",goal:"g",context:"c",
  acceptance_criteria:[],deliverables:[],out_of_scope:[],history:[{
    action:"claim",spec_hash:$hash,
    spec_fields:["goal","context","acceptance_criteria","deliverables","out_of_scope"],field_hashes:{}
  }]
}' > "$legacy_file"
FATQ_WATCH_SKIP_INITIAL_DISPATCH=1 FATQ_WATCH_RUN_ONCE=1 INOTIFYWAIT_BIN=/bin/true \
  FATQ_WATCH_LOG="$TMPROOT/watch.log" timeout 30 bash "$WATCH"
assert legacy_claim_not_false_stale bash -c '! compgen -G "$1/*spec-staleness*.json" >/dev/null' _ "$FATQ_RELAY_DIR"
cap_tmp="$(mktemp "$FATQ_ROOT/in_progress/.workflow-edit.XXXXXX")"
jq '.workflow.args.changed=true' "$FATQ_ROOT/in_progress/$cap_id.json" > "$cap_tmp"
mv -f "$cap_tmp" "$FATQ_ROOT/in_progress/$cap_id.json"
FATQ_WATCH_SKIP_INITIAL_DISPATCH=1 FATQ_WATCH_RUN_ONCE=1 INOTIFYWAIT_BIN=/bin/true \
  FATQ_WATCH_LOG="$TMPROOT/watch.log" timeout 30 bash "$WATCH"
assert workflow_edit_detected jq -e 'any(.history[]; .action=="spec_staleness_notified" and (.changed_fields|index("workflow")))' "$FATQ_ROOT/in_progress/$cap_id.json"

echo "RESULT: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]]

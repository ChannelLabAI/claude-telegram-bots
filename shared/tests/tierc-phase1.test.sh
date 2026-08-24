#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/fatq-cli.sh"
VERIFY="$HERE/../bin/fatq-verify.sh"
POLICY="$HERE/../lib/fatq-gate-policy.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tierc-phase1.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

export FATQ_ROOT="$tmp/tasks"
export FATQ_PROD_ROOT="$tmp/not-production"
export FATQ_TEAM_CONFIG="$tmp/team-config.json"
export FATQ_BOT_ROUTING="$tmp/bot-routing.yml"
export FATQ_DISPATCH_AFFINITY="$tmp/dispatch-affinity.json"
export FATQ_VERIFY_SH="$VERIFY"
export FATQ_GATE_POLICY_FILE="$POLICY"
export FATQ_BLOCKING_LIB="$HERE/../lib/fatq-blocking.sh"
export FATQ_RELAY_DIR="$tmp/relay"
export FATQ_OVERRIDE_AUDIT="$tmp/override-audit.jsonl"
export FATQ_TRUST_LEDGER_AUDIT="$tmp/trust-ledger.jsonl"
export FATQ_NOW_ISO="2026-08-24T20:00:00+08:00"
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR"

jq -n '{assistants:[{state_dir:"anya"}],shared_pools:{builder:[{state_dir:"anna"}],reviewer:[{state_dir:"bella"}],designer:[]},external_identities:[]}' > "$FATQ_TEAM_CONFIG"
printf '%s\n' 'bot_roster:' '  - id: bella' '    directory: bella' '    role: reviewer' 'reviewers:' '  - id: bella' > "$FATQ_BOT_ROUTING"
jq -n '{infra_patterns:[],lines:{default:{builder:"anna",reviewer:"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"

make_review_task() {
  local id="$1"
  jq -n --arg id "$id" '{task_id:$id,slug:$id,status:"review",assigned:"anna",reviewer:"bella",verify_commands:[{cmd:["/bin/sh","-c","echo g09-positive-control >&2; exit 9"],expect_exit:0}],history:[]}' > "$FATQ_ROOT/review/$id.json"
}

make_done_task() {
  local id="$1"
  jq -n --arg id "$id" '{task_id:$id,slug:$id,status:"done",assigned:"anna",reviewer:"bella",history:[{ts:"2026-08-24T19:59:00+08:00",by:"bella",via:"fatq-cli",action:"verdict_approve",from:"review/",to:"done/"}],live_verify_commands:[{cmd:["/bin/sh","-c","echo probe-failed; echo probe-detail >&2; exit 7"],expect_exit:0}],closeout:{state:"pending",host_effect_policy:"required_for_commits"}}' > "$FATQ_ROOT/done/$id.json"
}

make_review_task g09-disabled
disabled_output="$(FATQ_G09_BLOCKING=0 bash "$CLI" verdict approve g09-disabled --as bella 2>&1)"
[[ -f "$FATQ_ROOT/done/g09-disabled.json" ]]
grep -Fq 'G09 verifier blocking is disabled' <<< "$disabled_output"

make_review_task g09-restored
set +e
restored_output="$(FATQ_G09_BLOCKING=1 bash "$CLI" verdict approve g09-restored --as bella 2>&1)"
restored_rc=$?
set -e
[[ "$restored_rc" -eq 5 ]]
[[ -f "$FATQ_ROOT/review/g09-restored.json" ]]
grep -Fq 'g09-positive-control' <<< "$restored_output"
grep -Fq 'verify gate' <<< "$restored_output"

make_done_task g12-advisory
advisory_output="$(FATQ_G12_BLOCKING=0 bash "$CLI" closeout g12-advisory --as deploy-pipeline --state closed \
  --deploy-evidence '{"commits":["deadbeef"],"services_restarted":[]}' \
  --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"fixture failed probe remains visible"}' 2>&1)"
grep -Fq 'probe-failed' <<< "$advisory_output"
grep -Fq 'G12 advisory probe failed' <<< "$advisory_output"
jq -e '.closeout.state == "closed" and .closeout.host_effect_proof.result == "fail" and .closeout.host_effect_proof.commands[0].actual_exit == 7 and (.closeout.host_effect_proof.commands[0].stdout.sample | contains("probe-failed")) and (.closeout.host_effect_proof.commands[0].stderr.sample | contains("probe-detail"))' "$FATQ_ROOT/done/g12-advisory.json" >/dev/null

make_done_task g12-restored
set +e
blocking_output="$(FATQ_G12_BLOCKING=1 bash "$CLI" closeout g12-restored --as deploy-pipeline --state closed \
  --deploy-evidence '{"commits":["deadbeef"],"services_restarted":[]}' \
  --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"fixture rollback"}' 2>&1)"
blocking_rc=$?
set -e
[[ "$blocking_rc" -eq 4 ]]
[[ "$(jq -r '.closeout.state' "$FATQ_ROOT/done/g12-restored.json")" == "pending" ]]
grep -Fq '主機生效探針失敗' <<< "$blocking_output"

printf '%s\n' '--- G09 disabled approval output ---' "$disabled_output"
printf '%s\n' '--- G09 restored positive-control output ---' "$restored_output"
printf '%s\n' '--- G12 advisory failed-probe closeout output ---' "$advisory_output"
printf '%s\n' '--- G12 restored blocking output ---' "$blocking_output"
echo "tierc phase1 tests PASS (G09 disabled/restored; G12 advisory evidence/restored blocking)"

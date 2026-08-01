#!/usr/bin/env bash
# Focused negative fixture. Exit 0 only when a commit-only closeout is blocked
# because its real host registration probe fails.
set -uo pipefail

CLI_SH="${1:?usage: $0 <fatq-cli.sh> <fatq-verify.sh>}"
VERIFY_SH="${2:?usage: $0 <fatq-cli.sh> <fatq-verify.sh>}"
FIXTURE_ROOT="${3:?usage: $0 <fatq-cli.sh> <fatq-verify.sh> <fixture-root>}"
FATQ_ROOT="$FIXTURE_ROOT/tasks"
export FATQ_ROOT FATQ_VERIFY_SH="$VERIFY_SH"
export FATQ_TEAM_CONFIG="$FIXTURE_ROOT/team-config.json"
export FATQ_RELAY_DIR="$FIXTURE_ROOT/relay"
export FATQ_DISPATCH_AFFINITY="$FIXTURE_ROOT/dispatch-affinity.json"
export FATQ_ENFORCEMENT_KILL_SWITCH="$FATQ_ROOT/.fatq-enforcement-off"
export FATQ_CREATE_GATE_DISABLED=1
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR"

printf '%s\n' '{"assistants":[{"state_dir":"anya"}],"shared_pools":{"builder":[{"state_dir":"anna"}],"reviewer":[{"state_dir":"bella"}]},"external_identities":[]}' > "$FATQ_TEAM_CONFIG"
printf '%s\n' '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"

task="$FATQ_ROOT/done/host-effect-negative.json"
missing="$FIXTURE_ROOT/host-registration-that-does-not-exist"
jq -n --arg missing "$missing" '{
  task_id:"host-effect-negative", slug:"historical-diana-or-2438", status:"done",
  reviewer:"bella", history:[],
  live_verify_commands:[{cmd:["test","-f",$missing],expect_exit:0}],
  closeout:{state:"pending",host_effect_policy:"required_for_commits"}
}' > "$task"

rc=0
bash "$CLI_SH" closeout host-effect-negative --as anya \
  --deploy-evidence '{"commits":["git-only"],"services_restarted":[]}' \
  --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"commit exists"}' \
  --state closed >/dev/null 2>&1 || rc=$?

[[ "$rc" -eq 4 ]] || exit 1
jq -e '.closeout == {state:"pending",host_effect_policy:"required_for_commits"}' "$task" >/dev/null || exit 1
exit 0

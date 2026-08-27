#!/usr/bin/env bash
# Permission-matrix regression for keeper's owner-approved FATQ admin parity.
# All mutations run against a disposable queue; production tasks are never read or written.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"
VERIFY_SH="$SCRIPT_DIR/../bin/fatq-verify.sh"
PROD_ROOT="/home/oldrabbit/.claude-bots/tasks"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_VERIFY_SH="$VERIFY_SH"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_BOT_ROUTING="$TMPROOT/bot-routing.yml"
export FATQ_OVERRIDE_AUDIT="$TMPROOT/override-audit.jsonl"
export FATQ_CREATE_GATE_DISABLED=1

if [[ "$FATQ_ROOT" == "$PROD_ROOT" || "$FATQ_ROOT" == "$PROD_ROOT/" ]]; then
  echo "FATAL: fixture FATQ_ROOT resolved to production" >&2
  exit 2
fi

mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived}
mkdir -p "$FATQ_RELAY_DIR"

cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{
  "assistants": [{"state_dir":"anya"},{"state_dir":"keeper"}],
  "shared_pools": {
    "builder": [{"state_dir":"anna"},{"state_dir":"sancai"}],
    "reviewer": [{"state_dir":"bella"}],
    "designer": []
  },
  "external_identities": ["deploy-pipeline","laotu"]
}
EOF

cat > "$FATQ_DISPATCH_AFFINITY" <<'EOF'
{
  "infra_patterns": ["shared/", "systemd", "schema"],
  "lines": {"default":{"builder":"anna","reviewer":"bella"}}
}
EOF

cat > "$FATQ_BOT_ROUTING" <<'EOF'
bot_roster:
  - id: bella
    directory: bella
    role: reviewer
reviewers:
  - id: bella
EOF

make_task() {
  local state="$1" task_id="$2" body="$3"
  jq -n --arg task_id "$task_id" --arg status "$state" --argjson body "$body" \
    '$body + {task_id:$task_id,status:$status,history:($body.history // [])}' \
    > "$FATQ_ROOT/$state/$task_id.json"
}

run_expect() {
  local label="$1" expected="$2"
  shift 2
  local output rc
  echo "COMMAND[$label]: $*"
  if output="$("$@" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    echo "<no output>"
  fi
  echo "EXIT[$label]: $rc"
  if [[ "$rc" -ne "$expected" ]]; then
    echo "FAIL[$label]: expected exit $expected" >&2
    return 1
  fi
}

run_denied() {
  local label="$1"
  shift
  local output rc
  echo "COMMAND[$label]: $*"
  if output="$("$@" 2>&1)"; then rc=0; else rc=$?; fi
  printf '%s\n' "${output:-<no output>}"
  echo "EXIT[$label]: $rc"
  if [[ "$rc" -ne 3 || ( "$output" != *"identity anna"* && "$output" != *"僅 anya/keeper"* ) ]]; then
    echo "FAIL[$label]: anna was not rejected by the permission gate" >&2
    return 1
  fi
}

make_task pending keeper-cancel '{"assigned":"anna"}'
run_expect keeper-cancel 0 bash "$CLI_SH" cancel keeper-cancel --as keeper --reason fixture

make_task in_progress keeper-reassign '{"assigned":"anna"}'
run_expect keeper-reassign 0 bash "$CLI_SH" reassign keeper-reassign --as keeper --to sancai

make_task done keeper-archive '{}'
run_expect keeper-archive 0 bash "$CLI_SH" archive keeper-archive --as keeper

make_task pending keeper-hold '{"assigned":"sancai"}'
run_expect keeper-hold 0 bash "$CLI_SH" hold keeper-hold --as keeper --until 2030-08-01T00:00:00+08:00

make_task in_progress keeper-set-live '{"assigned":"sancai","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
run_expect keeper-set-live 0 bash "$CLI_SH" set-live-verify keeper-set-live --as keeper \
  --value '[{"cmd":["true"],"expect_exit":0}]' --reason fixture

make_task done keeper-closeout '{"assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
run_expect keeper-closeout 0 bash "$CLI_SH" closeout keeper-closeout --as keeper \
  --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"fixture artifact"}' \
  --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"fixture reviewed"}' \
  --state closed

make_task done keeper-closeout-no-host-effect '{"assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
run_expect keeper-closeout-no-host-effect 0 bash "$CLI_SH" closeout keeper-closeout-no-host-effect --as keeper \
  --no-host-effect 'fixture has no host mutation' --state closed

make_task done keeper-closeout-unverified '{"assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
run_expect keeper-closeout-unverified 0 bash "$CLI_SH" closeout keeper-closeout-unverified --as keeper \
  --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
  --unverified 'fixture predates live probe' --state closed

make_task done keeper-finalize '{"assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
run_expect keeper-finalize-sign 0 bash "$CLI_SH" closeout keeper-finalize --as keeper \
  --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"fixture artifact"}' \
  --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"fixture reviewed"}' \
  --state pending
if [[ "$(jq -r '.closeout.deploy_evidence.by' "$FATQ_ROOT/done/keeper-finalize.json")" != "keeper" ]]; then
  echo "FAIL[keeper-finalize-sign]: fixture was not signed by keeper" >&2
  exit 1
fi
run_expect keeper-finalize 0 bash "$CLI_SH" finalize-existing keeper-finalize --as keeper

make_task in_progress keeper-update-skills '{"assigned":"anna","created_by":"anya"}'
run_expect keeper-update-skills 0 bash "$CLI_SH" update-field keeper-update-skills skills --as keeper --value '["fixture"]'
make_task in_progress keeper-update-deliver '{"assigned":"anna","created_by":"anya","deliver_to":"anya"}'
run_expect keeper-update-deliver 0 bash "$CLI_SH" update-field keeper-update-deliver deliver_to --as keeper --value '"sancai"'
make_task in_progress keeper-update-reviewer '{"assigned":"anna","created_by":"anya","goal":"normal task","context":"fixture","deliverables":["fixture"]}'
run_expect keeper-update-reviewer 0 bash "$CLI_SH" update-field keeper-update-reviewer reviewer --as keeper --value '"bella"'

make_task pending keeper-force '{"assigned":"anna"}'
run_expect keeper-force 0 bash "$CLI_SH" force-mv keeper-force review --as keeper --reason fixture

# AC3: execution permission is granted, but evidence authority remains separate.
make_task done keeper-self-verify '{"assigned":"keeper","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
if self_output="$(bash "$CLI_SH" closeout keeper-self-verify --as keeper \
  --live-check '{"verified_by":"keeper","method":"reviewer-live","evidence":"self signed"}' \
  --state pending 2>&1)"; then self_rc=0; else self_rc=$?; fi
printf '%s\n' "COMMAND[keeper-self-verify]: bash $CLI_SH closeout keeper-self-verify --as keeper --live-check <verified_by=keeper> --state pending"
printf '%s\n' "$self_output"
echo "EXIT[keeper-self-verify]: $self_rc"
if [[ "$self_rc" -ne 3 || "$self_output" != *"assigned builder"* ]]; then
  echo "FAIL[keeper-self-verify]: assigned-builder evidence guard was weakened" >&2
  exit 1
fi

make_task pending anna-cancel '{"assigned":"sancai"}'
run_denied anna-cancel bash "$CLI_SH" cancel anna-cancel --as anna --reason fixture
make_task in_progress anna-reassign '{"assigned":"sancai"}'
run_denied anna-reassign bash "$CLI_SH" reassign anna-reassign --as anna --to sancai
make_task done anna-archive '{}'
run_denied anna-archive bash "$CLI_SH" archive anna-archive --as anna
make_task pending anna-hold '{"assigned":"sancai"}'
run_denied anna-hold bash "$CLI_SH" hold anna-hold --as anna --until 2030-08-01T00:00:00+08:00
make_task in_progress anna-set-live '{"assigned":"sancai","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending"}}'
run_denied anna-set-live bash "$CLI_SH" set-live-verify anna-set-live --as anna --value '[{"cmd":["true"]}]' --reason fixture
make_task done anna-closeout '{"assigned":"sancai","reviewer":"bella","closeout":{"state":"pending"}}'
run_denied anna-closeout bash "$CLI_SH" closeout anna-closeout --as anna --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"fixture"}' --state pending
make_task done anna-finalize '{"assigned":"sancai","reviewer":"bella","closeout":{"state":"pending"}}'
run_denied anna-finalize bash "$CLI_SH" finalize-existing anna-finalize --as anna
make_task in_progress anna-update '{"assigned":"sancai","created_by":"anya"}'
run_denied anna-update bash "$CLI_SH" update-field anna-update skills --as anna --value '["fixture"]'
make_task pending anna-force '{"assigned":"sancai"}'
run_denied anna-force bash "$CLI_SH" force-mv anna-force review --as anna --reason fixture

echo "[fatq-keeper-permission-parity-test] PASS"

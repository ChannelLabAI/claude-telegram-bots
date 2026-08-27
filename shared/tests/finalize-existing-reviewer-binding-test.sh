#!/usr/bin/env bash
# Regression fixture for finalize-existing reviewer-live identity binding.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="${FATQ_CLI_UNDER_TEST:-$SCRIPT_DIR/../bin/fatq-cli.sh}"
PROD_ROOT="/home/oldrabbit/.claude-bots/tasks"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_BOT_ROUTING="$TMPROOT/bot-routing.yml"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_G12_BLOCKING=1

if [[ "$FATQ_ROOT" == "$PROD_ROOT" || "$FATQ_ROOT" == "$PROD_ROOT/" ]]; then
  echo "[finalize-binding-test] FATAL: refusing production FATQ_ROOT" >&2
  exit 2
fi

mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR"

cat > "$FATQ_TEAM_CONFIG" <<'JSON'
{
  "assistants": [{"state_dir":"anya"}],
  "shared_pools": {
    "builder": [{"state_dir":"anna"}],
    "reviewer": [{"state_dir":"bella"}, {"state_dir":"yitang"}]
  },
  "external_identities": []
}
JSON

cat > "$FATQ_BOT_ROUTING" <<'YAML'
reviewers:
  - id: bella
  - id: yitang
YAML

cat > "$FATQ_DISPATCH_AFFINITY" <<'JSON'
{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}
JSON

pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "PASS $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name" >&2
  fi
}

make_task() {
  local task_id="$1" verified_by="$2"
  jq -n --arg task_id "$task_id" --arg verified_by "$verified_by" '
    {
      task_id:$task_id,
      status:"done",
      assigned:"anna",
      reviewer:"bella",
      live_verify_commands:[],
      closeout:{
        state:"pending",
        host_effect_policy:"required_for_commits",
        deploy_evidence:{
          commits:[], services_restarted:[], not_applicable:true,
          reason:"fixture only", by:"anya", ts:"2026-08-27T11:00:00+08:00"
        },
        live_check:{
          verified_by:$verified_by, method:"reviewer-live",
          evidence:"fixture review", ts:"2026-08-27T11:01:00+08:00"
        }
      },
      history:[
        {ts:"2026-08-27T10:59:00+08:00",by:"bella",action:"verdict_approve"}
      ]
    }
  ' > "$FATQ_ROOT/done/$task_id.json"
}

run_case() {
  local label="$1" task_id="$2" verified_by="$3" expected_rc="$4" expected_text="$5"
  local output rc state
  make_task "$task_id" "$verified_by"
  output="$(bash "$CLI_SH" finalize-existing "$task_id" --as anya 2>&1)"
  rc=$?
  state="$(jq -r '.closeout.state' "$FATQ_ROOT/done/$task_id.json")"
  echo "EVIDENCE $label command: FATQ_ROOT=<fixture> $CLI_SH finalize-existing $task_id --as anya"
  echo "EVIDENCE $label exit=$rc state=$state output=$output"
  check "$label exit=$expected_rc" test "$rc" -eq "$expected_rc"
  check "$label diagnostic" grep -Fq "$expected_text" <<< "$output"
}

run_case "AC1 arbitrary identity rejected" "binding-nobody" "nobody" 4 \
  "本單實際審查者是 bella（來源：verdict 歷史），live_check.verified_by 是 nobody"

run_case "AC2 actual reviewer accepted" "binding-actual" "bella" 0 \
  "finalize-existing OK: binding-actual state=closed by=anya"
check "AC2 persisted closed state" test "$(jq -r '.closeout.state' "$FATQ_ROOT/done/binding-actual.json")" = "closed"

run_case "AC3 assigned builder rejected" "binding-self" "anna" 4 \
  "live_check.verified_by(anna) 是本單 assigned builder，不得自我放行"

echo "[finalize-binding-test] RESULT: $pass pass, $fail fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "[finalize-binding-test] All cases passed"

#!/usr/bin/env bash
# Fixture-first regression for canonical cancelled/ task termination.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"
DISPATCH_SH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"
AUDIT_SH="$SCRIPT_DIR/../bin/fatq-void-dispatch-audit.sh"
BASE_EPOCH=1783000000
PROD_ROOT=/home/oldrabbit/.claude-bots/tasks
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

fail() { echo "FAIL $*" >&2; exit 1; }

setup_fixture() {
  local name="$1"
  export FATQ_ROOT="$TMPROOT/$name/tasks"
  export FATQ_RELAY_DIR="$TMPROOT/$name/relay"
  export FATQ_STATE_DIR="$TMPROOT/$name/state"
  export FATQ_TEAM_CONFIG="$TMPROOT/$name/team-config.json"
  export FATQ_DISPATCH_AFFINITY="$TMPROOT/$name/dispatch-affinity.json"
  export FATQ_BOT_ROUTING="$TMPROOT/$name/bot-routing.yml"
  export FATQ_OVERRIDE_AUDIT="$TMPROOT/$name/override-audit.jsonl"
  export FATQ_TRUST_LEDGER_AUDIT="$TMPROOT/$name/trust-ledger.jsonl"
  export FATQ_DISPATCH_BREAKER_CONFIG="$TMPROOT/$name/dispatch-breaker.json"
  export FATQ_WORKER_PS_FILE="$TMPROOT/$name/workers"
  export FATQ_VERIFY_SH="$SCRIPT_DIR/../bin/fatq-verify.sh"
  export FATQ_PROD_ROOT="$PROD_ROOT"
  export FATQ_STALE_SECS=7200 FATQ_NUDGE_COOLDOWN_SECS=7200
  export FATQ_CLAIM_TTL_SECS=14400 FATQ_MAX_DISPATCH=3 FATQ_MAX_NUDGES=3
  export FATQ_UNASSIGNED_ALERT_SECS=3600 FATQ_UNASSIGNED_REMIND_SECS=86400
  export FATQ_CLOSEOUT_REMIND_SECS=86400 FATQ_STALE_RELAY_WARN_SECS=7200
  export FATQ_DRY_RUN=0 FATQ_MATTERMOST_DISABLE=1 FATQ_CREATE_GATE_DISABLED=1
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review,reviews,proposals}
  mkdir -p "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"
  printf '%s\n' '{"max_consecutive_no_transition":3}' > "$FATQ_DISPATCH_BREAKER_CONFIG"
  printf '%s\n' gateway-builder-anna gateway-builder-sancai > "$FATQ_WORKER_PS_FILE"
  cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{"assistants":[{"state_dir":"anya"},{"state_dir":"keeper"}],"shared_pools":{"builder":[{"state_dir":"anna"},{"state_dir":"sancai"}],"reviewer":[{"state_dir":"bella"},{"state_dir":"yitang"}],"designer":[{"state_dir":"twinkle"}]},"external_identities":["laotu"]}
EOF
  cat > "$FATQ_DISPATCH_AFFINITY" <<'EOF'
{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}
EOF
  cat > "$FATQ_BOT_ROUTING" <<'EOF'
bot_roster:
  - id: bella
    directory: bella
reviewers:
  - id: bella
EOF
}

make_rejected() {
  local tid="$1" ts
  ts="$(TZ=Asia/Taipei date -d "@$((BASE_EPOCH - 60))" '+%Y-%m-%dT%H:%M:%S+08:00')"
  jq -n --arg tid "$tid" --arg ts "$ts" '{task_id:$tid,slug:$tid,status:"rejected",assigned:"anna",reviewer:"bella",created_by:"keeper",deliver_to:"keeper",verify_commands:[],history:[{ts:$ts,by:"bella",via:"fatq-cli",action:"verdict_reject",from:"review/",to:"rejected/"}]}' > "$FATQ_ROOT/rejected/$tid.json"
}

action_count() {
  jq '[.history[]? | select(.action == "dispatch" or .action == "nudge")] | length' "$1"
}

run_cycle() {
  local epoch="$1"
  export FATQ_NOW_EPOCH="$epoch"
  bash "$DISPATCH_SH" >/dev/null 2>&1
  mkdir -p "$FATQ_RELAY_DIR/read"
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' -exec mv {} "$FATQ_RELAY_DIR/read/" \; 2>/dev/null || true
}

exercise_probe() {
  local name="$1" cli="$2" expect_cancel="$3" tid="93eb-$1" f before after delta rc
  setup_fixture "$name"
  make_rejected "$tid"
  f="$FATQ_ROOT/rejected/$tid.json"

  # AC3 calibration must happen first: the same probe sees a live rejected task.
  run_cycle "$BASE_EPOCH"
  before="$(action_count "$f")"
  echo "CALIBRATION[$name] dispatch_or_nudge=$before"
  (( before > 0 )) || fail "$name calibration did not count a true positive"

  bash "$cli" cancel "$tid" --as anna --reason 'superseded fixture' >/dev/null 2>&1
  rc=$?
  if [[ "$expect_cancel" == 1 ]]; then
    [[ "$rc" == 0 ]] || fail "$name holder cancel exit=$rc"
    f="$FATQ_ROOT/cancelled/$tid.json"
  else
    [[ "$rc" != 0 ]] || fail "$name mutant unexpectedly cancelled"
    f="$FATQ_ROOT/rejected/$tid.json"
  fi

  run_cycle "$((BASE_EPOCH + 14500))"
  run_cycle "$((BASE_EPOCH + 21800))"
  run_cycle "$((BASE_EPOCH + 29100))"
  after="$(action_count "$f")"
  delta=$((after - before))
  echo "POST_VOID[$name] dispatch_or_nudge=$delta total=$after cancel_exit=$rc"

  if [[ "$expect_cancel" == 1 ]]; then
    [[ "$delta" == 0 ]] || fail "$name cancelled task was still dispatched/nudged"
    jq -e '.history[-1].action == "cancel" and .history[-1].actor_role == "holder"' "$f" >/dev/null || fail "$name holder audit role missing"
    [[ "$(find "$FATQ_RELAY_DIR/read" -type f -name '*holder-cancel*.json' | wc -l | tr -d ' ')" -ge 1 ]] || fail "$name creator/deliver_to notification missing"

    bash "$CLI_SH" force-mv "$tid" rejected --as anya --reason 'restore mistaken holder cancel' >/dev/null || fail "$name cancelled force-mv restore failed"
    f="$FATQ_ROOT/rejected/$tid.json"
    jq -e '.status == "rejected" and .history[-1].action == "force_mv" and .history[-1].from == "cancelled/" and .history[-1].to == "rejected/"' "$f" >/dev/null || fail "$name restore audit assertion failed"

    bash "$CLI_SH" claim "$tid" --as anna >/dev/null || fail "$name REJECT claim regression"
    bash "$CLI_SH" submit "$tid" --as anna >/dev/null || fail "$name REJECT resubmit regression"
    [[ -f "$FATQ_ROOT/review/$tid.json" ]] || fail "$name REJECT repair flow did not reach review"
    echo "REJECT_FLOW[$name] rejected->in_progress->review exit=0"
  else
    (( delta > 0 )) || fail "$name mutant did not restore dispatch/nudge leak"
  fi
}

# Red/green mutation is structural: remove rejected from the accepted cancel sources.
MUTANT_CLI="$TMPROOT/fatq-cli-mutant.sh"
sed 's/pending|design|design_review|spec_review|review|rejected|in_progress)/pending|design|design_review|spec_review|review|in_progress)/' "$CLI_SH" > "$MUTANT_CLI"
chmod +x "$MUTANT_CLI"

exercise_probe fixed "$CLI_SH" 1
exercise_probe mutant "$MUTANT_CLI" 0

audit_root="$TMPROOT/audit/tasks"
mkdir -p "$audit_root/cancelled"
cancel_ts="$(TZ=Asia/Taipei date -d "@$((BASE_EPOCH - 100))" '+%Y-%m-%dT%H:%M:%S+08:00')"
before_ts="$(TZ=Asia/Taipei date -d "@$((BASE_EPOCH - 110))" '+%Y-%m-%dT%H:%M:%S+08:00')"
after_ts="$(TZ=Asia/Taipei date -d "@$((BASE_EPOCH - 50))" '+%Y-%m-%dT%H:%M:%S+08:00')"
jq -n --arg c "$cancel_ts" --arg b "$before_ts" --arg a "$after_ts" '{task_id:"audit-fixture",history:[{action:"nudge",ts:$b},{action:"cancel",to:"cancelled/",ts:$c},{action:"dispatch",ts:$a,relay_file:"leak.json"}]}' > "$audit_root/cancelled/audit-fixture.json"
audit_out="$(FATQ_ROOT="$audit_root" VOID_AUDIT_NOW_EPOCH="$BASE_EPOCH" bash "$AUDIT_SH" --hours 1 2>&1)"
audit_rc=$?
echo "$audit_out"
[[ "$audit_rc" == 1 ]] || fail "audit should exit 1 when a post-cancel event exists"
grep -Fq 'TOTAL affected_tasks=1 dispatch=1 nudge=0 events=1' <<< "$audit_out" || fail "audit totals are not calibrated"

positional_audit_out="$(VOID_AUDIT_NOW_EPOCH="$BASE_EPOCH" bash "$AUDIT_SH" 1 "$audit_root" 2>&1)"
positional_audit_rc=$?
[[ "$positional_audit_rc" == 1 ]] || fail "positional audit compatibility exit=$positional_audit_rc"
[[ "$positional_audit_out" == "$audit_out" ]] || fail "--hours and positional audit output differ"
echo 'AUDIT_ARGS --hours=compatible positional=compatible'

echo 'PASS void-task-dispatch-test'

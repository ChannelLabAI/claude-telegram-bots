#!/usr/bin/env bash
# fatq-cli-test.sh — fixture tests for shared/bin/fatq-cli.sh (Pod 2.1 FATQ CLI, Part 1)
#
# Spec: handover/fatq-cli-and-approval-spec-20260707.md §1.8 (C1-C7)
# Ported from the fatq-cli.ts reference implementation's permission-matrix behavior
# (which already implements the mac-bridge 20260707-120500 ruling: check order =
# permission before state; builder pool fail-closed; E4 reviewer-of-record).
#
# All fixtures are self-made in mktemp -d dirs — never asserts against real tasks/
# (see feedback_closed_loop_test_fixture). Hard guard below refuses to run if
# FATQ_ROOT somehow resolves to the production path (this week's third
# test-vs-production collision incident, mac-bridge 20260707-120500 ①).
#
# Usage: fatq-cli-test.sh
# Exit:  0 = all P1-P30 + CONC1 + REDLINE pass, 1 = one or more failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"
VERIFY_SH="$SCRIPT_DIR/../bin/fatq-verify.sh"
PROD_ROOT="/home/oldrabbit/.claude-bots/tasks"

TOTAL_PASS=0
TOTAL_FAIL=0
FAIL_NAMES=()

# ── ①硬檢查（mac-bridge 20260707-120500）：測試永遠不得對真實 tasks/ 動手 ──
if [[ "${FATQ_ROOT:-}" == "$PROD_ROOT" || "${FATQ_ROOT:-}" == "${PROD_ROOT}/" ]]; then
  echo "[fatq-cli-test] FATAL: FATQ_ROOT 指向生產路徑 ($PROD_ROOT)，拒絕執行。測試一律用 mktemp -d fixture。" >&2
  exit 2
fi

# ── fixture scaffolding ────────────────────────────────────────────────────
setup() {
  TMPROOT=$(mktemp -d)
  export FATQ_ROOT="$TMPROOT/tasks"
  export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
  export FATQ_VERIFY_SH="$VERIFY_SH"
  export FATQ_RELAY_DIR="$TMPROOT/relay"
  export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
  export FATQ_OVERRIDE_AUDIT="$TMPROOT/override-audit.jsonl"
  export FATQ_TRUST_LEDGER_AUDIT="$TMPROOT/trust-ledger/trust-ledger.audit.jsonl"
  export FATQ_ENFORCEMENT_KILL_SWITCH="$FATQ_ROOT/.fatq-enforcement-off"
  # AP5 tests approval dispatch, not create provenance. The dedicated dispatch
  # A74-A76 fixtures cover the production-default create gate.
  export FATQ_CREATE_GATE_DISABLED=1
  export FATQ_MATTERMOST_DISABLE=0
  unset FATQ_NOW_ISO || true
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived}
  mkdir -p "$FATQ_RELAY_DIR"

  # 再次防呆：即使外層環境沒設，setup() 產生的 FATQ_ROOT 也必須不等於生產路徑
  if [[ "$FATQ_ROOT" == "$PROD_ROOT" ]]; then
    echo "[fatq-cli-test] FATAL: fixture FATQ_ROOT 意外撞到生產路徑" >&2
    exit 2
  fi

  # 固定 fixture team-config：builder={anna,sancai,eric}, reviewer={bella,yitang,ron-reviewer},
  # assistants={anya,caijie-zhuchu}, designer={twinkle,sara}，external_identities={mac-agent,laotu}
  # （Q5 裁決落地：身份名單改讀此段，不再寫死在 fatq-cli.sh，測試需跟進）。
  # 不耦合真實名單，測試不受名單異動影響。
  cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{
  "assistants": [{"state_dir": "anya"}, {"state_dir": "caijie-zhuchu"}, {"state_dir": "huizhang"}],
  "shared_pools": {
    "builder": [{"state_dir": "anna"}, {"state_dir": "sancai"}, {"state_dir": "eric"}],
    "reviewer": [{"state_dir": "bella"}, {"state_dir": "yitang"}, {"state_dir": "ron-reviewer"}],
    "designer": [{"state_dir": "twinkle"}, {"state_dir": "sara"}]
  },
  "external_identities": ["mac-agent", "laotu", "ron-web-identity"]
}
EOF

  # 固定 fixture 公共財偵測表+業務線親和表：不讀真實 shared/lib/
  # dispatch-affinity.json，避免未來該表被 d5c3 擴充後改變本測試的斷言基礎。
  # lines schema 與 d5c3 定案一致：以 created_by 為鍵，{builder, reviewer} 單值。
  cat > "$FATQ_DISPATCH_AFFINITY" <<'EOF'
{
  "infra_patterns": ["shared/", "crontab", "gateway", "systemd", "schema", "database"],
  "lines": {
    "caijie-zhuchu": {"builder": "sancai", "reviewer": "yitang"},
    "default": {"builder": "anna", "reviewer": "bella"}
  }
}
EOF
}

teardown() {
  rm -rf "$TMPROOT"
}

run_cli() {
  bash "$CLI_SH" "$@"
}

# make_task <path> <overrides-json>
make_task() {
  local path="$1" overrides="$2"
  jq -n --argjson ov "$overrides" \
    '{task_id: "override-me", slug: "t", status: "pending", history: [],
      verify_commands: []} * $ov' \
    > "$path"
}

real_done_sample_task() {
  local f
  while read -r f; do
    if jq -e '(.history|length)>=2 and all(.history[0:2][]; has("ts") and has("by") and has("via") and has("action") and has("from") and has("to"))' "$f" >/dev/null 2>&1; then
      echo "$f"
      return 0
    fi
  done < <(find "$PROD_ROOT/done" -maxdepth 1 -name '*.json' -print 2>/dev/null)
  return 1
}

make_real_submit_task() {
  local path="$1" tid="$2" advisor_required="${3:-unset}" with_advisor="${4:-0}"
  local sample
  sample="$(real_done_sample_task)" || {
    echo "[fatq-cli-test] FATAL: no production done/ sample with >=2 full history entries" >&2
    return 1
  }
  jq --arg tid "$tid" --argjson advisor_required "$advisor_required" --arg with_advisor "$with_advisor" '
    .task_id = $tid
    | .slug = $tid
    | .status = "in_progress"
    | .assigned = "anna"
    | .reviewer = (.reviewer // "bella")
    | .verify_commands = []
    | del(.transition_token, .not_before)
    | if $advisor_required == null then del(.advisor_required) else .advisor_required = $advisor_required end
    | if $with_advisor == "1" then
        .history = ((.history // []) + [{
          ts:"2026-07-15T00:00:00+08:00",
          by:"anna",
          via:"fatq-cli",
          action:"comment",
          text:"[advisor] Q: fixture shape? | A: production clone shape is preserved | verdict: proceed"
        }])
      else . end
  ' "$sample" > "$path"
}

fail() {
  echo "    ✗ $*"
  return 1
}

assert_exit() {
  local expected="$1" actual="$2" ctx="$3"
  [[ "$actual" == "$expected" ]] || fail "$ctx: expected exit $expected, got $actual"
}

state_dir_of() {
  # $1 = task_id, searches all core dirs, echoes state name or "MISSING"
  local tid="$1" d
  for d in pending in_progress review done rejected cancelled wont_do approval_pending; do
    [[ -f "$FATQ_ROOT/$d/$tid.json" ]] && { echo "$d"; return 0; }
  done
  echo "MISSING"
}

history_len() {
  jq '.history | length' "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# CLAIM (pending|rejected → in_progress): builder pool ∪ {mac-agent} AND assigned==self
# ═══════════════════════════════════════════════════════════════════════════

test_P1() {
  local f="$FATQ_ROOT/pending/t1.json"
  make_task "$f" '{"task_id":"t1","assigned":"anna"}'
  local out rc
  out=$(run_cli claim t1 --as anna 2>&1); rc=$?
  assert_exit 0 "$rc" "P1" || return 1
  [[ "$(state_dir_of t1)" == "in_progress" ]] || fail "P1: expected in_progress/, got $(state_dir_of t1)" || return 1
  [[ "$(history_len "$FATQ_ROOT/in_progress/t1.json")" == "1" ]] || fail "P1: history should be 1" || return 1
  return 0
}

test_P2() {
  local f="$FATQ_ROOT/pending/t2.json"
  make_task "$f" '{"task_id":"t2","assigned":"anna"}'
  local rc
  run_cli claim t2 --as sancai >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P2 (sancai claims anna's task)" || return 1
  [[ "$(state_dir_of t2)" == "pending" ]] || fail "P2: task must not move" || return 1
  return 0
}

test_P3() {
  # yitang is reviewer-pool only, not builder-pool — fail-closed even if assigned matches (③a)
  local f="$FATQ_ROOT/pending/t3.json"
  make_task "$f" '{"task_id":"t3","assigned":"yitang"}'
  local rc
  run_cli claim t3 --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P3 (yitang not in builder pool)" || return 1
  return 0
}

test_P4() {
  # mac-agent is an EXTRA_IDENTITY treated as builder-category
  local f="$FATQ_ROOT/pending/t4.json"
  make_task "$f" '{"task_id":"t4","assigned":"mac-agent"}'
  local rc
  run_cli claim t4 --as mac-agent >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P4 (mac-agent extra identity claims own task)" || return 1
  [[ "$(state_dir_of t4)" == "in_progress" ]] || fail "P4: expected in_progress/" || return 1
  return 0
}

test_P5() {
  local f="$FATQ_ROOT/rejected/t5.json"
  make_task "$f" '{"task_id":"t5","assigned":"anna"}'
  local rc
  run_cli claim t5 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P5 (rejected -> in_progress)" || return 1
  [[ "$(state_dir_of t5)" == "in_progress" ]] || fail "P5: expected in_progress/" || return 1
  return 0
}

test_P6() {
  # perm-before-state: task in review/ (illegal source for claim) AND assigned to someone else.
  # Must fail with E_PERM (3), not E_STATE (4) — unauthorized caller must not learn the state.
  local f="$FATQ_ROOT/review/t6.json"
  make_task "$f" '{"task_id":"t6","assigned":"sancai","reviewer":"bella"}'
  local rc
  run_cli claim t6 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P6 (perm-before-state on claim)" || return 1
  return 0
}

test_P7() {
  local f="$FATQ_ROOT/pending/t7.json"
  make_task "$f" '{"task_id":"t7","assigned":"anna"}'
  local rc
  run_cli claim t7 --as ghost-identity >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P7 (unknown identity)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SUBMIT (in_progress → review): builder pool AND assigned==self, verify gate
# ═══════════════════════════════════════════════════════════════════════════

test_P8() {
  local f="$FATQ_ROOT/in_progress/t8.json"
  make_task "$f" '{"task_id":"t8","assigned":"anna","status":"in_progress"}'
  local rc
  run_cli submit t8 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P8" || return 1
  [[ "$(state_dir_of t8)" == "review" ]] || fail "P8: expected review/" || return 1
  return 0
}

test_P9() {
  local f="$FATQ_ROOT/in_progress/t9.json"
  make_task "$f" '{"task_id":"t9","assigned":"anna","status":"in_progress"}'
  local rc
  run_cli submit t9 --as sancai >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P9 (sancai submits anna's task)" || return 1
  return 0
}

test_P10() {
  # perm-before-state: task actually still in pending/ AND assigned mismatched
  local f="$FATQ_ROOT/pending/t10.json"
  make_task "$f" '{"task_id":"t10","assigned":"sancai"}'
  local rc
  run_cli submit t10 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P10 (perm-before-state on submit)" || return 1
  return 0
}

test_P11() {
  local f="$FATQ_ROOT/in_progress/t11.json"
  make_task "$f" '{"task_id":"t11","assigned":"anna","status":"in_progress","verify_commands":[{"cmd":["false"],"expect_exit":0,"desc":"always fails"}]}'
  local rc err_file="$TMPROOT/t11.stderr" validate_out
  run_cli submit t11 --as anna >/dev/null 2>"$err_file"; rc=$?
  assert_exit 5 "$rc" "P11 (verify gate fails)" || return 1
  [[ "$(state_dir_of t11)" == "in_progress" ]] || fail "P11: task must stay in_progress/" || return 1
  grep -Fq "ERROR: submit: verify gate 未過" "$err_file" ||
    fail "P11: non-TTY stderr must contain a visible E_VERIFY reason" || return 1
  [[ "$(jq '[.history[] | select(.action=="submit_verify_failed" and .verify_exit==1)] | length' "$f")" == "1" ]] ||
    fail "P11: failed gate must leave one durable history entry" || return 1
  validate_out="$(run_cli validate --as anna --json)"
  [[ "$(jq -r '[.violations[] | select(.issue=="transition_token_mismatch" and .task_id=="t11")] | length' <<<"$validate_out")" == "0" ]] ||
    fail "P11: failed gate left a stale transition_token" || return 1
  return 0
}

test_P12() {
  local f="$FATQ_ROOT/in_progress/t12.json"
  make_task "$f" '{"task_id":"t12","assigned":"anna","status":"in_progress","verify_commands":[{"cmd":["true"],"expect_exit":0,"desc":"always passes"}]}'
  local rc
  run_cli submit t12 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P12 (verify gate passes)" || return 1
  [[ "$(state_dir_of t12)" == "review" ]] || fail "P12: expected review/" || return 1
  return 0
}

# Regression for a3cc: before the fix, submit holds .locks/<task>.lock while
# FATQ_VERIFY_SH runs, so this verifier's same-task comment waits forever on
# that exact lock. The fixed two-phase submit releases it around verification.
test_SUBMIT_LOCK1() {
  local f="$FATQ_ROOT/in_progress/submit-lock1.json"
  make_task "$f" '{"task_id":"submit-lock1","assigned":"anna","status":"in_progress"}'
  export FATQ_VERIFY_SH="$SCRIPT_DIR/fixtures/fatq-submit-reentrant-verify.sh"
  export REENTER_CLI_SH="$CLI_SH"
  export REENTER_TASK_ID="submit-lock1"
  export REENTER_MODE="comment"
  local rc
  timeout 5 bash "$CLI_SH" submit submit-lock1 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "SUBMIT_LOCK1 (same-task verifier re-entry)" || return 1
  [[ "$(state_dir_of submit-lock1)" == "review" ]] ||
    fail "SUBMIT_LOCK1: expected review/" || return 1
  [[ "$(jq '[.history[] | select(.action=="comment" and .text=="verify re-entered the task lock")] | length' "$FATQ_ROOT/review/submit-lock1.json")" == "1" ]] ||
    fail "SUBMIT_LOCK1: verifier comment missing" || return 1
  return 0
}

# Verification is outside the lock, so the second lock must reject any
# transition-relevant mutation instead of moving a now-different task.
test_SUBMIT_LOCK2() {
  local f="$FATQ_ROOT/in_progress/submit-lock2.json"
  make_task "$f" '{"task_id":"submit-lock2","assigned":"anna","status":"in_progress"}'
  export FATQ_VERIFY_SH="$SCRIPT_DIR/fixtures/fatq-submit-reentrant-verify.sh"
  export REENTER_CLI_SH="$CLI_SH"
  export REENTER_TASK_ID="submit-lock2"
  export REENTER_MODE="mutate"
  local rc
  timeout 5 bash "$CLI_SH" submit submit-lock2 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 6 "$rc" "SUBMIT_LOCK2 (mutation invalidates snapshot)" || return 1
  [[ "$(state_dir_of submit-lock2)" == "in_progress" ]] ||
    fail "SUBMIT_LOCK2: changed task must stay in_progress/" || return 1
  [[ "$(jq -r '.graduated_invariant[0]' "$f")" == "changed-during-verify" ]] ||
    fail "SUBMIT_LOCK2: mutation fixture did not run" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# VERDICT (review → done|rejected): reviewer-of-record ∪ {bella,anya}, no self-review
# ═══════════════════════════════════════════════════════════════════════════

test_P13() {
  local f="$FATQ_ROOT/review/t13.json"
  make_task "$f" '{"task_id":"t13","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict approve t13 --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P13" || return 1
  [[ "$(state_dir_of t13)" == "done" ]] || fail "P13: expected done/" || return 1
  return 0
}

test_P14() {
  local f="$FATQ_ROOT/review/t14.json"
  make_task "$f" '{"task_id":"t14","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict approve t14 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P14 (bella exception, not reviewer-of-record)" || return 1
  return 0
}

test_P15() {
  local f="$FATQ_ROOT/review/t15.json"
  make_task "$f" '{"task_id":"t15","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict approve t15 --as anya >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P15 (anya exception)" || return 1
  return 0
}

test_P16() {
  local f="$FATQ_ROOT/review/t16.json"
  make_task "$f" '{"task_id":"t16","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict approve t16 --as sancai >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P16 (builder, not reviewer/bella/anya)" || return 1
  return 0
}

test_P17() {
  # self-review: identity == assigned, no exception even if also nominally "reviewer"
  local f="$FATQ_ROOT/review/t17.json"
  make_task "$f" '{"task_id":"t17","assigned":"anna","reviewer":"anna","status":"review"}'
  local rc
  run_cli verdict approve t17 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P17 (self-review forbidden, no exception)" || return 1
  return 0
}

test_P18() {
  local f="$FATQ_ROOT/review/t18.json"
  make_task "$f" '{"task_id":"t18","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict approve t18 --as ron-reviewer >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P18 (reviewer pool member reviewing someone else's record)" || return 1
  return 0
}

test_P19() {
  local f="$FATQ_ROOT/review/t19.json"
  make_task "$f" '{"task_id":"t19","assigned":"anna","reviewer":"yitang","status":"review","verify_commands":[{"cmd":["false"],"expect_exit":0,"desc":"x"}]}'
  local rc
  run_cli verdict approve t19 --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 5 "$rc" "P19 (verdict approve re-runs verify, fails)" || return 1
  [[ "$(state_dir_of t19)" == "review" ]] || fail "P19: must stay review/" || return 1
  return 0
}

test_P20() {
  local f="$FATQ_ROOT/review/t20.json"
  make_task "$f" '{"task_id":"t20","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict reject t20 --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "P20 (reject without --reason)" || return 1
  return 0
}

test_P21() {
  local f="$FATQ_ROOT/review/t21.json"
  make_task "$f" '{"task_id":"t21","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli verdict reject t21 --as yitang --reason "not good enough" >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P21 (reject with reason)" || return 1
  [[ "$(state_dir_of t21)" == "rejected" ]] || fail "P21: expected rejected/" || return 1
  return 0
}

test_P22() {
  # perm-before-state: task actually in pending/ AND reviewer field mismatched
  local f="$FATQ_ROOT/pending/t22.json"
  make_task "$f" '{"task_id":"t22","assigned":"anna","reviewer":"yitang"}'
  local rc
  run_cli verdict approve t22 --as sancai >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P22 (perm-before-state on verdict)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# REASSIGN (any → pending, anya only)
# ═══════════════════════════════════════════════════════════════════════════

test_P23() {
  local f="$FATQ_ROOT/in_progress/t23.json"
  make_task "$f" '{"task_id":"t23","assigned":"anna","status":"in_progress"}'
  local rc
  run_cli reassign t23 --as anya --to sancai >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P23" || return 1
  [[ "$(state_dir_of t23)" == "pending" ]] || fail "P23: expected pending/" || return 1
  [[ "$(jq -r '.assigned' "$FATQ_ROOT/pending/t23.json")" == "sancai" ]] || fail "P23: assigned not updated" || return 1
  return 0
}

test_P24() {
  local f="$FATQ_ROOT/in_progress/t24.json"
  make_task "$f" '{"task_id":"t24","assigned":"anna","status":"in_progress"}'
  local rc
  run_cli reassign t24 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P24 (bella not anya)" || return 1
  return 0
}

test_P25() {
  local f="$FATQ_ROOT/done/t25.json"
  make_task "$f" '{"task_id":"t25","assigned":"anna","status":"done"}'
  local rc
  run_cli reassign t25 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P25 (perm-checked before terminal-state check)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# COMMENT (any known identity, any state, no restriction)
# ═══════════════════════════════════════════════════════════════════════════

test_P26() {
  local f="$FATQ_ROOT/pending/t26.json"
  make_task "$f" '{"task_id":"t26","assigned":"anna"}'
  local rc
  run_cli comment t26 --as sancai --text "fyi" >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P26 (comment open to any known identity)" || return 1
  [[ "$(state_dir_of t26)" == "pending" ]] || fail "P26: state must not change" || return 1
  return 0
}

test_P27() {
  local f="$FATQ_ROOT/pending/t27.json"
  make_task "$f" '{"task_id":"t27","assigned":"anna"}'
  local rc
  run_cli comment t27 --as ghost --text "fyi" >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P27 (unknown identity cannot comment)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HOLD (anya + assigned self)
# ═══════════════════════════════════════════════════════════════════════════

test_P28() {
  local f="$FATQ_ROOT/pending/t28.json"
  make_task "$f" '{"task_id":"t28","assigned":"anna"}'
  local rc
  run_cli hold t28 --as anna --until 2026-08-01T00:00:00+08:00 >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P28" || return 1
  [[ "$(jq -r '.not_before' "$FATQ_ROOT/pending/t28.json")" == "2026-08-01T00:00:00+08:00" ]] || fail "P28: not_before not set" || return 1
  return 0
}

test_P29() {
  local f="$FATQ_ROOT/pending/t29.json"
  make_task "$f" '{"task_id":"t29","assigned":"anna"}'
  local rc
  run_cli hold t29 --as bella --until 2026-08-01T00:00:00+08:00 >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "P29 (non-anya, non-assigned cannot hold)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# QUERY (open to anyone, no identity required)
# ═══════════════════════════════════════════════════════════════════════════

test_P30() {
  local f="$FATQ_ROOT/pending/t30.json"
  make_task "$f" '{"task_id":"t30","assigned":"anna","reviewer":"yitang","priority":"P1","goal":"g"}'
  local out rc
  out=$(run_cli query t30 --json 2>&1); rc=$?
  assert_exit 0 "$rc" "P30" || return 1
  [[ "$(jq -r '.tasks[0].task_id' <<<"$out")" == "t30" ]] || fail "P30: schema task_id wrong" || return 1
  [[ "$(jq -r '.tasks[0].state' <<<"$out")" == "pending" ]] || fail "P30: schema state wrong" || return 1
  [[ "$(jq 'has("history")' <<<"$(jq '.tasks[0]' <<<"$out")")" == "false" ]] || fail "P30: history must not be in default output" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# ARCHIVE — 終態任務生命週期歸檔（非狀態機新態）
# ═══════════════════════════════════════════════════════════════════════════
test_ARCHIVE1() {
  local f="$FATQ_ROOT/done/arc1.json"
  make_task "$f" '{"task_id":"arc1","assigned":"anna","status":"done"}'
  local rc
  run_cli archive arc1 --as anya >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ARCHIVE1 (done -> archived)" || return 1
  [[ -f "$FATQ_ROOT/archived/arc1.json" ]] || fail "ARCHIVE1: archived file missing" || return 1
  [[ ! -f "$FATQ_ROOT/done/arc1.json" ]] || fail "ARCHIVE1: source file still in done/" || return 1
  [[ "$(jq -r '.status' "$FATQ_ROOT/archived/arc1.json")" == "done" ]] || fail "ARCHIVE1: status should remain done, not become archived" || return 1
  [[ "$(jq -r '.history[-1].action' "$FATQ_ROOT/archived/arc1.json")" == "archive" ]] || fail "ARCHIVE1: last history action should be archive" || return 1
  [[ "$(jq -r '.history[-1].from' "$FATQ_ROOT/archived/arc1.json")" == "done/" ]] || fail "ARCHIVE1: history from should be done/" || return 1
  [[ "$(jq -r '.history[-1].to' "$FATQ_ROOT/archived/arc1.json")" == "archived/" ]] || fail "ARCHIVE1: history to should be archived/" || return 1
  return 0
}

test_ARCHIVE2() {
  local st
  for st in wont_do cancelled rejected; do
    local f="$FATQ_ROOT/$st/arc2-$st.json"
    make_task "$f" "{\"task_id\":\"arc2-$st\",\"assigned\":\"anna\",\"status\":\"$st\"}"
    run_cli archive "arc2-$st" --as laotu >/dev/null 2>&1
    local rc=$?
    assert_exit 0 "$rc" "ARCHIVE2 ($st -> archived)" || return 1
    [[ -f "$FATQ_ROOT/archived/arc2-$st.json" ]] || fail "ARCHIVE2: $st file not archived" || return 1
    [[ "$(jq -r '.status' "$FATQ_ROOT/archived/arc2-$st.json")" == "$st" ]] || fail "ARCHIVE2: $st status changed" || return 1
  done
  return 0
}

test_ARCHIVE3() {
  local st
  for st in pending in_progress review approval_pending; do
    local f="$FATQ_ROOT/$st/arc3-$st.json"
    make_task "$f" "{\"task_id\":\"arc3-$st\",\"assigned\":\"anna\",\"status\":\"$st\"}"
    local rc
    run_cli archive "arc3-$st" --as anya >/dev/null 2>&1; rc=$?
    assert_exit 4 "$rc" "ARCHIVE3 ($st rejected as non-terminal)" || return 1
    [[ -f "$FATQ_ROOT/$st/arc3-$st.json" ]] || fail "ARCHIVE3: $st task moved despite E_STATE" || return 1
  done
  return 0
}

test_ARCHIVE4() {
  local f="$FATQ_ROOT/done/arc4.json"
  make_task "$f" '{"task_id":"arc4","assigned":"anna","status":"done"}'
  local before rc
  before=$(jq -c '.history' "$f")
  run_cli archive arc4 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "ARCHIVE4 (non-admin rejected)" || return 1
  [[ -f "$FATQ_ROOT/done/arc4.json" ]] || fail "ARCHIVE4: non-admin moved task" || return 1
  [[ "$(jq -c '.history' "$f")" == "$before" ]] || fail "ARCHIVE4: history changed on permission reject" || return 1
  return 0
}

test_ARCHIVE5() {
  local f="$FATQ_ROOT/wont_do/arc5.json"
  make_task "$f" '{"task_id":"arc5","assigned":"anna","status":"wont_do"}'
  run_cli archive arc5 --as anya >/dev/null 2>&1 || return 1
  local hist_len rc out
  hist_len=$(history_len "$FATQ_ROOT/archived/arc5.json")
  out=$(run_cli archive arc5 --as anya --json 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "ARCHIVE5 (repeat archive idempotent)" || return 1
  [[ "$(jq -r '.history_appended' <<<"$out")" == "false" ]] || fail "ARCHIVE5: repeat archive should report history_appended=false" || return 1
  [[ "$(history_len "$FATQ_ROOT/archived/arc5.json")" == "$hist_len" ]] || fail "ARCHIVE5: repeat archive appended history" || return 1
  return 0
}

test_ARCHIVE6() {
  local f="$FATQ_ROOT/wont_do/smoke-wont-do.json"
  make_task "$f" '{"task_id":"smoke-wont-do","assigned":"anna","status":"wont_do","goal":"煙霧單"}'
  run_cli archive smoke-wont-do --as anya >/dev/null 2>&1 || return 1

  local all assigned state rc
  all=$(run_cli query --json 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "ARCHIVE6 (query all after archive)" || return 1
  [[ "$(jq '[.tasks[] | select(.task_id=="smoke-wont-do")] | length' <<<"$all")" == "0" ]] || fail "ARCHIVE6: archived wont_do task still appears in default query/needs list" || return 1

  assigned=$(run_cli query --assigned anna --json 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "ARCHIVE6 (query assigned after archive)" || return 1
  [[ "$(jq '[.tasks[] | select(.task_id=="smoke-wont-do")] | length' <<<"$assigned")" == "0" ]] || fail "ARCHIVE6: archived task still appears in assigned needs query" || return 1

  state=$(run_cli query --state archived --json 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "ARCHIVE6 (query --state archived returns empty because archived is not CORE_STATE_DIRS)" || return 1
  [[ "$(jq '.count' <<<"$state")" == "0" ]] || fail "ARCHIVE6: archived should not be query-scanned as a core state" || return 1
  return 0
}

test_ARCHIVE7() {
  local f="$FATQ_ROOT/archived/arc7.json"
  make_task "$f" '{"task_id":"arc7","assigned":"anna","status":"done"}'
  local rc
  run_cli claim arc7 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 7 "$rc" "ARCHIVE7 (claim cannot see archived)" || return 1
  run_cli submit arc7 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 7 "$rc" "ARCHIVE7 (submit cannot see archived)" || return 1
  run_cli verdict approve arc7 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 7 "$rc" "ARCHIVE7 (verdict cannot see archived)" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# ARGV 順序無關性（Bella QA REJECT #1/#2）：web spawn CLI 的參數順序不受控，
# 凍結契約表面必須順序無關。P1/P8 等既有案例全用「flag 在尾部」順序，抓不到
# 這兩個 bug；這裡刻意把 --as/--json 放在 positional 前面重現。
# ═══════════════════════════════════════════════════════════════════════════
test_P31() {
  # 重現 Bella #1：create --as X --json --slug ... （--json 在中間，非尾部）
  local out rc
  out=$(run_cli create --as anya --json --slug demo-y --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r 2>&1)
  rc=$?
  assert_exit 0 "$rc" "P31 (create with --json before other flags)" || return 1
  [[ "$(jq -r '.ok' <<<"$out")" == "true" ]] || fail "P31: create did not succeed, got: $out" || return 1
  return 0
}

test_CREATEVC1() {
  # 9673 root cause: verify_commands top-level array used to pass even when entry.cmd was a shell string.
  local err rc
  err=$(run_cli create --as anya --slug bad-vc-string --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r \
    --verify_commands '[{"cmd":"test -f /tmp/x","expect_exit":0,"desc":"bad"}]' 2>&1 >/dev/null)
  rc=$?
  assert_exit 2 "$rc" "CREATEVC1 (cmd string rejected)" || return 1
  [[ "$err" == *"verify_commands[0].cmd"* && "$err" == *"non-empty string array"* ]] || fail "CREATEVC1: error should name index and .cmd, got: $err" || return 1
  [[ "$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' -print | wc -l)" == "0" ]] || fail "CREATEVC1: invalid create must not write pending task" || return 1
  return 0
}

test_CREATEVC2() {
  local out rc tid
  out=$(run_cli create --as anya --json --slug good-vc-array --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r \
    --verify_commands '[{"cmd":["test","-f","/tmp/x"],"expect_exit":1,"desc":"good"}]' 2>&1)
  rc=$?
  assert_exit 0 "$rc" "CREATEVC2 (cmd array accepted)" || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  [[ -f "$FATQ_ROOT/pending/${tid}.json" ]] || fail "CREATEVC2: valid create should write pending task" || return 1
  [[ "$(jq -r '.verify_commands[0].cmd[0]' "$FATQ_ROOT/pending/${tid}.json")" == "test" ]] || fail "CREATEVC2: cmd array not preserved" || return 1
  return 0
}

test_CREATEVC3() {
  local err rc
  err=$(run_cli create --as anya --slug bad-vc-expect --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r \
    --verify_commands '[{"cmd":["true"],"expect_exit":"0","desc":"bad"}]' 2>&1 >/dev/null)
  rc=$?
  assert_exit 2 "$rc" "CREATEVC3 (expect_exit string rejected)" || return 1
  [[ "$err" == *"verify_commands[0].expect_exit"* && "$err" == *"number"* ]] || fail "CREATEVC3: error should name index and expect_exit, got: $err" || return 1
  [[ "$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' -print | wc -l)" == "0" ]] || fail "CREATEVC3: invalid create must not write pending task" || return 1
  return 0
}

test_CREATETITLE1() {
  local expected='Human-readable 標題：保留空白與符號 / #42' out rc tid f
  out=$(run_cli create --as anya --json --slug title-present --title "$expected" \
    --goal g --background b --context c --deliverables '["d"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r 2>&1)
  rc=$?
  assert_exit 0 "$rc" "CREATETITLE1 (title serialized)" || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.title' "$f")" == "$expected" ]] ||
    fail "CREATETITLE1: created task title did not round-trip exactly" || return 1
  return 0
}

test_CREATETITLE2() {
  local out rc tid f
  out=$(run_cli create --as anya --json --slug title-omitted \
    --goal g --background b --context c --deliverables '["d"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r 2>&1)
  rc=$?
  assert_exit 0 "$rc" "CREATETITLE2 (omitted title remains null)" || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  f="$FATQ_ROOT/pending/${tid}.json"
  jq -e 'has("title") and .title == null' "$f" >/dev/null ||
    fail "CREATETITLE2: omitted title must serialize as null, not an empty string" || return 1
  return 0
}

test_P32() {
  # 重現 Bella #2：claim --as anna <task_id>（--as 在 task_id 前面）
  local f="$FATQ_ROOT/pending/t32.json"
  make_task "$f" '{"task_id":"t32","assigned":"anna"}'
  local rc
  run_cli claim --as anna t32 >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "P32 (claim with --as before task_id)" || return 1
  [[ "$(state_dir_of t32)" == "in_progress" ]] || fail "P32: expected in_progress/" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# EXIT CODE 補完：E_STATE(4)（權限過關、純狀態不符）與 E_NOTFOUND(7)
# ═══════════════════════════════════════════════════════════════════════════
test_ESTATE() {
  # 權限完全合法（anna 是 builder 且 assigned==anna），純粹狀態不對（已在 review/）
  local f="$FATQ_ROOT/review/tst.json"
  make_task "$f" '{"task_id":"tst","assigned":"anna","reviewer":"yitang","status":"review"}'
  local rc
  run_cli claim tst --as anna >/dev/null 2>&1; rc=$?
  assert_exit 4 "$rc" "ESTATE (perm ok, state wrong)" || return 1
  return 0
}

test_ENOTFOUND() {
  local rc
  run_cli claim does-not-exist --as anna >/dev/null 2>&1; rc=$?
  assert_exit 7 "$rc" "ENOTFOUND" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CONC1 — 併發雙 claim：恰一成功，輸家必須拿 E_CONFLICT(6) 不是 E_PERM(3)
# （Bella QA REJECT ③：鎖外預讀 assigned 撞上贏家已 mv 走會誤判成權限錯誤，
# 對 web 呼叫端是 403/409 語義互換的真傷害。驗收標準＝連跑 20 次全過，
# 這裡直接把 20 輪內建進單一測試案例，往後回歸跑一次就有 20 輪壓力覆蓋）
# ═══════════════════════════════════════════════════════════════════════════
test_CONC1() {
  local round
  for round in $(seq 1 20); do
    local tid="tc1-r${round}"
    local f="$FATQ_ROOT/pending/${tid}.json"
    make_task "$f" "{\"task_id\":\"${tid}\",\"assigned\":\"anna\"}"

    ( run_cli claim "$tid" --as anna >"$TMPROOT/race1-${round}.log" 2>&1 ) &
    local pid1=$!
    ( run_cli claim "$tid" --as anna >"$TMPROOT/race2-${round}.log" 2>&1 ) &
    local pid2=$!
    wait "$pid1"; local rc1=$?
    wait "$pid2"; local rc2=$?

    local successes=0
    [[ "$rc1" -eq 0 ]] && successes=$((successes+1))
    [[ "$rc2" -eq 0 ]] && successes=$((successes+1))
    [[ "$successes" -eq 1 ]] || fail "CONC1 round $round: expected exactly 1 success, got $successes (rc1=$rc1 rc2=$rc2)" || return 1

    [[ "$(state_dir_of "$tid")" == "in_progress" ]] || fail "CONC1 round $round: task should end up in in_progress/" || return 1
    [[ "$(history_len "$FATQ_ROOT/in_progress/${tid}.json")" == "1" ]] || fail "CONC1 round $round: history must have exactly 1 claim entry" || return 1

    local loser_rc
    if [[ "$rc1" -eq 0 ]]; then loser_rc="$rc2"; else loser_rc="$rc1"; fi
    [[ "$loser_rc" -eq 6 ]] || fail "CONC1 round $round: loser should get E_CONFLICT(6), got $loser_rc" || return 1
  done
  return 0
}

# CLAIM_NOCLOBBER — pending 幽靈不得覆蓋既有 in_progress 活檔。
test_CLAIM_NOCLOBBER() {
  local tid="claim-noclobber"
  local ghost="$FATQ_ROOT/pending/${tid}.json"
  local active="$FATQ_ROOT/in_progress/${tid}.json"
  make_task "$ghost" "{\"task_id\":\"${tid}\",\"assigned\":\"anna\",\"history\":[{\"action\":\"dispatch\"}]}"
  make_task "$active" "{\"task_id\":\"${tid}\",\"assigned\":\"anna\",\"status\":\"in_progress\",\"history\":[{\"action\":\"claim\",\"marker\":\"active\"}]}"
  local before rc after
  before="$(sha256sum "$active" | awk '{print $1}')"
  run_cli claim "$tid" --as anna >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$active" | awk '{print $1}')"
  assert_exit 6 "$rc" "CLAIM_NOCLOBBER existing target" || return 1
  [[ "$before" == "$after" ]] || fail "CLAIM_NOCLOBBER: active destination was overwritten" || return 1
  [[ -f "$ghost" ]] || fail "CLAIM_NOCLOBBER: ghost source unexpectedly disappeared" || return 1
  return 0
}

# VALIDATE_DUP — advisory validate 必須列出跨 state 的同 task_id 副本。
test_VALIDATE_DUP() {
  local tid="validate-duplicate"
  make_task "$FATQ_ROOT/pending/${tid}.json" "{\"task_id\":\"${tid}\"}"
  make_task "$FATQ_ROOT/in_progress/${tid}.json" "{\"task_id\":\"${tid}\",\"status\":\"in_progress\"}"
  local out
  out="$(run_cli validate --as anna --json)"
  [[ "$(jq -r --arg tid "$tid" '[.violations[] | select(.issue=="duplicate_task_id" and .task_id==$tid)] | length' <<<"$out")" == "1" ]] \
    || fail "VALIDATE_DUP: duplicate_task_id violation missing or repeated" || return 1
  [[ "$(jq -r --arg tid "$tid" '[.violations[] | select(.issue=="duplicate_task_id" and .task_id==$tid)][0].task_files | length' <<<"$out")" == "2" ]] \
    || fail "VALIDATE_DUP: expected both duplicate paths" || return 1
  return 0
}

# FIND_TASK_FILE_DUP — command-time lookup warns when priority masks a duplicate.
test_FIND_TASK_FILE_DUP() {
  local tid="find-duplicate" out rc
  make_task "$FATQ_ROOT/pending/${tid}.json" "{\"task_id\":\"${tid}\",\"assigned\":\"anna\"}"
  make_task "$FATQ_ROOT/in_progress/${tid}.json" "{\"task_id\":\"${tid}\",\"assigned\":\"anna\",\"status\":\"in_progress\"}"
  out="$(run_cli claim "$tid" --as anna 2>&1)"; rc=$?
  assert_exit 6 "$rc" "FIND_TASK_FILE_DUP priority source conflict" || return 1
  grep -Fq "WARNING: task $tid exists in 2 state directories" <<<"$out" \
    || fail "FIND_TASK_FILE_DUP: command-time multi-match warning missing" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# REDLINE — 轉移後 diff：除預期欄位外零變動（§1.8 C7）
# ═══════════════════════════════════════════════════════════════════════════
test_REDLINE() {
  local f="$FATQ_ROOT/pending/tr1.json"
  make_task "$f" '{"task_id":"tr1","slug":"audit-me","priority":"P2","assigned":"anna"}'
  local before after
  before=$(jq 'del(.history, .status, .transition_token)' "$f")

  run_cli claim tr1 --as anna >/dev/null 2>&1

  local moved="$FATQ_ROOT/in_progress/tr1.json"
  [[ -f "$moved" ]] || fail "REDLINE: task did not move to in_progress/" || return 1
  after=$(jq 'del(.history, .status, .transition_token)' "$moved")
  [[ "$before" == "$after" ]] || fail "REDLINE: non-history/status fields changed:\nBEFORE=$before\nAFTER=$after" || return 1

  local last_entry
  last_entry=$(jq -c '.history[-1]' "$moved")
  for key in ts by via action from to; do
    [[ "$(jq "has(\"$key\")" <<<"$last_entry")" == "true" ]] || fail "REDLINE: history entry missing key '$key'" || return 1
  done
  [[ "$(jq -r '.via' <<<"$last_entry")" == "fatq-cli" ]] || fail "REDLINE: via must be fatq-cli" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Part 2 — approval 子命令組（§2.9 P1-P7，handover/fatq-cli-and-approval-spec-20260707.md）
# ═══════════════════════════════════════════════════════════════════════════
DISPATCH_SH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"

run_dispatch() {
  FATQ_ROOT="$FATQ_ROOT" FATQ_RELAY_DIR="$FATQ_RELAY_DIR" FATQ_STATE_DIR="$TMPROOT/dstate" \
  FATQ_MATTERMOST_DISABLE=1 FATQ_NOW_EPOCH="${FATQ_NOW_EPOCH:-}" \
    bash "$DISPATCH_SH" >>"$TMPROOT/dispatch.log" 2>&1
}

# AP1 — 狀態轉移全矩陣：request（從 pending 與 in_progress 兩種 return_state）→ approve/reject/expire
test_AP1() {
  # (a) request from pending -> approve -> 回 pending
  local f1="$FATQ_ROOT/pending/ap1a.json"
  make_task "$f1" '{"task_id":"ap1a","assigned":"anna"}'
  run_cli approval request ap1a --as anna --domain security --expires 48h --reason "r" >/dev/null 2>&1
  [[ "$(state_dir_of ap1a)" == "approval_pending" ]] || fail "AP1a: expected approval_pending/ after request" || return 1
  [[ "$(jq -r '.approval.return_state' "$FATQ_ROOT/approval_pending/ap1a.json")" == "pending" ]] || fail "AP1a: return_state should be pending" || return 1
  run_cli approval approve ap1a --as laotu --evidence "tg:1" >/dev/null 2>&1
  [[ "$(state_dir_of ap1a)" == "pending" ]] || fail "AP1a: approve should return to pending/" || return 1
  local approval_a
  approval_a=$(jq -c '.approval' "$FATQ_ROOT/pending/ap1a.json")
  [[ "$(jq -r '.status' <<<"$approval_a")" == "approved" ]] || fail "AP1a: approval.status should be approved" || return 1
  [[ "$(jq -r '.decided_by' <<<"$approval_a")" == "laotu" ]] || fail "AP1a: decided_by should be laotu" || return 1
  [[ "$(jq -r '.decided_at' <<<"$approval_a")" != "null" ]] || fail "AP1a: decided_at must be set" || return 1

  # (b) request from in_progress -> reject -> 落 rejected/
  local f2="$FATQ_ROOT/in_progress/ap1b.json"
  make_task "$f2" '{"task_id":"ap1b","assigned":"anna","status":"in_progress"}'
  run_cli approval request ap1b --as anna --domain cross-bot-infra --expires 24h --reason "r2" >/dev/null 2>&1
  [[ "$(jq -r '.approval.return_state' "$FATQ_ROOT/approval_pending/ap1b.json")" == "in_progress" ]] || fail "AP1b: return_state should be in_progress" || return 1
  run_cli approval reject ap1b --as laotu --evidence "tg:2" --reason "no" >/dev/null 2>&1
  [[ "$(state_dir_of ap1b)" == "rejected" ]] || fail "AP1b: reject should land in rejected/" || return 1
  [[ "$(jq -r '.approval.status' "$FATQ_ROOT/rejected/ap1b.json")" == "rejected" ]] || fail "AP1b: approval.status should be rejected" || return 1
  return 0
}

# AP2 — 未授權 approve 拒絕：--as anna（非 approvers）
test_AP2() {
  local f="$FATQ_ROOT/pending/ap2.json"
  make_task "$f" '{"task_id":"ap2","assigned":"anna"}'
  run_cli approval request ap2 --as anna --domain funds --expires 24h --reason "r" >/dev/null 2>&1
  local before after rc
  before=$(jq -c '.history' "$FATQ_ROOT/approval_pending/ap2.json")
  run_cli approval approve ap2 --as anna --evidence "tg:1" >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "AP2 (non-approver approve)" || return 1
  after=$(jq -c '.history' "$FATQ_ROOT/approval_pending/ap2.json")
  [[ "$before" == "$after" ]] || fail "AP2: history must be unchanged on rejected attempt" || return 1
  [[ "$(jq -r '.approval.decision' "$FATQ_ROOT/approval_pending/ap2.json")" == "null" ]] || fail "AP2: decision must stay null" || return 1
  return 0
}

# AP3 — 逾時 default-deny：注入時鐘過 expires，全程無自動 approve
test_AP3() {
  export FATQ_NOW_ISO="2026-08-01T00:00:00+08:00"
  local f="$FATQ_ROOT/pending/ap3.json"
  make_task "$f" '{"task_id":"ap3","assigned":"anna"}'
  run_cli approval request ap3 --as anna --domain data --expires 24h --reason "r" >/dev/null 2>&1

  # 未到期：dispatch 跑一次應是 approval_reminder，不是 expired
  export FATQ_NOW_EPOCH=$(date -d "2026-08-01T12:00:00+08:00" +%s)
  run_dispatch
  local reminders
  reminders=$(jq '[.history[] | select(.action=="approval_reminder")] | length' "$FATQ_ROOT/approval_pending/ap3.json")
  [[ "$reminders" == "1" ]] || fail "AP3: expected 1 approval_reminder before expiry, got $reminders" || return 1

  # 過期（24h 已過）：第一輪 dispatch 應恰產生 1 個 approval_expired_alert
  export FATQ_NOW_EPOCH=$(date -d "2026-08-02T01:00:00+08:00" +%s)
  run_dispatch
  local expired_alerts
  expired_alerts=$(jq '[.history[] | select(.action=="approval_expired_alert")] | length' "$FATQ_ROOT/approval_pending/ap3.json")
  [[ "$expired_alerts" == "1" ]] || fail "AP3: expected exactly 1 approval_expired_alert, got $expired_alerts" || return 1
  [[ "$(jq -r '.approval.status' "$FATQ_ROOT/approval_pending/ap3.json")" == "pending" ]] || fail "AP3: status must still be pending, no auto-approve/expire from dispatch" || return 1

  # 再跑一輪（<24h since expired_alert）：不應重複 escalate
  export FATQ_NOW_EPOCH=$(date -d "2026-08-02T02:00:00+08:00" +%s)
  run_dispatch
  expired_alerts=$(jq '[.history[] | select(.action=="approval_expired_alert")] | length' "$FATQ_ROOT/approval_pending/ap3.json")
  [[ "$expired_alerts" == "1" ]] || fail "AP3: approval_expired_alert must not repeat within 24h" || return 1

  # 再過 24h：cron 應提醒 Anya 執行回收（approval_expire_reminder），仍不自動 expire
  export FATQ_NOW_EPOCH=$(date -d "2026-08-03T02:00:00+08:00" +%s)
  run_dispatch
  local expire_reminders
  expire_reminders=$(jq '[.history[] | select(.action=="approval_expire_reminder")] | length' "$FATQ_ROOT/approval_pending/ap3.json")
  [[ "$expire_reminders" == "1" ]] || fail "AP3: expected 1 approval_expire_reminder 24h after escalation, got $expire_reminders" || return 1
  [[ "$(jq -r '.approval.status' "$FATQ_ROOT/approval_pending/ap3.json")" == "pending" ]] || fail "AP3: dispatch must never auto-expire — status still pending" || return 1

  # 人工執行 expire（anya）：status->expired，decision 維持 null，回 return_state
  unset FATQ_NOW_ISO
  export FATQ_NOW_ISO="2026-08-03T03:00:00+08:00"
  run_cli approval expire ap3 --as anya >/dev/null 2>&1
  [[ "$(state_dir_of ap3)" == "pending" ]] || fail "AP3: expire should return task to return_state (pending/)" || return 1
  [[ "$(jq -r '.approval.status' "$FATQ_ROOT/pending/ap3.json")" == "expired" ]] || fail "AP3: approval.status should be expired" || return 1
  [[ "$(jq -r '.approval.decision' "$FATQ_ROOT/pending/ap3.json")" == "null" ]] || fail "AP3: decision must remain null (no auto-approve)" || return 1
  unset FATQ_NOW_ISO FATQ_NOW_EPOCH
  return 0
}

# AP4 — 雙通道通知斷言：request 後跑 dispatch，TG relay 檔存在且含 @Anyachl_bot 與 task_id
test_AP4() {
  local f="$FATQ_ROOT/pending/ap4.json"
  make_task "$f" '{"task_id":"ap4","assigned":"anna"}'
  run_cli approval request ap4 --as anna --domain security --expires 48h --reason "r" >/dev/null 2>&1
  run_dispatch
  local relay_file
  relay_file=$(grep -l "ap4" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$relay_file" ]] || fail "AP4: expected a TG relay file mentioning ap4" || return 1
  grep -q "@Anyachl_bot" "$relay_file" || fail "AP4: relay text must contain @Anyachl_bot" || return 1
  [[ "$(jq -r '.fatq_task_id' "$relay_file")" == "ap4" ]] || fail "AP4: relay fatq_task_id mismatch" || return 1
  return 0
}

# AP5 — dispatch 相容：approval_pending 任務 + 正常 pending 任務並存
test_AP5() {
  local f1="$FATQ_ROOT/pending/ap5-normal.json"
  make_task "$f1" '{"task_id":"ap5-normal","assigned":"anna"}'
  local f2="$FATQ_ROOT/pending/ap5-approval.json"
  make_task "$f2" '{"task_id":"ap5-approval","assigned":"anna"}'
  run_cli approval request ap5-approval --as anna --domain security --expires 48h --reason "r" >/dev/null 2>&1

  run_dispatch

  # 正常任務照常派工
  local dispatch_entries
  dispatch_entries=$(jq '[.history[] | select(.action=="dispatch")] | length' "$FATQ_ROOT/pending/ap5-normal.json" 2>/dev/null)
  [[ "$dispatch_entries" == "1" ]] || fail "AP5: normal pending task should be dispatched once, got $dispatch_entries" || return 1

  # approval_pending 任務零派工 relay、恰 1 個通知 relay
  local dispatch_relays notify_relays
  dispatch_relays=$(grep -l "ap5-approval" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | xargs -I{} sh -c 'jq -r ".text" {}' 2>/dev/null | grep -c "FATQ 派工" || true)
  [[ "$dispatch_relays" == "0" ]] || fail "AP5: approval_pending task must never get a dispatch relay, got $dispatch_relays" || return 1
  notify_relays=$(grep -l "ap5-approval" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [[ "$notify_relays" == "1" ]] || fail "AP5: expected exactly 1 notification relay for approval task, got $notify_relays" || return 1

  # 24h 節流：再跑一輪不應加發
  run_dispatch
  notify_relays=$(grep -l "ap5-approval" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [[ "$notify_relays" == "1" ]] || fail "AP5: 24h throttle should prevent a 2nd reminder, got $notify_relays" || return 1
  return 0
}

# AP6 — evidence 稽核鏈：approve 帶 --evidence tg:12345
test_AP6() {
  local f="$FATQ_ROOT/pending/ap6.json"
  make_task "$f" '{"task_id":"ap6","assigned":"anna"}'
  run_cli approval request ap6 --as anna --domain security --expires 48h --reason "r" >/dev/null 2>&1
  run_cli approval approve ap6 --as laotu --evidence "tg:12345" --reason "老兔核可" >/dev/null 2>&1
  [[ "$(jq -r '.approval.evidence' "$FATQ_ROOT/pending/ap6.json")" == "tg:12345" ]] || fail "AP6: approval.evidence must record tg:12345" || return 1
  local last_entry
  last_entry=$(jq -c '.history[-1]' "$FATQ_ROOT/pending/ap6.json")
  [[ "$(jq -r '.evidence' <<<"$last_entry")" == "tg:12345" ]] || fail "AP6: history entry must also record evidence" || return 1
  return 0
}

# AP7 — 紅線稽核：cron 對 approval_pending 只 append history；所有 mv 的 history 行 by 皆為角色身份
test_AP7() {
  local f="$FATQ_ROOT/pending/ap7.json"
  make_task "$f" '{"task_id":"ap7","assigned":"anna"}'
  run_cli approval request ap7 --as anna --domain security --expires 48h --reason "r" >/dev/null 2>&1

  local before after
  before=$(jq 'del(.history)' "$FATQ_ROOT/approval_pending/ap7.json")
  run_dispatch
  [[ -f "$FATQ_ROOT/approval_pending/ap7.json" ]] || fail "AP7: cron must never mv approval_pending task" || return 1
  after=$(jq 'del(.history)' "$FATQ_ROOT/approval_pending/ap7.json")
  [[ "$before" == "$after" ]] || fail "AP7: cron wrote something beyond history" || return 1

  # 所有「造成 mv」的 history 行（request/approve/reject/expire）by 都必須是角色身份，
  # 不是 cron——cron 自己寫的 approval_reminder/approval_expired_alert/
  # approval_expire_reminder 只是通知，本來就該是 fatq-dispatch-cron，不算在內。
  run_cli approval approve ap7 --as laotu --evidence "tg:9" >/dev/null 2>&1
  local by_values
  by_values=$(jq -r '[.history[] | select(.action == "approval_request" or .action == "approval_approve" or .action == "approval_reject" or .action == "approval_expire") | .by] | join(",")' "$FATQ_ROOT/pending/ap7.json")
  [[ "$by_values" != *"fatq-dispatch-cron"* ]] || fail "AP7: mv-causing history entries must never be authored by fatq-dispatch-cron, got: $by_values" || return 1
  [[ -n "$by_values" ]] || fail "AP7: expected at least one mv-causing history entry, found none" || return 1
  return 0
}

# AP8 — Bella QA REJECT 回歸：requester=anya 的 reject 必須產生 TG relay 檔
# （原本 lookup_bot_for_relay 漏 anya，rc=0 但零 relay 產出，違反 AC3）
test_AP8() {
  local f="$FATQ_ROOT/pending/ap8.json"
  make_task "$f" '{"task_id":"ap8","assigned":"anna"}'
  run_cli approval request ap8 --as anya --domain security --expires 24h --reason "r" >/dev/null 2>&1
  run_cli approval reject ap8 --as laotu --evidence "tg:1" --reason "no" >/dev/null 2>&1

  local relay_file
  relay_file=$(grep -l "ap8" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$relay_file" ]] || fail "AP8: requester=anya reject must still produce a relay file" || return 1
  grep -q "@Anyachl_bot" "$relay_file" || fail "AP8: relay text must contain @Anyachl_bot for anya requester" || return 1
  [[ "$(jq -r '.recipient' "$relay_file")" == "" ]] || fail "AP8: anya's recipient should be empty (self-picked via @handle, per dispatch convention)" || return 1
  return 0
}

# AP9 — 查無映射的 requester（如 mac-agent）reject 時 fallback 給 Anya 人工轉達，不得靜默丟
test_AP9() {
  local f="$FATQ_ROOT/pending/ap9.json"
  make_task "$f" '{"task_id":"ap9","assigned":"anna"}'
  run_cli approval request ap9 --as mac-agent --domain security --expires 24h --reason "r" >/dev/null 2>&1
  run_cli approval reject ap9 --as laotu --evidence "tg:1" --reason "no" >/dev/null 2>&1

  local relay_file
  relay_file=$(grep -l "ap9" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$relay_file" ]] || fail "AP9: unmapped requester reject must still produce a fallback relay file" || return 1
  grep -q "@Anyachl_bot" "$relay_file" || fail "AP9: fallback relay must contain @Anyachl_bot" || return 1
  grep -q "mac-agent" "$relay_file" || fail "AP9: fallback relay must mention the original requester for manual routing" || return 1
  return 0
}

# AP10 — FATQ_MATTERMOST_DISABLE=1 時 reject 完全不寫 relay 檔（a1d5 視覺測試事故 7/8：
# 互動測試只覆寫 FATQ_ROOT、沒覆寫 FATQ_RELAY_DIR，reject 通知真的送到 TG。此閘門
# 讓不想碰真通知通道的測試/互動 QA 有一個明確開關，不必依賴每個呼叫端都記得隔離
# FATQ_RELAY_DIR。狀態轉移本身（rejected/ + approval.status）必須照常發生，只是不產 relay。
test_AP10() {
  local f="$FATQ_ROOT/pending/ap10.json"
  make_task "$f" '{"task_id":"ap10","assigned":"anna"}'
  run_cli approval request ap10 --as anya --domain security --expires 24h --reason "r" >/dev/null 2>&1
  FATQ_MATTERMOST_DISABLE=1 run_cli approval reject ap10 --as laotu --evidence "tg:1" --reason "no" >/dev/null 2>&1

  [[ "$(state_dir_of ap10)" == "rejected" ]] || fail "AP10: reject must still land in rejected/ even with notifications disabled" || return 1
  [[ "$(jq -r '.approval.status' "$FATQ_ROOT/rejected/ap10.json")" == "rejected" ]] || fail "AP10: approval.status must still be rejected" || return 1
  local relay_file
  relay_file=$(grep -l "ap10" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -z "$relay_file" ]] || fail "AP10: FATQ_MATTERMOST_DISABLE=1 must suppress the relay file entirely, found $relay_file" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# INFRA1 — create 建單 infra 偵測補遺（org-design-lines-20260707 決議 #3）
# ═══════════════════════════════════════════════════════════════════════════
test_INFRA1() {
  local out rc
  # 注意：不可 2>&1 合併 stderr——create 偵測到 infra 變動時會印 NOTICE 到 stderr，
  # 混進 stdout 會讓 --json 輸出不再是合法單一 JSON。
  out=$(run_cli create --as anya --slug infra-demo --goal "改 crontab 排程" \
    --background b --context "修改 shared/bin/fatq-dispatch.sh" \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "INFRA1" || return 1
  local tid
  tid=$(jq -r '.task_id' <<<"$out")
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "yitang" ]] || fail "INFRA1: explicit non-critical infra reviewer must be respected, got $(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" || return 1
  [[ "$(jq -r '[.history[]? | select(.action=="infra_gate_rewrite")] | length' "$FATQ_ROOT/pending/${tid}.json")" == "0" ]] || fail "INFRA1: explicit non-critical reviewer must not produce rewrite history" || return 1

  # 對照組：不含公共財關鍵字的一般任務不受影響
  local out2 tid2
  out2=$(run_cli create --as anya --slug normal-task --goal "寫日報" \
    --background b --context "整理今天對話" \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid2=$(jq -r '.task_id' <<<"$out2")
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid2}.json")" == "yitang" ]] || fail "INFRA1: non-infra task's reviewer must not be overridden" || return 1
  return 0
}

test_INFRA2() {
  local out tid reviewer hist_count

  out=$(run_cli create --as anya --slug infra-fp-flow --goal "跑通 pending→dispatch→QA 全流程" \
    --background b --context "低風險前端單" \
    --deliverables '["調整卡片文字","補一個前端 fixture","整理 QA 截圖"]' \
    --acceptance_criteria '["流程可跑完"]' --out_of_scope '["不改 shared"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 false-positive #1: process words dispatch/QA must not force bella, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-fp-gateway-copy --goal "文案說明 gateway 使用體驗" \
    --background b --context "只改 MVP 頁面 copy" \
    --deliverables '["把 gateway 一詞翻成入口","補 UI 截圖","不碰程式碼"]' \
    --acceptance_criteria '["copy 顯示正確"]' --out_of_scope '["不改 shared/ 路徑"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 false-positive #2: descriptive gateway wording must not force bella, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-fp-systemd-doc --goal "整理 systemd 事故回顧" \
    --background b --context "文件摘要，不改服務" \
    --deliverables '["寫 retrospective","列 lessons","通知團隊"]' \
    --acceptance_criteria '["文件存在"]' --out_of_scope '["不改 systemd unit"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 false-positive #3: descriptive systemd wording must not force bella, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-tp-shared-bin --goal "補前端 fixture" \
    --background b --context "交付需修改 shared/bin/fatq-cli.sh" \
    --deliverables '["shared/bin/fatq-cli.sh","fixture 誤傷例","fixture 漏放例"]' \
    --acceptance_criteria '["shared/bin 路徑必強制 bella"]' --out_of_scope '["不改 reviewer pool"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 true-positive #1: shared/bin path is infra but explicit pool reviewer must be respected, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-tp-goal-gateway --goal "修改 gateway routing guard" \
    --background b --context "避免 misroute" \
    --deliverables '["isolated patch","test"]' \
    --acceptance_criteria '["gateway change must be infra"]' --out_of_scope '["不重啟服務"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 true-positive #2: non-critical gateway change must respect explicit yitang, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-tp-goal-fix-gateway --goal "fix gateway routing guard" \
    --background b --context "avoid routing leak" \
    --deliverables '["isolated patch","test"]' \
    --acceptance_criteria '["gateway fix must be infra"]' --out_of_scope '["不重啟服務"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 true-positive #3: English gateway fix must respect explicit yitang, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-tp-goal-update-db --goal "Update database schema migration" \
    --background b --context "isolated patch" \
    --deliverables '["migration test"]' \
    --acceptance_criteria '["database/schema update must be infra"]' --out_of_scope '["不重啟服務"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "yitang" ]] || fail "INFRA2 true-positive #4: database/schema change must respect explicit yitang, got $reviewer" || return 1

  out=$(run_cli create --as anya --slug infra-tp-systemd --goal "修 systemd restart guard" \
    --background b --context "隔離 patch" \
    --deliverables '["test"]' \
    --acceptance_criteria '["systemd guard change must be infra"]' --out_of_scope '["不重啟服務"]' \
    --review_focus r --reviewer yitang --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$reviewer" == "bella" ]] || fail "INFRA2 true-positive #5: explicit goal systemd fix must force bella, got $reviewer" || return 1
  hist_count=$(jq -r '[.history[]? | select(.action=="infra_gate_rewrite")] | length' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$hist_count" == "1" ]] || fail "INFRA2 true-positive #5: infra_gate_rewrite history missing" || return 1

  return 0
}

test_INFRA3() {
  local i out tid reviewers=""
  for i in 1 2 3 4; do
    out=$(run_cli create --as anya --slug "infra-dist-$i" --goal "修改公共腳本" \
      --background b --context "shared/bin/fatq-cli.sh" \
      --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --json 2>/dev/null) || return 1
    tid=$(jq -r '.task_id' <<<"$out")
    reviewers+="$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json") "
  done
  [[ "$(tr ' ' '\n' <<<"$reviewers" | grep -cx bella)" == "2" ]] \
    || fail "INFRA3: expected two Bella assignments, got $reviewers" || return 1
  [[ "$(tr ' ' '\n' <<<"$reviewers" | grep -cx yitang)" == "2" ]] \
    || fail "INFRA3: expected two Yitang assignments, got $reviewers" || return 1
  return 0
}

test_INFRA4() {
  local goal slug out tid reviewer rewrites=0
  for slug in daemon security deploy; do
    case "$slug" in
      daemon) goal="修 systemd daemon restart guard" ;;
      security) goal="修改 gateway security credential guard" ;;
      deploy) goal="修改 gateway production deploy gate" ;;
    esac
    out=$(run_cli create --as anya --slug "infra-critical-$slug" --goal "$goal" \
      --background b --context "shared/bin/fatq-cli.sh" \
      --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --reviewer yitang --json 2>/dev/null) || return 1
    tid=$(jq -r '.task_id' <<<"$out")
    reviewer=$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")
    [[ "$reviewer" == "bella" ]] || fail "INFRA4: $slug gate must force Bella, got $reviewer" || return 1
    rewrites=$((rewrites + $(jq '[.history[] | select(.action=="infra_gate_rewrite"
      and .original_reviewer=="yitang" and .forced_reviewer=="bella")] | length' "$FATQ_ROOT/pending/${tid}.json")))
  done
  [[ "$rewrites" == "3" ]] || fail "INFRA4: expected three auditable explicit critical rewrites, got $rewrites" || return 1
  return 0
}

test_INFRA5() {
  local reviewer out tid
  for reviewer in bella yitang; do
    out=$(run_cli create --as anya --slug "infra-explicit-$reviewer" --goal "修改共用腳本" \
      --background b --context "shared/bin/fatq-cli.sh" \
      --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --reviewer "$reviewer" --json 2>/dev/null) || return 1
    tid=$(jq -r '.task_id' <<<"$out")
    [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "$reviewer" ]] \
      || fail "INFRA5: explicit $reviewer was rewritten" || return 1
  done
  return 0
}

test_INFRA6() {
  make_task "$FATQ_ROOT/review/bella-busy.json" '{"task_id":"bella-busy","status":"review","reviewer":"bella"}'
  local out tid
  out=$(run_cli create --as anya --slug infra-load --goal "修改共用腳本" \
    --background b --context "shared/bin/fatq-cli.sh" \
    --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --json 2>/dev/null) || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "yitang" ]] \
    || fail "INFRA6: lower review/ load should select Yitang" || return 1
  return 0
}

test_INFRA7() {
  local i out tid f sample_count
  for i in $(seq 1 11); do
    out=$(run_cli create --as anya --slug "infra-probation-$i" --goal "修改共用腳本" \
      --background b --context "shared/bin/fatq-cli.sh" \
      --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --reviewer yitang --json 2>/dev/null) || return 1
    tid=$(jq -r '.task_id' <<<"$out")
    f="$FATQ_ROOT/pending/${tid}.json"
    if (( i <= 10 )); then
      [[ "$(jq -r '[.history[] | select(.action=="infra_reviewer_probation")] | length' "$f")" == "1" ]] \
        || fail "INFRA7: probation entry missing at sequence $i" || return 1
    else
      [[ "$(jq -r '[.history[] | select(.action=="infra_reviewer_probation")] | length' "$f")" == "0" ]] \
        || fail "INFRA7: sequence 11 must be outside probation" || return 1
    fi
  done
  [[ "$(jq -s 'length' "$FATQ_TRUST_LEDGER_AUDIT")" == "10" ]] \
    || fail "INFRA7: trust ledger must contain exactly first 10 assignments" || return 1
  sample_count=$(jq -s '[.[] | select(.bella_recheck_sample == true)] | length' "$FATQ_TRUST_LEDGER_AUDIT")
  [[ "$sample_count" == "3" ]] || fail "INFRA7: Bella must recheck exactly 3 of first 10, got $sample_count" || return 1
  [[ "$(jq -s '[.[] | select(.bella_recheck_sample == true) | .probation_sequence] == [1,4,7]' "$FATQ_TRUST_LEDGER_AUDIT")" == "true" ]] \
    || fail "INFRA7: deterministic sample must be sequences 1,4,7" || return 1
  return 0
}

test_INFRA8() {
  local i pid rc=0 bella_count yitang_count
  local pids=()
  for i in $(seq 1 8); do
    (
      run_cli create --as anya --slug "infra-concurrent-$i" --goal "修改共用腳本" \
        --background b --context "shared/bin/fatq-cli.sh" \
        --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
        --out_of_scope '["o"]' --review_focus r --json \
        >"$TMPROOT/create-$i.json" 2>"$TMPROOT/create-$i.err"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done
  [[ "$rc" == "0" ]] || fail "INFRA8: at least one concurrent create failed" || return 1
  bella_count=$(jq -r '.reviewer' "$FATQ_ROOT/pending/"*.json | grep -cx bella)
  yitang_count=$(jq -r '.reviewer' "$FATQ_ROOT/pending/"*.json | grep -cx yitang)
  [[ "$bella_count" == "4" && "$yitang_count" == "4" ]] \
    || fail "INFRA8: lock must keep concurrent tie-break balanced, got bella=$bella_count yitang=$yitang_count" || return 1
  return 0
}

test_INFRA9() {
  local f="$FATQ_ROOT/review/infra-probation-verdict.json" rc relay_file
  make_task "$f" '{
    "task_id":"infra-probation-verdict",
    "status":"review",
    "assigned":"anna",
    "reviewer":"yitang",
    "history":[{
      "ts":"2026-01-01T00:00:00+08:00",
      "by":"anya",
      "via":"fatq-cli",
      "action":"infra_reviewer_probation",
      "reviewer":"yitang",
      "probation_sequence":4,
      "bella_recheck_sample":true,
      "advisory_only":true,
      "task_id":"infra-probation-verdict"
    }]
  }'
  run_cli verdict approve infra-probation-verdict --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "INFRA9 Yitang verdict" || return 1
  [[ "$(state_dir_of infra-probation-verdict)" == "done" ]] \
    || fail "INFRA9: advisory recheck must not block verdict" || return 1
  jq -s -e 'any(.[]; .event=="infra_reviewer_probation_verdict"
    and .subject_id=="yitang" and .probation_sequence==4
    and .bella_recheck_sample==true and .verdict=="approve"
    and .advisory_only==true)' "$FATQ_TRUST_LEDGER_AUDIT" >/dev/null \
    || fail "INFRA9: trust ledger verdict audit missing" || return 1
  relay_file="$FATQ_RELAY_DIR/fatq-yitang-infra-recheck-infra-probation-verdict.json"
  [[ -f "$relay_file" ]] || fail "INFRA9: Bella advisory recheck relay missing" || return 1
  [[ "$(jq -r '.recipient' "$relay_file")" == "bella" ]] \
    || fail "INFRA9: advisory relay must target Bella" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CREATEAFF1-4（org-design-lines-20260707 決議 #2，b3d7）：create 層業務線
# 親和預填——d5c3 揭示 cron 層親和違紅線後，Anya 裁決真自動指派換層到 create
# （唯一合法寫手層，缺省欄位在建檔當下直接寫入，不會有「假裝欄位已寫」問題）。
# ═══════════════════════════════════════════════════════════════════════════

test_CREATEAFF1() {
  # 缺省預填：assigned/reviewer 都沒傳，依 created_by=caijie-zhuchu 的親和表填入
  local out rc
  out=$(run_cli create --as caijie-zhuchu --slug aff1 --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "CREATEAFF1" || return 1
  local tid
  tid=$(jq -r '.task_id' <<<"$out")
  [[ "$(jq -r '.assigned' "$FATQ_ROOT/pending/${tid}.json")" == "sancai" ]] || fail "CREATEAFF1: assigned 應預填 sancai（caijie-zhuchu 親和 builder），實得 $(jq -r '.assigned' "$FATQ_ROOT/pending/${tid}.json")" || return 1
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "yitang" ]] || fail "CREATEAFF1: reviewer 應預填 yitang（caijie-zhuchu 親和 reviewer），實得 $(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" || return 1
  return 0
}

test_CREATEAFF2() {
  # 明文尊重：assigned/reviewer 都明文傳入 → 一律尊重，不套用親和表，不產生 affinity_prefill history
  local out tid
  out=$(run_cli create --as caijie-zhuchu --slug aff2 --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer ron-reviewer --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  [[ "$(jq -r '.assigned' "$FATQ_ROOT/pending/${tid}.json")" == "anna" ]] || fail "CREATEAFF2: 明文 assigned=anna 不該被親和表覆蓋" || return 1
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "ron-reviewer" ]] || fail "CREATEAFF2: 明文 reviewer=ron-reviewer 不該被親和表覆蓋" || return 1
  local prefill_count
  prefill_count=$(jq '[.history[] | select(.action=="affinity_prefill")] | length' "$FATQ_ROOT/pending/${tid}.json")
  [[ "$prefill_count" == "0" ]] || fail "CREATEAFF2: 明文指定時不該產生 affinity_prefill history，實得 $prefill_count" || return 1
  return 0
}

test_CREATEAFF3() {
  # 未知身份 fallback 工程線：created_by 不在親和表任何鍵（如 mac-agent）→ 落 default（anna/bella）
  local out tid
  out=$(run_cli create --as mac-agent --slug aff3 --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --deliver_to anya --json 2>/dev/null)
  tid=$(jq -r '.task_id' <<<"$out")
  [[ "$(jq -r '.assigned' "$FATQ_ROOT/pending/${tid}.json")" == "anna" ]] || fail "CREATEAFF3: 未知身份應 fallback default builder=anna，實得 $(jq -r '.assigned' "$FATQ_ROOT/pending/${tid}.json")" || return 1
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "bella" ]] || fail "CREATEAFF3: 未知身份應 fallback default reviewer=bella，實得 $(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" || return 1
  return 0
}

test_CREATEAFF4() {
  # history 記錄可稽核：affinity_prefill 行含 prefilled_assigned/prefilled_reviewer；
  # 凍結契約（create --json schema）不受影響
  local out rc tid
  out=$(run_cli create --as caijie-zhuchu --slug aff4 --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "CREATEAFF4" || return 1
  # 凍結契約：create --json 輸出仍是 {ok,task_id,from,to,history_appended}，只增不改不刪
  for key in ok task_id from to history_appended; do
    [[ "$(jq "has(\"$key\")" <<<"$out")" == "true" ]] || fail "CREATEAFF4: create --json 輸出缺少凍結契約欄位 '$key'" || return 1
  done
  tid=$(jq -r '.task_id' <<<"$out")
  local prefill_entry
  prefill_entry=$(jq -c '.history[] | select(.action=="affinity_prefill")' "$FATQ_ROOT/pending/${tid}.json")
  [[ -n "$prefill_entry" ]] || fail "CREATEAFF4: 應有 1 筆 affinity_prefill history" || return 1
  [[ "$(jq -r '.prefilled_assigned' <<<"$prefill_entry")" == "sancai" ]] || fail "CREATEAFF4: history 應記錄 prefilled_assigned=sancai" || return 1
  [[ "$(jq -r '.prefilled_reviewer' <<<"$prefill_entry")" == "yitang" ]] || fail "CREATEAFF4: history 應記錄 prefilled_reviewer=yitang" || return 1
  [[ "$(jq -r '.via' <<<"$prefill_entry")" == "fatq-cli" ]] || fail "CREATEAFF4: history 行應含 via=fatq-cli" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# EXTID1/EXTID2 — 身份名單改讀 team-config.json external_identities（Q5 裁決，
# anya 2026-07-07 補充要求：不再寫死 EXTRA_IDENTITIES，mac-agent 已加 9 個
# web 身份，CLI 需單一權威源，不然 laotu 以外的 web 身份會被拒）
# ═══════════════════════════════════════════════════════════════════════════
test_EXTID1() {
  # "ron-web-identity" 只存在於 fixture 的 external_identities，不在
  # shared_pools/assistants 裡——若 CLI 還是靠寫死清單判斷，這個身份會被拒。
  local f="$FATQ_ROOT/pending/extid1.json"
  make_task "$f" '{"task_id":"extid1","assigned":"anna"}'
  local rc
  run_cli comment extid1 --as ron-web-identity --text "hi" >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "EXTID1 (identity only in external_identities must be recognized)" || return 1
  return 0
}

test_EXTID2() {
  # 未知子命令錯誤訊息必須含「未知子命令」字樣（mac-agent fixture 靠此字串偵測）
  local err rc
  err=$(run_cli approval bogus-action --as anna 2>&1); rc=$?
  assert_exit 2 "$rc" "EXTID2 (unknown approval sub-action)" || return 1
  [[ "$err" == *"未知子命令"* ]] || fail "EXTID2: error message must contain '未知子命令', got: $err" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CLOCK1-3（f7d9，時鐘完整性雙防呆）：Bella 反證定案的三修正案①②——史實是
# a7e5 的 history 條目疑似受 FATQ_NOW_ISO 洩漏污染（後查證：實際上我方
# via=fatq-cli 的條目全數嚴格遞增，污染源另有其人，見 last_run_summary），
# 但這兩條防呆本身是紮實的縱深防禦，值得留。
# ═══════════════════════════════════════════════════════════════════════════

test_CLOCK1() {
  # 驗收①：fixture 路徑（非生產）注入時鐘照常生效——不破壞既有測試能力。
  # 本測試本身就是最直接的證據：全套 fixture 測試都靠 FATQ_NOW_ISO/EPOCH
  # 注入固定時鐘才能穩定斷言，這裡額外做一個聚焦、單一目的的斷言。
  export FATQ_NOW_ISO="2026-01-01T00:00:00+08:00"
  local f="$FATQ_ROOT/pending/clock1.json"
  make_task "$f" '{"task_id":"clock1","assigned":"anna"}'
  run_cli comment clock1 --as anna --text "probe" >/dev/null 2>&1
  local ts
  ts=$(jq -r '.history[-1].ts' "$f")
  [[ "$ts" == "2026-01-01T00:00:00+08:00" ]] || fail "CLOCK1: fixture 路徑應採用注入時鐘，實得 $ts" || return 1
  unset FATQ_NOW_ISO
  return 0
}

test_CLOCK2() {
  # 驗收②：生產路徑一律無視 FATQ_NOW_ISO 注入。不對真實 tasks/ 動手——把
  # FATQ_PROD_ROOT 覆寫成等於本次 fixture 的 FATQ_ROOT，模擬「這就是生產
  # 路徑」的情境，完整驗證 is_prod_root() 比對邏輯本身，不需真的碰
  # /home/oldrabbit/.claude-bots/tasks（[[feedback_closed_loop_test_fixture]]）。
  export FATQ_PROD_ROOT="$FATQ_ROOT"
  export FATQ_NOW_ISO="2026-01-01T00:00:00+08:00"
  local f="$FATQ_ROOT/pending/clock2.json"
  make_task "$f" '{"task_id":"clock2","assigned":"anna"}'
  local before after
  before=$(date +%s)
  run_cli comment clock2 --as anna --text "probe" >/dev/null 2>&1
  after=$(date +%s)
  local ts ts_epoch
  ts=$(jq -r '.history[-1].ts' "$f")
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null)
  [[ "$ts" != "2026-01-01T00:00:00+08:00" ]] || fail "CLOCK2: 生產路徑不該採用注入時鐘（應被忽略），但實際寫入了注入值" || return 1
  [[ "$ts_epoch" -ge "$before" && "$ts_epoch" -le "$after" ]] || fail "CLOCK2: 生產路徑應改用系統當下時鐘，實得 $ts（不在 [$before,$after] 範圍內）" || return 1
  unset FATQ_PROD_ROOT FATQ_NOW_ISO
  return 0
}

test_CLOCK3() {
  # 驗收②-單調性：新條目 ts 早於前一筆時，改用系統時鐘並插入 clock_warn。
  # 手法：先用正常時鐘 append 一筆基準，再切換到「過去」時鐘（模擬污染注入）
  # 觸發下一筆 append，驗證系統糾偏。
  local f="$FATQ_ROOT/pending/clock3.json"
  make_task "$f" '{"task_id":"clock3","assigned":"anna"}'
  unset FATQ_NOW_ISO || true
  run_cli comment clock3 --as anna --text "baseline" >/dev/null 2>&1
  local baseline_ts baseline_epoch
  baseline_ts=$(jq -r '.history[-1].ts' "$f")
  baseline_epoch=$(date -d "$baseline_ts" +%s)

  # 注入一個早於 baseline 的時鐘（模擬 FATQ_NOW_ISO 污染殘留）
  local injected_ts="$(TZ=Asia/Taipei date -d "@$((baseline_epoch - 1200))" '+%Y-%m-%dT%H:%M:%S+08:00')"
  export FATQ_NOW_ISO="$injected_ts"
  local before after
  before=$(date +%s)
  run_cli comment clock3 --as anna --text "polluted" >/dev/null 2>&1
  after=$(date +%s)
  unset FATQ_NOW_ISO

  local n last_action last_ts warn_action warn_ts warn_attempted
  n=$(jq '.history | length' "$f")
  [[ "$n" == "3" ]] || fail "CLOCK3: 預期 baseline+clock_warn+polluted 共 3 筆 history（make_task 起手 history 為空），實得 $n" || return 1

  warn_action=$(jq -r '.history[-2].action' "$f")
  warn_ts=$(jq -r '.history[-2].ts' "$f")
  warn_attempted=$(jq -r '.history[-2].attempted_ts' "$f")
  [[ "$warn_action" == "clock_warn" ]] || fail "CLOCK3: 倒數第二筆應為 clock_warn，實得 $warn_action" || return 1
  [[ "$warn_attempted" == "$injected_ts" ]] || fail "CLOCK3: clock_warn 應記錄原本被拒的注入值 $injected_ts，實得 $warn_attempted" || return 1

  last_action=$(jq -r '.history[-1].action' "$f")
  last_ts=$(jq -r '.history[-1].ts' "$f")
  [[ "$last_action" == "comment" ]] || fail "CLOCK3: 最後一筆應是原本要寫的 comment 動作，只是 ts 被糾正" || return 1
  local last_epoch
  last_epoch=$(date -d "$last_ts" +%s)
  [[ "$last_epoch" -ge "$before" && "$last_epoch" -le "$after" ]] || fail "CLOCK3: 最後一筆的 ts 應被糾正為系統當下時鐘，實得 $last_ts（不在 [$before,$after] 範圍內）" || return 1
  [[ "$last_epoch" -ge "$baseline_epoch" ]] || fail "CLOCK3: 糾正後仍不得早於前一筆基準 $baseline_ts" || return 1
  return 0
}

test_CLOCK4() {
  # 35e2：history 新條目若超前 now+skew，應插入 clock_warn 並把該條目 ts
  # 糾正為系統時鐘。這裡用 fake date 只替本次 run_cli 注入固定未來 timestamp，
  # guard 的 now_epoch 則回固定基準秒，穩定覆蓋 future-skew 分支。
  local f="$FATQ_ROOT/pending/clock4.json"
  make_task "$f" '{"task_id":"clock4","assigned":"anna"}'
  run_cli comment clock4 --as anna --text "baseline" >/dev/null 2>&1

  local fake_bin fake_state base_epoch base_iso future_ts
  fake_bin="$TMPROOT/fake-bin"
  fake_state="$TMPROOT/clock4-date-state"
  mkdir -p "$fake_bin"
  base_epoch="$(/usr/bin/date +%s)"
  base_iso="$(TZ=Asia/Taipei date -d "@$base_epoch" '+%Y-%m-%dT%H:%M:%S+08:00')"
  future_ts="$(TZ=Asia/Taipei date -d "@$((base_epoch + 3600))" '+%Y-%m-%dT%H:%M:%S+08:00')"
  printf '0\n' > "$fake_state"
  cat > "$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" ]]; then
  exec /usr/bin/date "$@"
fi
if [[ "${1:-}" == "+%s" ]]; then
  printf '%s\n' "$FATQ_CLOCK4_BASE_EPOCH"
  exit 0
fi
if [[ "${1:-}" == "+%Y-%m-%dT%H:%M:%S+08:00" ]]; then
  n="$(cat "$FATQ_CLOCK4_STATE" 2>/dev/null || printf '0')"
  if [[ "$n" == "0" ]]; then
    printf '1\n' > "$FATQ_CLOCK4_STATE"
    printf '%s\n' "$FATQ_CLOCK4_FUTURE_TS"
  else
    printf '%s\n' "$FATQ_CLOCK4_BASE_ISO"
  fi
  exit 0
fi
exec /usr/bin/date "$@"
EOF
  chmod +x "$fake_bin/date"

  FATQ_CLOCK4_BASE_EPOCH="$base_epoch" \
  FATQ_CLOCK4_BASE_ISO="$base_iso" \
  FATQ_CLOCK4_FUTURE_TS="$future_ts" \
  FATQ_CLOCK4_STATE="$fake_state" \
  PATH="$fake_bin:$PATH" \
    run_cli comment clock4 --as anna --text "future guard" >/dev/null 2>&1

  local n warn_action warn_note warn_attempted last_action last_ts
  n=$(jq '.history | length' "$f")
  [[ "$n" == "3" ]] || fail "CLOCK4: 預期 baseline+clock_warn+comment 共 3 筆 history，實得 $n" || return 1
  warn_action=$(jq -r '.history[-2].action' "$f")
  warn_note=$(jq -r '.history[-2].note' "$f")
  warn_attempted=$(jq -r '.history[-2].attempted_ts' "$f")
  last_action=$(jq -r '.history[-1].action' "$f")
  last_ts=$(jq -r '.history[-1].ts' "$f")
  [[ "$warn_action" == "clock_warn" ]] || fail "CLOCK4: 倒數第二筆應為 clock_warn，實得 $warn_action" || return 1
  echo "$warn_note" | grep -q "未來時戳防呆" || fail "CLOCK4: clock_warn note 應標明未來時戳防呆，實得 $warn_note" || return 1
  [[ "$warn_attempted" == "$future_ts" ]] || fail "CLOCK4: clock_warn 應記錄被拒的固定未來值 $future_ts，實得 $warn_attempted" || return 1
  [[ "$last_action" == "comment" ]] || fail "CLOCK4: 最後一筆應保留原 comment 動作，實得 $last_action" || return 1
  [[ "$last_ts" == "$base_iso" ]] || fail "CLOCK4: 最後一筆 ts 應被糾正為固定基準時鐘 $base_iso，實得 $last_ts" || return 1
  return 0
}

test_CLOCK5() {
  # 35e2：verdict 禁止外部傳入 ts；未來 ts 必須拒絕，且任務不得移動。
  local f="$FATQ_ROOT/review/clock5.json"
  make_task "$f" '{"task_id":"clock5","assigned":"anna","reviewer":"yitang","status":"review"}'
  local future_ts rc
  future_ts="$(TZ=Asia/Taipei date -d "@$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%M:%S+08:00')"
  run_cli verdict reject clock5 --as yitang --reason "bad" --ts "$future_ts" >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "CLOCK5 (verdict rejects external future --ts)" || return 1
  [[ "$(state_dir_of clock5)" == "review" ]] || fail "CLOCK5: future --ts rejected task must remain review/, got $(state_dir_of clock5)" || return 1
  [[ "$(history_len "$f")" == "0" ]] || fail "CLOCK5: rejected --ts must not append history" || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# runner
# ═══════════════════════════════════════════════════════════════════════════
run_test() {
  local name="$1"
  setup
  echo "── $name ──"
  if "test_$name"; then
    echo "  ✅ $name PASS"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    echo "  ❌ $name FAIL"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAIL_NAMES+=("$name")
  fi
  teardown
}

# ═══════════════════════════════════════════════════════════════════════════
# ATTACH — d1c9：需求單附件 metadata 記錄（mvp-server.ts 驗完型別/落地檔案後
# 呼叫這裡登記，本身不碰檔案本體，純 task JSON 附加）
# ═══════════════════════════════════════════════════════════════════════════
test_ATTACH1() {
  local f="$FATQ_ROOT/pending/attach1.json"
  make_task "$f" '{"task_id":"attach1","assigned":"anna"}'
  run_cli attach attach1 --as anna --file "uuid-abc.png" --name "screenshot.png" --mime "image/png" --size 12345 >/dev/null 2>&1
  local att_len att_name att_mime att_size hist_action hist_name
  att_len=$(jq '.attachments | length' "$f")
  att_name=$(jq -r '.attachments[0].name' "$f")
  att_mime=$(jq -r '.attachments[0].mime' "$f")
  att_size=$(jq -r '.attachments[0].size' "$f")
  hist_action=$(jq -r '.history[-1].action' "$f")
  hist_name=$(jq -r '.history[-1].name' "$f")
  [[ "$att_len" == "1" ]] || fail "ATTACH1: expected 1 attachment, got $att_len" || return 1
  [[ "$att_name" == "screenshot.png" ]] || fail "ATTACH1: attachment name wrong: $att_name" || return 1
  [[ "$att_mime" == "image/png" ]] || fail "ATTACH1: mime wrong: $att_mime" || return 1
  [[ "$att_size" == "12345" ]] || fail "ATTACH1: size wrong: $att_size" || return 1
  [[ "$hist_action" == "attachment_added" ]] || fail "ATTACH1: history action wrong: $hist_action" || return 1
  [[ "$hist_name" == "screenshot.png" ]] || fail "ATTACH1: history name wrong: $hist_name" || return 1
  return 0
}

# ATTACH2 — 回歸守門：is_known_identity/is_reviewer_pool/is_builder_pool 內部
# while-read 迴圈變數過去沒宣告 local、直接叫 `name`——跟 cmd_attach 自己的
# local name（--name 的值）撞名，resolve_identity 一跑就把 --name 的值覆寫成
# identity 字串。這裡故意讓 --name 的值明顯不同於 --as 的 identity，撞名 bug
# 回歸的話這裡會直接測出 attachments[0].name 變成 identity 字串。
test_ATTACH2() {
  local f="$FATQ_ROOT/pending/attach2.json"
  make_task "$f" '{"task_id":"attach2","assigned":"anna"}'
  run_cli attach attach2 --as anna --file "uuid-def.pdf" --name "totally-different-filename.pdf" --mime "application/pdf" --size 999 >/dev/null 2>&1
  local att_name
  att_name=$(jq -r '.attachments[0].name' "$f")
  [[ "$att_name" == "totally-different-filename.pdf" ]] || fail "ATTACH2 REGRESSION: --name 被 identity 覆寫了！got '$att_name' (identity 是 'anna')，is_known_identity 等函式的 while-read name 迴圈變數沒宣告 local" || return 1
  return 0
}

test_ATTACH3() {
  local f="$FATQ_ROOT/pending/attach3.json"
  make_task "$f" '{"task_id":"attach3","assigned":"anna"}'
  local rc
  run_cli attach attach3 --as anna --file "x.png" --mime "image/png" --size 1 >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "ATTACH3 (missing --name -> E_USAGE)" || return 1
  return 0
}

test_ATTACH4() {
  local f="$FATQ_ROOT/pending/attach4.json"
  make_task "$f" '{"task_id":"attach4","assigned":"anna"}'
  local rc
  run_cli attach attach4 --as anna --file "../../etc/passwd" --name "x" --mime "image/png" --size 1 >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "ATTACH4 (path traversal in --file -> E_USAGE)" || return 1
  [[ "$(jq '.attachments // [] | length' "$f")" == "0" ]] || fail "ATTACH4: 路徑穿越檔名竟然被登記進去了" || return 1
  return 0
}

test_ATTACH5() {
  local rc
  run_cli attach does-not-exist-task --as anna --file "x.png" --name "x" --mime "image/png" --size 1 >/dev/null 2>&1; rc=$?
  assert_exit 7 "$rc" "ATTACH5 (unknown task_id -> E_NOTFOUND)" || return 1
  return 0
}

test_ENFORCE1() {
  local f="$FATQ_ROOT/pending/revclaim.json"
  make_task "$f" '{"task_id":"revclaim","assigned":"yitang","reviewer":"bella","skills":["spec-review"]}'
  local rc
  run_cli claim revclaim --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ENFORCE1 (assigned reviewer may claim spec-review task)" || return 1
  run_cli submit revclaim --as yitang >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ENFORCE1 (assigned reviewer may submit spec-review task)" || return 1
  [[ "$(state_dir_of revclaim)" == "review" ]] || fail "ENFORCE1: expected review/" || return 1
  return 0
}

# PERMPOOL1 — builder/designer pool 都可轉移自己的任務，但 assigned 邊界保持獨立。
# 三個真實身份各跑 claim+submit happy path，再各自嘗試碰別人的任務；非池身份即使
# assigned 寫自己仍須 fail-closed，避免把「池資格」擴充誤解成放寬任務歸屬。
test_PERMPOOL1() {
  local identity f rc
  for identity in sara twinkle eric; do
    f="$FATQ_ROOT/pending/perm-${identity}.json"
    make_task "$f" "{\"task_id\":\"perm-${identity}\",\"assigned\":\"${identity}\"}"
    run_cli claim "perm-${identity}" --as "$identity" >/dev/null 2>&1; rc=$?
    assert_exit 0 "$rc" "PERMPOOL1 ($identity claims own task)" || return 1
    run_cli submit "perm-${identity}" --as "$identity" >/dev/null 2>&1; rc=$?
    assert_exit 0 "$rc" "PERMPOOL1 ($identity submits own task)" || return 1
    [[ "$(state_dir_of "perm-${identity}")" == "review" ]] || fail "PERMPOOL1: $identity task should reach review/" || return 1

    f="$FATQ_ROOT/pending/perm-${identity}-foreign.json"
    make_task "$f" "{\"task_id\":\"perm-${identity}-foreign\",\"assigned\":\"anna\"}"
    run_cli claim "perm-${identity}-foreign" --as "$identity" >/dev/null 2>&1; rc=$?
    assert_exit 3 "$rc" "PERMPOOL1 ($identity cannot claim anna task)" || return 1
    [[ "$(state_dir_of "perm-${identity}-foreign")" == "pending" ]] || fail "PERMPOOL1: foreign task moved for $identity" || return 1
  done

  f="$FATQ_ROOT/pending/perm-orange.json"
  make_task "$f" '{"task_id":"perm-orange","assigned":"orange"}'
  run_cli claim perm-orange --as orange >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "PERMPOOL1 (orange outside eligible pools)" || return 1
  [[ "$(state_dir_of perm-orange)" == "pending" ]] || fail "PERMPOOL1: orange task must not move" || return 1
  return 0
}

test_ENFORCE2() {
  local f="$FATQ_ROOT/pending/force1.json"
  make_task "$f" '{"task_id":"force1","assigned":"anna"}'
  local rc
  run_cli force-mv force1 review --as anna --reason "manual repair" >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "ENFORCE2 (non-admin force-mv rejected)" || return 1
  run_cli force-mv force1 review --as anya >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "ENFORCE2 (force-mv requires reason)" || return 1
  run_cli force-mv force1 review --as anya --reason "break glass for stuck reviewer claim" >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ENFORCE2 (admin force-mv with reason)" || return 1
  [[ "$(state_dir_of force1)" == "review" ]] || fail "ENFORCE2: expected review/" || return 1
  [[ -f "$FATQ_OVERRIDE_AUDIT" ]] || fail "ENFORCE2: override audit file missing" || return 1
  [[ "$(jq -r 'select(.task_id=="force1") | .actor + "|" + .overridden_rule + "|" + .reason' "$FATQ_OVERRIDE_AUDIT")" == "anya|fatq_state_machine|break glass for stuck reviewer claim" ]] || fail "ENFORCE2: audit row missing actor/rule/reason" || return 1
  [[ "$(jq -r '.history[-1].action' "$FATQ_ROOT/review/force1.json")" == "force_mv" ]] || fail "ENFORCE2: history action should be force_mv" || return 1
  return 0
}

test_ENFORCE3() {
  local f="$FATQ_ROOT/pending/val1.json"
  make_task "$f" '{"task_id":"val1","assigned":"anna","status":"in_progress"}'
  local out rc
  out=$(run_cli validate --json 2>&1); rc=$?
  assert_exit 0 "$rc" "ENFORCE3 (validator fail-open exit)" || return 1
  echo "$out" | jq -e '.ok == true and .mode == "advisory" and ([.violations[].issue] | index("dir_status_mismatch") != null)' >/dev/null || fail "ENFORCE3: expected advisory dir_status_mismatch" || return 1
  return 0
}

test_ENFORCE4() {
  touch "$FATQ_ROOT/.fatq-enforcement-off"
  local f="$FATQ_ROOT/pending/val2.json"
  make_task "$f" '{"task_id":"val2","assigned":"anna","status":"review"}'
  local out rc
  out=$(run_cli validate --json 2>&1); rc=$?
  assert_exit 0 "$rc" "ENFORCE4 (kill-switch exits open)" || return 1
  echo "$out" | jq -e '.ok == true and .mode == "disabled" and (.violations | length) == 0' >/dev/null || fail "ENFORCE4: expected disabled/zero violations" || return 1
  return 0
}

test_ADVISOR1() {
  local f="$FATQ_ROOT/in_progress/advisor1.json" out err rc
  make_real_submit_task "$f" "advisor1" "true" "0" || return 1
  out=$(run_cli submit advisor1 --as anna 2>"$TMPROOT/advisor1.err"); rc=$?
  err=$(cat "$TMPROOT/advisor1.err")
  assert_exit 0 "$rc" "ADVISOR1 (advisor_required true without checkpoint is warn-only)" || return 1
  [[ "$(state_dir_of advisor1)" == "review" ]] || fail "ADVISOR1: expected review/" || return 1
  [[ "$err" == *"NOTICE:"* && "$err" == *"advisor_required"* && "$err" == *"[advisor]"* ]] || fail "ADVISOR1: expected advisor NOTICE on stderr, got: $err" || return 1
  [[ "$out" == *"submit OK"* ]] || fail "ADVISOR1: expected normal submit stdout, got: $out" || return 1
  return 0
}

test_ADVISOR2() {
  local f="$FATQ_ROOT/in_progress/advisor2.json" err rc
  make_real_submit_task "$f" "advisor2" "true" "1" || return 1
  run_cli submit advisor2 --as anna >"$TMPROOT/advisor2.out" 2>"$TMPROOT/advisor2.err"; rc=$?
  err=$(cat "$TMPROOT/advisor2.err")
  assert_exit 0 "$rc" "ADVISOR2 (advisor_required true with checkpoint)" || return 1
  [[ "$(state_dir_of advisor2)" == "review" ]] || fail "ADVISOR2: expected review/" || return 1
  [[ "$err" != *"NOTICE:"* ]] || fail "ADVISOR2: should not print NOTICE when [advisor] comment exists, got: $err" || return 1
  return 0
}

test_ADVISOR3() {
  local f="$FATQ_ROOT/in_progress/advisor3.json" before after err rc
  make_real_submit_task "$f" "advisor3" "null" "0" || return 1
  before=$(jq -S 'del(.history, .status, .transition_token)' "$f")
  run_cli submit advisor3 --as anna >"$TMPROOT/advisor3.out" 2>"$TMPROOT/advisor3.err"; rc=$?
  err=$(cat "$TMPROOT/advisor3.err")
  assert_exit 0 "$rc" "ADVISOR3 (advisor_required absent preserves existing behavior)" || return 1
  [[ "$(state_dir_of advisor3)" == "review" ]] || fail "ADVISOR3: expected review/" || return 1
  [[ "$err" != *"NOTICE:"* ]] || fail "ADVISOR3: absent advisor_required must not print NOTICE, got: $err" || return 1
  after=$(jq -S 'del(.history, .status, .transition_token)' "$FATQ_ROOT/review/advisor3.json")
  [[ "$before" == "$after" ]] || fail "ADVISOR3: non-history/status fields changed:\nBEFORE=$before\nAFTER=$after" || return 1
  return 0
}

# CLOSEOUT1 — deploy-pipeline happy path：兩證據齊備才 closed，CLI 自填 by/ts，
# 並留下獨立 via 供稽核（--as 仍是既有宣告式身份模型，不假裝是密碼學認證）。
test_CLOSEOUT1() {
  local f="$FATQ_ROOT/done/closeout1.json" rc
  make_task "$f" '{"task_id":"closeout1","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_cli closeout closeout1 --as deploy-pipeline \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":["mvp-server"]}' \
    --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"GET /health 200"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT1 (deploy-pipeline happy path)" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.deploy_evidence.by == "deploy-pipeline"
    and (.closeout.deploy_evidence.ts | type == "string" and length > 0)
    and .closeout.live_check.verified_by == "deploy-pipeline"
    and .history[-1].action == "closeout_update"
    and .history[-1].via == "fatq-cli-closeout"
    and .history[-1].identity_source == "--as (declarative; auditable)"
  ' "$f" >/dev/null || fail "CLOSEOUT1: closeout evidence/history shape invalid" || return 1
  return 0
}

# CLOSEOUT2 — Anya 可記錄原 reviewer 的 reviewer-live 證據。
test_CLOSEOUT2() {
  local f="$FATQ_ROOT/done/closeout2.json" rc
  make_task "$f" '{"task_id":"closeout2","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_cli closeout closeout2 --as anya \
    --deploy-evidence '{"commits":["def456"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"real UI flow passed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT2 (anya + original reviewer-live)" || return 1
  [[ "$(jq -r '.closeout.deploy_evidence.by + "|" + .closeout.live_check.verified_by' "$f")" == "anya|bella" ]] \
    || fail "CLOSEOUT2: by/verified_by mismatch" || return 1
  return 0
}

# CLOSEOUT3 — 非授權身份必須 exit 3，且檔案位元不變。
test_CLOSEOUT3() {
  local f="$FATQ_ROOT/done/closeout3.json" before after rc
  make_task "$f" '{"task_id":"closeout3","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout3 --as anna \
    --deploy-evidence '{"commits":["x"],"services_restarted":[]}' --state pending >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "CLOSEOUT3 (unauthorized identity rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT3: unauthorized call modified task" || return 1
  return 0
}

# CLOSEOUT4 — BLOCKER-2 反面：所有 closeout 路徑都不能走 update-field。
test_CLOSEOUT4() {
  local f="$FATQ_ROOT/done/closeout4.json" field rc before after
  make_task "$f" '{"task_id":"closeout4","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  for field in closeout closeout.state closeout.deploy_evidence closeout.live_check; do
    run_cli update-field closeout4 "$field" --as anya --value '[]' >/dev/null 2>&1; rc=$?
    [[ "$rc" -ne 0 ]] || fail "CLOSEOUT4: update-field unexpectedly accepted $field" || return 1
  done
  after="$(sha256sum "$f" | awk '{print $1}')"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT4: rejected update-field changed task" || return 1
  return 0
}

# CLOSEOUT5 — 證據可分兩次寫；只有第二證據到齊才能 closed，已 closed 不可覆寫。
test_CLOSEOUT5() {
  local f="$FATQ_ROOT/done/closeout5.json" rc
  make_task "$f" '{"task_id":"closeout5","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_cli closeout closeout5 --as deploy-pipeline \
    --deploy-evidence '{"commits":["abc"],"services_restarted":["pod@builder"]}' --state pending >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT5 (deploy evidence pending)" || return 1
  [[ "$(jq -r '.closeout.state' "$f")" == "pending" ]] || fail "CLOSEOUT5: first evidence must stay pending" || return 1
  run_cli closeout closeout5 --as deploy-pipeline \
    --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"probe pass"}' --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT5 (second evidence closes)" || return 1
  run_cli closeout closeout5 --as deploy-pipeline \
    --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"overwrite"}' --state closed >/dev/null 2>&1; rc=$?
  assert_exit 4 "$rc" "CLOSEOUT5 (closed immutable)" || return 1
  return 0
}

# CLOSEOUT6 — schema placement：建單者在 create 時定義 live_verify_commands；
# 新制 task 自帶 pending closeout，後續沒有 update-field 管道可讓 builder 改探針。
test_CLOSEOUT6() {
  local out rc tid f
  out=$(run_cli create --as anya --json --slug closeout-schema --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
    --live_verify_commands '[{"cmd":["curl","-fsS","https://example.invalid/health"],"expect_exit":0}]' 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "CLOSEOUT6 (creator defines live_verify_commands)" || return 1
  tid="$(jq -r '.task_id' <<< "$out")"
  f="$FATQ_ROOT/pending/$tid.json"
  jq -e '
    .closeout == {state:"pending"}
    and (.live_verify_commands | length) == 1
    and .live_verify_commands[0].cmd[0] == "curl"
  ' "$f" >/dev/null || fail "CLOSEOUT6: create schema fields missing" || return 1
  return 0
}

# CLOSEOUT7 — 歷史 done 單沒有 closeout schema，不得藉專用命令偷偷回填。
test_CLOSEOUT7() {
  local f="$FATQ_ROOT/done/closeout7.json" rc
  make_task "$f" '{"task_id":"closeout7","status":"done","reviewer":"bella"}'
  run_cli closeout closeout7 --as anya \
    --deploy-evidence '{"commits":["x"],"services_restarted":[]}' --state pending >/dev/null 2>&1; rc=$?
  assert_exit 4 "$rc" "CLOSEOUT7 (legacy done no backfill)" || return 1
  jq -e 'has("closeout") | not' "$f" >/dev/null || fail "CLOSEOUT7: legacy task was backfilled" || return 1
  return 0
}

# CLOSEOUT8 — 防偽細節：caller 不得在 evidence JSON 自填 by/ts；缺第二證據
# 不得直接 closed；Anya 也不能冒充 auto-probe。
test_CLOSEOUT8() {
  local f="$FATQ_ROOT/done/closeout8.json" rc
  make_task "$f" '{"task_id":"closeout8","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_cli closeout closeout8 --as deploy-pipeline \
    --deploy-evidence '{"commits":["x"],"services_restarted":[],"by":"anya"}' --state pending >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "CLOSEOUT8 (caller cannot inject by)" || return 1
  run_cli closeout closeout8 --as deploy-pipeline \
    --deploy-evidence '{"commits":["x"],"services_restarted":[]}' --state closed >/dev/null 2>&1; rc=$?
  assert_exit 4 "$rc" "CLOSEOUT8 (cannot close with one evidence)" || return 1
  jq -e '.closeout == {state:"pending"}' "$f" >/dev/null || fail "CLOSEOUT8: rejected close persisted partial evidence" || return 1
  run_cli closeout closeout8 --as anya \
    --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"spoof"}' --state pending >/dev/null 2>&1; rc=$?
  assert_exit 3 "$rc" "CLOSEOUT8 (anya cannot impersonate auto-probe)" || return 1
  return 0
}

# CLOSEOUT9 — 空 commits 沒有顯式 N/A 證據時拒絕，避免把「不適用」與
# 「部署證據尚未收齊」混為一談。
test_CLOSEOUT9() {
  local f="$FATQ_ROOT/done/closeout9.json" before after rc
  make_task "$f" '{"task_id":"closeout9","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout9 --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"artifact reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 2 "$rc" "CLOSEOUT9 (empty commits without N/A rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT9: rejected evidence changed task" || return 1
  return 0
}

# CLOSEOUT10 — 純 artifact 可用成對的 not_applicable:true + reason 誠實閉環。
test_CLOSEOUT10() {
  local f="$FATQ_ROOT/done/closeout10.json" rc
  make_task "$f" '{"task_id":"closeout10","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_cli closeout closeout10 --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"spec artifact only; no deployment action"}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"artifact reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT10 (explicit N/A closes)" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.deploy_evidence.commits == []
    and .closeout.deploy_evidence.not_applicable == true
    and .closeout.deploy_evidence.reason == "spec artifact only; no deployment action"
  ' "$f" >/dev/null || fail "CLOSEOUT10: explicit N/A evidence not preserved" || return 1
  return 0
}

# CLOSEOUT11 — 真有 commit 時不得夾帶 N/A 旗標或理由。
test_CLOSEOUT11() {
  local f="$FATQ_ROOT/done/closeout11.json" before after rc
  make_task "$f" '{"task_id":"closeout11","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout11 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[],"not_applicable":true,"reason":"contradiction"}' \
    --state pending >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 2 "$rc" "CLOSEOUT11 (commits and N/A mutually exclusive)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT11: rejected evidence changed task" || return 1
  return 0
}

# CLOSEOUT12 — N/A reason 必須包含非空白內容。
test_CLOSEOUT12() {
  local f="$FATQ_ROOT/done/closeout12.json" before after rc
  make_task "$f" '{"task_id":"closeout12","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout12 --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"   "}' \
    --state pending >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 2 "$rc" "CLOSEOUT12 (blank N/A reason rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT12: rejected evidence changed task" || return 1
  return 0
}

# CLOSEOUT13 — 擴充白名單後仍 fail-closed 拒絕任何其他鍵。
test_CLOSEOUT13() {
  local f="$FATQ_ROOT/done/closeout13.json" before after rc
  make_task "$f" '{"task_id":"closeout13","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout13 --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"design artifact only","extra":true}' \
    --state pending >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 2 "$rc" "CLOSEOUT13 (unknown deploy evidence key rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT13: rejected evidence changed task" || return 1
  return 0
}

# CLOSEOUT14 — closed gate 也必須獨立擋住既存的舊式空 commits；不能只靠
# 新寫入時的 schema guard，否則歷史 pending 證據仍可被補 live_check 後誤關閉。
test_CLOSEOUT14() {
  local f="$FATQ_ROOT/done/closeout14.json" before after rc
  make_task "$f" '{"task_id":"closeout14","status":"done","reviewer":"bella","closeout":{"state":"pending","deploy_evidence":{"commits":[],"services_restarted":[],"by":"anya","ts":"2026-07-20T00:00:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout14 --as anya \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"artifact reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "CLOSEOUT14 (closed gate rejects legacy ambiguous empty commits)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT14: rejected close changed task" || return 1
  return 0
}

# BACKFILL1 — reviewer repair follows creator affinity and repeated repair is mutation-idempotent.
test_BACKFILL1() {
  local f="$FATQ_ROOT/in_progress/backfill1.json" out rc before after
  make_task "$f" '{"task_id":"backfill1","status":"in_progress","assigned":"anna","created_by":"anya","goal":"normal task","context":"c","deliverables":["d"]}'
  out=$(run_cli update-field backfill1 reviewer --as anya --json --value '"bella"' 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "BACKFILL1 first repair" || return 1
  [[ "$(jq -r '.reviewer' "$f")" == "bella" ]] || fail "BACKFILL1: reviewer not materialized" || return 1
  [[ "$(jq -r '[.history[] | select(.action=="update_field" and .field=="reviewer" and .via=="fatq-cli")] | length' "$f")" == "1" ]] || fail "BACKFILL1: audit history missing" || return 1
  [[ "$(jq -r '.history_appended' <<< "$out")" == "true" ]] || fail "BACKFILL1: first repair should append audit history" || return 1
  before="$(sha256sum "$f" | awk '{print $1}')"
  out=$(run_cli update-field backfill1 reviewer --as anya --json --value '"bella"' 2>/dev/null); rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "BACKFILL1 repeated repair is rejected" || return 1
  [[ "$before" == "$after" ]] || fail "BACKFILL1: idempotent rerun changed file" || return 1
  [[ "$(jq -r '.ok' <<< "$out")" == "false" ]] || fail "BACKFILL1: rerun should report rejection" || return 1
  return 0
}

# BACKFILL2 — arbitrary reviewer cannot bypass affinity.
test_BACKFILL2() {
  local f="$FATQ_ROOT/pending/backfill2.json" rc before after
  make_task "$f" '{"task_id":"backfill2","assigned":"anna","created_by":"anya","goal":"normal","context":"c","deliverables":["d"]}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli update-field backfill2 reviewer --as anya --value '"yitang"' >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "BACKFILL2 wrong affinity" || return 1
  [[ "$before" == "$after" ]] || fail "BACKFILL2: rejected repair changed file" || return 1
  return 0
}

# BACKFILL3 — non-infra business line uses its configured reviewer.
test_BACKFILL3() {
  local f="$FATQ_ROOT/pending/backfill3.json" rc
  make_task "$f" '{"task_id":"backfill3","assigned":"sancai","created_by":"caijie-zhuchu","goal":"normal","context":"c","deliverables":["d"]}'
  run_cli update-field backfill3 reviewer --as caijie-zhuchu --value '"yitang"' >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "BACKFILL3 business affinity" || return 1
  [[ "$(jq -r '.reviewer' "$f")" == "yitang" ]] || fail "BACKFILL3: affinity reviewer wrong" || return 1
  return 0
}

# BACKFILL4 — infra repair remains mechanically forced to Bella.
test_BACKFILL4() {
  local f="$FATQ_ROOT/pending/backfill4.json" rc
  make_task "$f" '{"task_id":"backfill4","assigned":"sancai","created_by":"caijie-zhuchu","goal":"modify shared/ dispatch","context":"shared/bin","deliverables":["shared/bin/x"]}'
  run_cli update-field backfill4 reviewer --as anya --value '"bella"' >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "BACKFILL4 infra reviewer" || return 1
  [[ "$(jq -r '.reviewer' "$f")" == "bella" ]] || fail "BACKFILL4: infra reviewer not Bella" || return 1
  return 0
}

# BACKFILL5 — the repair path must never overwrite a valid explicit assignment.
test_BACKFILL5() {
  local f="$FATQ_ROOT/in_progress/backfill5.json" rc before after
  make_task "$f" '{"task_id":"backfill5","status":"in_progress","assigned":"anna","created_by":"anya","reviewer":"yitang","goal":"normal task","context":"c","deliverables":["d"]}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli update-field backfill5 reviewer --as anya --value '"bella"' >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "BACKFILL5 existing reviewer cannot be reassigned" || return 1
  [[ "$before" == "$after" ]] || fail "BACKFILL5: rejected reassignment changed file" || return 1
  [[ "$(jq -r '.reviewer' "$f")" == "yitang" ]] || fail "BACKFILL5: existing reviewer was overwritten" || return 1
  return 0
}

# DELIVER1 — bot creator defaults deliver_to to its canonical state_dir.
test_DELIVER1() {
  local out tid f
  out=$(run_cli create --as huizhang --json --slug delivery-default --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r 2>/dev/null) || return 1
  tid="$(jq -r '.task_id' <<<"$out")"; f="$FATQ_ROOT/pending/$tid.json"
  [[ "$(jq -r '.created_by + "|" + .deliver_to' "$f")" == "huizhang|huizhang" ]] \
    || fail "DELIVER1: default deliver_to did not follow created_by" || return 1
  return 0
}

# DELIVER2 — explicit target is canonicalized and invalid targets fail before write.
test_DELIVER2() {
  local out tid before after rc
  out=$(run_cli create --as huizhang --json --deliver_to SaNcAi --slug delivery-explicit --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r 2>/dev/null) || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  [[ "$(jq -r '.deliver_to' "$FATQ_ROOT/pending/$tid.json")" == "sancai" ]] \
    || fail "DELIVER2: explicit target was not canonicalized" || return 1
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  run_cli create --as huizhang --deliver_to not-a-bot --slug delivery-invalid --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r >/dev/null 2>&1; rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 2 "$rc" "DELIVER2 invalid target" || return 1
  [[ "$before" == "$after" ]] || fail "DELIVER2: invalid target created a task" || return 1
  return 0
}

# DELIVER3 — creator/Anya can update active tasks; changes are audited and
# normalized same-value writes are byte-for-byte no-ops.
test_DELIVER3() {
  local f="$FATQ_ROOT/in_progress/deliver3.json" before after rc
  make_task "$f" '{"task_id":"deliver3","status":"in_progress","assigned":"anna","created_by":"huizhang","deliver_to":"huizhang"}'
  run_cli update-field deliver3 deliver_to --as huizhang --value '"SaNcAi"' >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "DELIVER3 creator update" || return 1
  jq -e '.deliver_to=="sancai" and .history[-1].field=="deliver_to"
    and .history[-1].from_value=="huizhang" and .history[-1].to_value=="sancai"' "$f" >/dev/null \
    || fail "DELIVER3: route/audit mismatch" || return 1
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli update-field deliver3 deliver_to --as anya --value '"SANCAI"' >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 0 "$rc" "DELIVER3 Anya same-value no-op" || return 1
  [[ "$before" == "$after" ]] || fail "DELIVER3: normalized same-value update changed file" || return 1
  return 0
}

# DELIVER4 — assigned builder cannot redirect unless it is also the creator.
test_DELIVER4() {
  local f="$FATQ_ROOT/in_progress/deliver4.json" before after rc
  make_task "$f" '{"task_id":"deliver4","status":"in_progress","assigned":"anna","created_by":"huizhang","deliver_to":"huizhang"}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli update-field deliver4 deliver_to --as anna --value '"sancai"' >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "DELIVER4 builder denied" || return 1
  [[ "$before" == "$after" ]] || fail "DELIVER4: denied redirect changed file" || return 1
  return 0
}

# DELIVER5 — submitted/completed routes are immutable.
test_DELIVER5() {
  local state f before after rc
  for state in review done; do
    f="$FATQ_ROOT/$state/deliver5-$state.json"
    make_task "$f" "{\"task_id\":\"deliver5-$state\",\"status\":\"$state\",\"created_by\":\"huizhang\",\"deliver_to\":\"huizhang\"}"
    before="$(sha256sum "$f" | awk '{print $1}')"
    run_cli update-field "deliver5-$state" deliver_to --as anya --value '"sancai"' >/dev/null 2>&1; rc=$?
    after="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$rc" -ne 0 && "$before" == "$after" ]] || fail "DELIVER5: $state route was mutable" || return 1
  done
  return 0
}

# TOKENSTAMP — every formerly unstamped history-writing path must leave the
# task clean under validate. Before 1fc4, each successful mutation below left
# transition_token_mismatch; this is the compact regression matrix.
test_TOKENSTAMP() {
  local f validate_out

  f="$FATQ_ROOT/in_progress/token-reassign.json"
  make_task "$f" '{"task_id":"token-reassign","assigned":"anna","status":"in_progress"}'
  run_cli reassign token-reassign --as anya --to sancai >/dev/null || return 1

  f="$FATQ_ROOT/done/token-archive.json"
  make_task "$f" '{"task_id":"token-archive","status":"done"}'
  run_cli archive token-archive --as anya >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-comment.json"
  make_task "$f" '{"task_id":"token-comment","assigned":"anna"}'
  run_cli comment token-comment --as anna --text stamp >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-attach.json"
  make_task "$f" '{"task_id":"token-attach","assigned":"anna"}'
  run_cli attach token-attach --as anna --file token.png --name token.png --mime image/png --size 1 >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-hold.json"
  make_task "$f" '{"task_id":"token-hold","assigned":"anna"}'
  run_cli hold token-hold --as anna --until 2026-08-01T00:00:00+08:00 >/dev/null || return 1

  f="$FATQ_ROOT/in_progress/token-update.json"
  make_task "$f" '{"task_id":"token-update","status":"in_progress","assigned":"anna","created_by":"anya"}'
  run_cli update-field token-update reviewer --as anya --value '"bella"' >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-approval-approve.json"
  make_task "$f" '{"task_id":"token-approval-approve","assigned":"anna"}'
  run_cli approval request token-approval-approve --as anna --domain security --expires 48h --reason stamp >/dev/null || return 1
  run_cli approval approve token-approval-approve --as laotu --evidence tg:stamp >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-approval-reject.json"
  make_task "$f" '{"task_id":"token-approval-reject","assigned":"anna"}'
  run_cli approval request token-approval-reject --as anna --domain security --expires 48h --reason stamp >/dev/null || return 1
  FATQ_MATTERMOST_DISABLE=1 run_cli approval reject token-approval-reject --as laotu --evidence tg:stamp --reason stamp >/dev/null || return 1

  f="$FATQ_ROOT/pending/token-approval-expire.json"
  make_task "$f" '{"task_id":"token-approval-expire","assigned":"anna"}'
  run_cli approval request token-approval-expire --as anna --domain security --expires 2020-01-01T00:00:00+08:00 --reason stamp >/dev/null || return 1
  run_cli approval expire token-approval-expire --as anya >/dev/null || return 1

  validate_out="$(run_cli validate --as anna --json)" || return 1
  [[ "$(jq '[.violations[] | select(.issue == "transition_token_mismatch" and (.task_id | startswith("token-")))] | length' <<<"$validate_out")" == "0" ]] ||
    fail "TOKENSTAMP: history mutation left transition_token_mismatch" || return 1
  return 0
}

for t in P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 SUBMIT_LOCK1 SUBMIT_LOCK2 P13 P14 P15 P16 P17 P18 P19 P20 \
         P21 P22 P23 P24 P25 P26 P27 P28 P29 P30 \
         ARCHIVE1 ARCHIVE2 ARCHIVE3 ARCHIVE4 ARCHIVE5 ARCHIVE6 ARCHIVE7 \
         P31 CREATEVC1 CREATEVC2 CREATEVC3 CREATETITLE1 CREATETITLE2 P32 ESTATE ENOTFOUND CONC1 CLAIM_NOCLOBBER VALIDATE_DUP FIND_TASK_FILE_DUP REDLINE \
         AP1 AP2 AP3 AP4 AP5 AP6 AP7 AP8 AP9 AP10 INFRA1 INFRA2 INFRA3 INFRA4 INFRA5 INFRA6 INFRA7 INFRA8 INFRA9 \
         CREATEAFF1 CREATEAFF2 CREATEAFF3 CREATEAFF4 EXTID1 EXTID2 \
         CLOCK1 CLOCK2 CLOCK3 CLOCK4 CLOCK5 \
         ATTACH1 ATTACH2 ATTACH3 ATTACH4 ATTACH5 \
         ENFORCE1 PERMPOOL1 ENFORCE2 ENFORCE3 ENFORCE4 \
         ADVISOR1 ADVISOR2 ADVISOR3 \
         CLOSEOUT1 CLOSEOUT2 CLOSEOUT3 CLOSEOUT4 CLOSEOUT5 CLOSEOUT6 CLOSEOUT7 CLOSEOUT8 \
         CLOSEOUT9 CLOSEOUT10 CLOSEOUT11 CLOSEOUT12 CLOSEOUT13 CLOSEOUT14 \
         BACKFILL1 BACKFILL2 BACKFILL3 BACKFILL4 BACKFILL5 \
         DELIVER1 DELIVER2 DELIVER3 DELIVER4 DELIVER5 TOKENSTAMP; do
  run_test "$t"
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-cli-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail (of $((TOTAL_PASS+TOTAL_FAIL)))"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-cli-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
echo "[fatq-cli-test] All cases passed ✅"
exit 0

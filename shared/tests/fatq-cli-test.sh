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
  unset FATQ_NOW_ISO || true
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending}

  # 再次防呆：即使外層環境沒設，setup() 產生的 FATQ_ROOT 也必須不等於生產路徑
  if [[ "$FATQ_ROOT" == "$PROD_ROOT" ]]; then
    echo "[fatq-cli-test] FATAL: fixture FATQ_ROOT 意外撞到生產路徑" >&2
    exit 2
  fi

  # 固定 fixture team-config：builder={anna,sancai}, reviewer={bella,yitang,ron-reviewer},
  # assistants={anya}, designer={twinkle}。不耦合真實名單，測試不受名單異動影響。
  cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{
  "assistants": [{"state_dir": "anya"}],
  "shared_pools": {
    "builder": [{"state_dir": "anna"}, {"state_dir": "sancai"}],
    "reviewer": [{"state_dir": "bella"}, {"state_dir": "yitang"}, {"state_dir": "ron-reviewer"}],
    "designer": [{"state_dir": "twinkle"}]
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
  for d in pending in_progress review done rejected cancelled wont_do; do
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
  local rc
  run_cli submit t11 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 5 "$rc" "P11 (verify gate fails)" || return 1
  [[ "$(state_dir_of t11)" == "in_progress" ]] || fail "P11: task must stay in_progress/" || return 1
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

# ═══════════════════════════════════════════════════════════════════════════
# REDLINE — 轉移後 diff：除預期欄位外零變動（§1.8 C7）
# ═══════════════════════════════════════════════════════════════════════════
test_REDLINE() {
  local f="$FATQ_ROOT/pending/tr1.json"
  make_task "$f" '{"task_id":"tr1","slug":"audit-me","priority":"P2","assigned":"anna"}'
  local before after
  before=$(jq 'del(.history, .status)' "$f")

  run_cli claim tr1 --as anna >/dev/null 2>&1

  local moved="$FATQ_ROOT/in_progress/tr1.json"
  [[ -f "$moved" ]] || fail "REDLINE: task did not move to in_progress/" || return 1
  after=$(jq 'del(.history, .status)' "$moved")
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

for t in P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12 P13 P14 P15 P16 P17 P18 P19 P20 \
         P21 P22 P23 P24 P25 P26 P27 P28 P29 P30 P31 P32 ESTATE ENOTFOUND CONC1 REDLINE; do
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

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
  unset FATQ_NOW_ISO || true
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending}
  mkdir -p "$FATQ_RELAY_DIR"

  # 再次防呆：即使外層環境沒設，setup() 產生的 FATQ_ROOT 也必須不等於生產路徑
  if [[ "$FATQ_ROOT" == "$PROD_ROOT" ]]; then
    echo "[fatq-cli-test] FATAL: fixture FATQ_ROOT 意外撞到生產路徑" >&2
    exit 2
  fi

  # 固定 fixture team-config：builder={anna,sancai}, reviewer={bella,yitang,ron-reviewer},
  # assistants={anya}, designer={twinkle}，external_identities={mac-agent,laotu}
  # （Q5 裁決落地：身份名單改讀此段，不再寫死在 fatq-cli.sh，測試需跟進）。
  # 不耦合真實名單，測試不受名單異動影響。
  cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{
  "assistants": [{"state_dir": "anya"}],
  "shared_pools": {
    "builder": [{"state_dir": "anna"}, {"state_dir": "sancai"}],
    "reviewer": [{"state_dir": "bella"}, {"state_dir": "yitang"}, {"state_dir": "ron-reviewer"}],
    "designer": [{"state_dir": "twinkle"}]
  },
  "external_identities": ["mac-agent", "laotu", "ron-web-identity"]
}
EOF

  # 固定 fixture 公共財偵測表：不讀真實 shared/lib/dispatch-affinity.json，
  # 避免未來該表被 d5c3 擴充後改變本測試的斷言基礎。
  cat > "$FATQ_DISPATCH_AFFINITY" <<'EOF'
{
  "infra_patterns": ["shared/", "crontab", "gateway", "systemd"],
  "lines": {"default": {"builders": ["anna"], "reviewers": ["Bella"]}}
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
  [[ "$(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "bella" ]] || fail "INFRA1: reviewer should be force-overridden to bella, got $(jq -r '.reviewer' "$FATQ_ROOT/pending/${tid}.json")" || return 1

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
         P21 P22 P23 P24 P25 P26 P27 P28 P29 P30 P31 P32 ESTATE ENOTFOUND CONC1 REDLINE \
         AP1 AP2 AP3 AP4 AP5 AP6 AP7 INFRA1 EXTID1 EXTID2; do
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

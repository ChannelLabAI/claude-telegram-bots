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
  export FATQ_BOT_ROUTING="$TMPROOT/bot-routing.yml"
  export FATQ_OVERRIDE_AUDIT="$TMPROOT/override-audit.jsonl"
  export FATQ_TRUST_LEDGER_AUDIT="$TMPROOT/trust-ledger/trust-ledger.audit.jsonl"
  export FATQ_ENFORCEMENT_KILL_SWITCH="$FATQ_ROOT/.fatq-enforcement-off"
  # This legacy matrix asserts the original blocking contracts. Keep it in
  # explicit rollback mode; tierc-phase1.test.sh owns the new default-policy
  # and reversibility coverage.
  export FATQ_G09_BLOCKING=1
  export FATQ_G12_BLOCKING=1
  # AP5 tests approval dispatch, not create provenance. The dedicated dispatch
  # A74-A76 fixtures cover the production-default create gate.
  export FATQ_CREATE_GATE_DISABLED=1
  export FATQ_MATTERMOST_DISABLE=0
  unset FATQ_INFRA_REVIEWER_LOAD_THRESHOLD || true
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

  # Reviewer fallback must come from routing config, with roster ids resolved
  # to runtime directories. Keep this fixture independent from production.
  cat > "$FATQ_BOT_ROUTING" <<'EOF'
bot_roster:
  - id: bella
    directory: bella
    role: reviewer
  - id: yitang
    directory: yitang
    role: reviewer
  - id: ron-reviewer
    directory: ron-reviewer
    role: reviewer
reviewers:
  - id: bella
  - id: yitang
  - id: ron-reviewer
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
  # Existing create fixtures test unrelated contracts. Keep each fixture's
  # no-deploy intent explicit at this adapter boundary; 5b1a's exact argv
  # contract tests use run_cli_exact so the production guard is never masked.
  local sub="${1:-}" arg has_live_contract=0
  if [[ "$sub" == "create" ]]; then
    for arg in "$@"; do
      [[ "$arg" == "--live_verify_commands" || "$arg" == "--no-live-verify" ]] && has_live_contract=1
    done
    if [[ "$has_live_contract" -eq 0 ]]; then
      bash "$CLI_SH" "$@" --no-live-verify "fatq-cli non-deploy test fixture"
      return
    fi
  fi
  bash "$CLI_SH" "$@"
}

# Run a command beneath a real process whose /proc/<pid>/comm is "claude".
# The parent receives the trusted workspace/session at exec time; spoof_workspace
# is exported only by that parent afterwards, so it changes the child CLI env
# without changing the ancestor's /proc/<pid>/environ evidence.
run_with_claude_parent() {
  local workspace="$1" cwd="$2" session_id="$3" spoof_workspace="$4"
  shift 4
  local fake_claude="$TMPROOT/claude"
  if [[ ! -x "$fake_claude" ]]; then
    cp /bin/bash "$fake_claude" || return 1
  fi
  (
    cd "$cwd" || exit 1
    env TELEGRAM_STATE_DIR="$workspace" CLAUDE_CODE_SESSION_ID="$session_id" \
      "$fake_claude" -c '
        spoof="$1"; shift
        if [[ -n "$spoof" ]]; then export TELEGRAM_STATE_DIR="$spoof"; fi
        "$@" &
        child=$!
        wait "$child"
      ' claude-parent "$spoof_workspace" "$@"
  )
}

# Start a command only after a setsid + second fork has orphaned the daemon and
# an init/subreaper has adopted it.  stdout/exit/daemon-parent+adopter are
# returned through files so the test runner does not keep a pipe open to the
# detached process.
run_after_true_detach() {
  local stdout_file="$1" stderr_file="$2" rc_file="$3" ppid_file="$4"
  shift 4
  python3 - "$stdout_file" "$stderr_file" "$rc_file" "$ppid_file" "$@" <<'PY'
import os
import subprocess
import sys
import time

stdout_file, stderr_file, rc_file, ppid_file, *command = sys.argv[1:]
first = os.fork()
if first:
    os.waitpid(first, 0)
    raise SystemExit(0)
os.setsid()
detach_parent_pid = os.getpid()
second = os.fork()
if second:
    os._exit(0)
for _ in range(200):
    if os.getppid() != detach_parent_pid:
        break
    time.sleep(0.01)
with open(ppid_file, "w", encoding="utf-8") as handle:
    handle.write(f"{detach_parent_pid} {os.getppid()}")
with open(stdout_file, "w", encoding="utf-8") as stdout_handle, \
     open(stderr_file, "w", encoding="utf-8") as stderr_handle:
    result = subprocess.run(command, stdout=stdout_handle, stderr=stderr_handle, check=False)
with open(rc_file, "w", encoding="utf-8") as handle:
    handle.write(str(result.returncode))
os._exit(0)
PY
}

run_cli_exact() {
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

# Parse a relay exactly as gateway.ts does: JSON.parse first, then search only
# at the start of text or after a real LF.  This intentionally rejects the two
# literal characters backslash+n, which cannot delimit firstRelayMention().
assert_relay_real_newline_mention() {
  local relay_file="$1" context="$2"
  node - "$relay_file" "$context" <<'JS'
const fs = require("fs");
const [relayFile, context] = process.argv.slice(2);
const relay = JSON.parse(fs.readFileSync(relayFile, "utf8"));
const text = relay.text;
const mention = /(?:^|\n)\s*@([A-Za-z0-9_]+)/.exec(text)?.[1];
if (!text.includes("\n")) {
  console.error(`${context}: parsed text has no 0x0A newline`);
  process.exit(1);
}
if (text.includes("\\n")) {
  console.error(`${context}: parsed text still contains literal backslash+n`);
  process.exit(1);
}
if (mention !== "Anyachl_bot") {
  console.error(`${context}: firstRelayMention expected Anyachl_bot, got ${mention}`);
  process.exit(1);
}
JS
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

test_SUBMIT_HOLD1() {
  local f="$FATQ_ROOT/in_progress/submit-hold1.json"
  make_task "$f" '{"task_id":"submit-hold1","assigned":"anna","status":"in_progress","not_before":"2030-08-01T00:00:00+08:00"}'
  export FATQ_NOW_ISO="2030-07-31T23:00:00+08:00"
  local rc err_file="$TMPROOT/submit-hold1.stderr"
  run_cli submit submit-hold1 --as anna >/dev/null 2>"$err_file"; rc=$?
  assert_exit 4 "$rc" "SUBMIT_HOLD1 (active hold rejects submit)" || return 1
  [[ "$(state_dir_of submit-hold1)" == "in_progress" ]] ||
    fail "SUBMIT_HOLD1: blocked task must remain in_progress/" || return 1
  grep -Fq "只有 fatq-cli hold/not_before 是機器阻斷" "$err_file" ||
    fail "SUBMIT_HOLD1: error must explain the sole machine-blocking mechanism" || return 1
  jq -e '([.history[] | select(.action=="submit_blocked" and .reason=="hold:not_before")] | length)==1' "$f" >/dev/null ||
    fail "SUBMIT_HOLD1: rejected attempt must leave durable history evidence" || return 1
  local validate_out
  validate_out="$(run_cli validate --as anna --json)"
  [[ "$(jq '[.violations[] | select(.issue=="transition_token_mismatch" and .task_id=="submit-hold1")] | length' <<<"$validate_out")" == "0" ]] ||
    fail "SUBMIT_HOLD1: blocked-attempt history left a stale transition_token" || return 1
  return 0
}

test_SUBMIT_HOLD2() {
  local f="$FATQ_ROOT/in_progress/submit-hold2.json"
  make_task "$f" '{"task_id":"submit-hold2","assigned":"anna","status":"in_progress","not_before":"2030-07-31T22:00:00+08:00"}'
  export FATQ_NOW_ISO="2030-07-31T23:00:00+08:00"
  run_cli submit submit-hold2 --as anna >/dev/null 2>&1 ||
    fail "SUBMIT_HOLD2: expired hold must not block submit" || return 1
  [[ "$(state_dir_of submit-hold2)" == "review" ]] ||
    fail "SUBMIT_HOLD2: expired hold should allow review transition" || return 1
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
  assert_exit 0 "$rc" "P11 (submit defers verify to reviewer)" || return 1
  [[ "$(state_dir_of t11)" == "review" ]] || fail "P11: task must move to review/" || return 1
  run_cli verdict approve t11 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 5 "$rc" "P11: reviewer verify must still block approval" || return 1
  [[ "$(state_dir_of t11)" == "review" ]] || fail "P11: failed reviewer verify must retain review/" || return 1
  return 0
}

test_SUBMIT_DEFER1() {
  local f="$FATQ_ROOT/in_progress/submit-defer1.json"
  # Keep the verifier duration beyond a generous CLI hard timeout. This tests
  # that submit defers verification; it does not impose a sub-second SLA.
  make_task "$f" '{"task_id":"submit-defer1","assigned":"anna","status":"in_progress","verify_commands":[{"cmd":["bash","-c","sleep 10"],"expect_exit":0,"desc":"simulated long suite"}]}'
  local rc
  timeout 5 bash "$CLI_SH" submit submit-defer1 --as anna >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "SUBMIT_DEFER1 (long suite does not block submit)" || return 1
  [[ "$(state_dir_of submit-defer1)" == "review" ]] ||
    fail "SUBMIT_DEFER1: task must move to review before reviewer-side verify" || return 1
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

# A failed verifier must expose the real bounded diagnostic output.  The
# command emits more than 8 KiB so the gate must also disclose truncation
# without echoing the full stream.
test_VERIFYDIAG1() {
  local f="$TMPROOT/verify-diag.json" output rc output_bytes
  make_task "$f" '{"task_id":"verify-diag","verify_commands":[{"cmd":["bash","-c","printf VERIFY_DIAG_UNIQUE; printf %020000d 0 | tr 0 X; printf VERIFY_STDERR_UNIQUE >&2; exit 9"],"expect_exit":0,"desc":"bounded failure diagnostic"}]}'
  output="$(bash "$VERIFY_SH" "$f" 2>&1)"; rc=$?
  assert_exit 1 "$rc" "VERIFYDIAG1 (failed verifier remains red)" || return 1
  [[ "$output" == *"VERIFY_DIAG_UNIQUE"* && "$output" == *"VERIFY_STDERR_UNIQUE"* ]] \
    || fail "VERIFYDIAG1: real stdout/stderr diagnostics were not retained" || return 1
  [[ "$output" == *"stdout_truncated=true"* && "$output" == *"stderr_truncated=false"* ]] \
    || fail "VERIFYDIAG1: truncation metadata missing or wrong" || return 1
  output_bytes="$(printf '%s' "$output" | wc -c | tr -d ' ')"
  [[ "$output_bytes" -lt 10000 ]] \
    || fail "VERIFYDIAG1: verifier emitted unbounded output ($output_bytes bytes)" || return 1
  return 0
}

# Regression for a3cc: approve owns the remaining verifier gate. It must not
# hold .locks/<task>.lock while FATQ_VERIFY_SH adds its same-task audit comment.
test_VERDICT_LOCK1() {
  local f="$FATQ_ROOT/review/verdict-lock1.json"
  make_task "$f" '{"task_id":"verdict-lock1","assigned":"anna","reviewer":"bella","status":"review"}'
  export FATQ_VERIFY_SH="$SCRIPT_DIR/fixtures/fatq-submit-reentrant-verify.sh"
  export REENTER_CLI_SH="$CLI_SH"
  export REENTER_TASK_ID="verdict-lock1"
  export REENTER_MODE="comment"
  export REENTER_AS="bella"
  local rc
  timeout 5 bash "$CLI_SH" verdict approve verdict-lock1 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "VERDICT_LOCK1 (same-task verifier re-entry)" || return 1
  [[ "$(state_dir_of verdict-lock1)" == "done" ]] ||
    fail "VERDICT_LOCK1: expected done/" || return 1
  [[ "$(jq '[.history[] | select(.action=="comment" and .text=="verify re-entered the task lock")] | length' "$FATQ_ROOT/done/verdict-lock1.json")" == "1" ]] ||
    fail "VERDICT_LOCK1: verifier comment missing" || return 1
  return 0
}

# The approve commit lock must reject a verifier-side task mutation instead of
# approving a task different from the one whose verifier result was observed.
test_VERDICT_LOCK2() {
  local f="$FATQ_ROOT/review/verdict-lock2.json"
  make_task "$f" '{"task_id":"verdict-lock2","assigned":"anna","reviewer":"bella","status":"review"}'
  export FATQ_VERIFY_SH="$SCRIPT_DIR/fixtures/fatq-submit-reentrant-verify.sh"
  export REENTER_CLI_SH="$CLI_SH"
  export REENTER_TASK_ID="verdict-lock2"
  export REENTER_MODE="mutate"
  export REENTER_AS="bella"
  local rc
  timeout 5 bash "$CLI_SH" verdict approve verdict-lock2 --as bella >/dev/null 2>&1; rc=$?
  assert_exit 6 "$rc" "VERDICT_LOCK2 (mutation invalidates snapshot)" || return 1
  [[ "$(state_dir_of verdict-lock2)" == "review" ]] ||
    fail "VERDICT_LOCK2: changed task must stay in review/" || return 1
  [[ "$(jq -r '.graduated_invariant[0]' "$f")" == "changed-during-verify" ]] ||
    fail "VERDICT_LOCK2: mutation fixture did not run" || return 1
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
# CANCEL — pending/in_progress/review 的管理者作廢路徑
# ═══════════════════════════════════════════════════════════════════════════
test_CANCEL1() {
  local src="$FATQ_ROOT/review/cancel1.json" dst="$FATQ_ROOT/cancelled/cancel1.json"
  local before after output rc
  make_task "$src" '{"task_id":"cancel1","status":"review","assigned":"anna","reviewer":"bella","reject_count":3,"review":{"note":"preserve"},"verdict":{"note":"preserve"}}'
  before="$(jq -c '{reject_count,review,verdict}' "$src")"
  output="$(run_cli cancel cancel1 --as anya --reason '  superseded by corrected task  ' 2>&1)"; rc=$?
  assert_exit 0 "$rc" "CANCEL1 (review -> cancelled)" || return 1
  [[ -f "$dst" && ! -e "$src" ]] || fail "CANCEL1: atomic move to cancelled/ missing" || return 1
  after="$(jq -c '{reject_count,review,verdict}' "$dst")"
  echo "  EVIDENCE CANCEL1_OUTPUT=$output"
  echo "  EVIDENCE CANCEL1_FIELDS_BEFORE=$before"
  echo "  EVIDENCE CANCEL1_FIELDS_AFTER=$after"
  [[ "$before" == "$after" ]] || fail "CANCEL1: reject_count/review/verdict changed" || return 1
  jq -e '
    .status == "cancelled"
    and .history[-1].action == "cancel"
    and .history[-1].by == "anya"
    and .history[-1].from == "review/"
    and .history[-1].to == "cancelled/"
    and .history[-1].reason == "superseded by corrected task"
  ' "$dst" >/dev/null || fail "CANCEL1: audit history incomplete" || return 1
  return 0
}

test_CANCEL2() {
  local f="$FATQ_ROOT/pending/cancel2.json" before after missing blank rc
  make_task "$f" '{"task_id":"cancel2","status":"pending","assigned":"anna"}'
  before="$(sha256sum "$f")"
  missing="$(run_cli cancel cancel2 --as anya 2>&1)"; rc=$?
  assert_exit 2 "$rc" "CANCEL2 (missing reason rejected)" || return 1
  blank="$(run_cli cancel cancel2 --as anya --reason '   ' 2>&1)"; rc=$?
  assert_exit 2 "$rc" "CANCEL2 (blank reason rejected)" || return 1
  after="$(sha256sum "$f")"
  echo "  EVIDENCE CANCEL2_MISSING=$missing"
  echo "  EVIDENCE CANCEL2_BLANK=$blank"
  [[ "$before" == "$after" ]] || fail "CANCEL2: invalid reason mutated task" || return 1
  return 0
}

test_CANCEL3() {
  local denied="$FATQ_ROOT/in_progress/cancel3-denied.json"
  local allowed="$FATQ_ROOT/pending/cancel3-laotu.json" denied_output rc
  make_task "$denied" '{"task_id":"cancel3-denied","status":"in_progress","assigned":"anna"}'
  denied_output="$(run_cli cancel cancel3-denied --as anna --reason no 2>&1)"; rc=$?
  assert_exit 3 "$rc" "CANCEL3 (non-admin rejected)" || return 1
  echo "  EVIDENCE CANCEL3_UNAUTHORIZED=$denied_output"
  [[ -f "$denied" ]] || fail "CANCEL3: unauthorized cancel moved task" || return 1

  make_task "$allowed" '{"task_id":"cancel3-laotu","status":"pending","assigned":"anna"}'
  run_cli cancel cancel3-laotu --as laotu --reason duplicate >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CANCEL3 (laotu allowed)" || return 1
  [[ -f "$FATQ_ROOT/cancelled/cancel3-laotu.json" ]] || fail "CANCEL3: laotu cancel missing" || return 1
  return 0
}

test_CANCEL4() {
  local st f before after rc
  for st in done cancelled wont_do rejected; do
    f="$FATQ_ROOT/$st/cancel4-$st.json"
    make_task "$f" "{\"task_id\":\"cancel4-$st\",\"status\":\"$st\",\"assigned\":\"anna\"}"
    before="$(sha256sum "$f")"
    run_cli cancel "cancel4-$st" --as anya --reason late >/dev/null 2>&1; rc=$?
    assert_exit 4 "$rc" "CANCEL4 ($st terminal rejected)" || return 1
    after="$(sha256sum "$f")"
    [[ "$before" == "$after" ]] || fail "CANCEL4: terminal $st task changed" || return 1
  done
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

# 5b1a create-time contract: omission fails before any queue artifact exists.
test_CREATE_LIVE1() {
  local before after err rc
  before="$(find "$FATQ_ROOT" -mindepth 1 -print | sort)"
  err=$(run_cli_exact create --as anya --slug missing-live --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer bella 2>&1 >/dev/null)
  rc=$?
  after="$(find "$FATQ_ROOT" -mindepth 1 -print | sort)"
  assert_exit 2 "$rc" "CREATE_LIVE1 (missing contract rejected)" || return 1
  [[ "$err" == *"--live_verify_commands"* && "$err" == *"--no-live-verify"* ]] \
    || fail "CREATE_LIVE1: error must explain both paths, got: $err" || return 1
  [[ "$before" == "$after" ]] || fail "CREATE_LIVE1: rejection created queue/lock artifacts" || return 1
  return 0
}

test_CREATE_LIVE2() {
  local out rc tid f
  out=$(run_cli_exact create --as anya --json --slug explicit-opt-out --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer bella \
    --no-live-verify "  documentation only; no deployment  " 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "CREATE_LIVE2 (opt-out accepted)" || return 1
  tid="$(jq -r '.task_id' <<< "$out")"; f="$FATQ_ROOT/pending/$tid.json"
  jq -e '
    .live_verify_commands == []
    and .closeout.host_effect_policy == "required_for_commits"
    and .closeout.live_verify_opt_out.reason == "documentation only; no deployment"
    and .closeout.live_verify_opt_out.by == "anya"
    and (.closeout.live_verify_opt_out.ts | test("T"))
  ' "$f" >/dev/null || fail "CREATE_LIVE2: opt-out audit missing or untrimmed" || return 1
  return 0
}

test_CREATE_LIVE3() {
  local out rc tid
  out=$(run_cli_exact create --as anya --json --slug explicit-probe --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer bella \
    --live_verify_commands '[{"cmd":["true"],"expect_exit":0}]' 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "CREATE_LIVE3 (probe accepted)" || return 1
  tid="$(jq -r '.task_id' <<< "$out")"
  jq -e '(.live_verify_commands | length) == 1 and (.closeout | has("live_verify_opt_out") | not)' \
    "$FATQ_ROOT/pending/$tid.json" >/dev/null || fail "CREATE_LIVE3: probe path serialized incorrectly" || return 1
  return 0
}

test_CREATE_LIVE4() {
  local rc count_before count_after
  count_before="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  run_cli_exact create --as anya --slug both-live-paths --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --assigned anna --reviewer bella \
    --live_verify_commands '[{"cmd":["true"]}]' --no-live-verify nope >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "CREATE_LIVE4 (mutual exclusion)" || return 1
  run_cli_exact create --as anya --slug blank-opt-out --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --assigned anna --reviewer bella --no-live-verify '   ' >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "CREATE_LIVE4 (blank opt-out reason)" || return 1
  count_after="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  [[ "$count_before" == "$count_after" ]] || fail "CREATE_LIVE4: rejected creates wrote task files" || return 1
  return 0
}

test_SETLIVE1() {
  local f="$FATQ_ROOT/done/setlive1.json" rc
  make_task "$f" '{"task_id":"setlive1","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","live_verify_opt_out":{"reason":"docs only","by":"anya","ts":"2026-08-01T00:00:00+08:00"}}}'
  run_cli set-live-verify setlive1 --as anya --value '[{"cmd":["true"],"expect_exit":0}]' \
    --reason "  deployment became necessary  " >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "SETLIVE1 (anya backfill)" || return 1
  jq -e '
    (.live_verify_commands | length) == 1
    and .closeout.live_verify_opt_out.reason == "docs only"
    and .closeout.live_verify_backfill.reason == "deployment became necessary"
    and .history[-1].action == "set_live_verify"
    and .history[-1].by == "anya"
  ' "$f" >/dev/null || fail "SETLIVE1: write-once audit trail incorrect" || return 1
  return 0
}

test_SETLIVE2() {
  local f="$FATQ_ROOT/in_progress/setlive2.json" before after rc
  make_task "$f" '{"task_id":"setlive2","status":"in_progress","assigned":"anna","created_by":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  run_cli set-live-verify setlive2 --as anna --value '[{"cmd":["true"]}]' --reason late >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 3 "$rc" "SETLIVE2 (assigned creator rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "SETLIVE2: rejected assigned call mutated task" || return 1
  return 0
}

test_SETLIVE3() {
  local f="$FATQ_ROOT/review/setlive3.json" output rc
  make_task "$f" '{"task_id":"setlive3","status":"review","assigned":"anna","created_by":"caijie-zhuchu","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  run_cli set-live-verify setlive3 --as caijie-zhuchu --value '[{"cmd":["true"]}]' --reason late >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "SETLIVE3 (non-assigned creator allowed)" || return 1
  output="$(run_cli set-live-verify setlive3 --as anya --value '[{"cmd":["printf","corrected"]}]' --reason 'wrong service manager' 2>&1)"; rc=$?
  assert_exit 0 "$rc" "SETLIVE3 (existing probe editable)" || return 1
  jq -e '
    .live_verify_commands == [{"cmd":["printf","corrected"]}]
    and .history[-1].action == "set_live_verify"
    and .history[-1].by == "anya"
    and .history[-1].reason == "wrong service manager"
    and .history[-1].old_value == [{"cmd":["true"]}]
    and .history[-1].new_value == [{"cmd":["printf","corrected"]}]
  ' "$f" >/dev/null || fail "SETLIVE3: overwrite or old/new audit trail incorrect" || return 1
  echo "  EVIDENCE SETLIVE3_OUTPUT=$output"
  echo "  EVIDENCE SETLIVE3_HISTORY=$(jq -c '.history[-1]' "$f")"
  return 0
}

test_SETLIVE4() {
  local f="$FATQ_ROOT/done/setlive4.json" before after output rc
  make_task "$f" '{"task_id":"setlive4","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[{"cmd":["true"]}],"closeout":{"state":"closed","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  output="$(run_cli set-live-verify setlive4 --as anya --value '[{"cmd":["printf","new"]}]' --reason correction 2>&1 >/dev/null)"; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 4 "$rc" "SETLIVE4 (closed immutable)" || return 1
  [[ "$output" == *"closeout 已 closed"* ]] || fail "SETLIVE4: closed diagnostic missing: $output" || return 1
  echo "  EVIDENCE SETLIVE4_CLOSED_REJECT=$output"
  [[ "$before" == "$after" ]] || fail "SETLIVE4: closed task changed" || return 1
  return 0
}

# 744e Gate A — replay the three production-path incidents verbatim.  Rejected
# creates must leave no task artifact and the error must provide both repairs.
test_VERIFYFIELD_A1() {
  local sample err rc before after
  local samples=(
    '[{"cmd":["bash","-c","cd /home/oldrabbit/.claude-bots && bash shared/scripts/signal-registry-conflict-gate.sh"],"expect_exit":0}]'
    '[{"cmd":["bash","-c","cd /home/oldrabbit/.claude-bots && python3 shared/scripts/clsc-line-lint.py seabed/chats.clsc.md"],"expect_exit":0}]'
    '[{"cmd":["bash","-c","cd /home/oldrabbit/.claude-bots/mvp && bun build mvp-server.ts --target=bun --outfile=/tmp/mvp-drawer-build.js >/dev/null 2>&1"],"expect_exit":0},{"cmd":["grep","-q","k-tree-drawer","/home/oldrabbit/.claude-bots/mvp/app.html"],"expect_exit":0}]'
  )
  before="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  for sample in "${samples[@]}"; do
    err=$(run_cli_exact create --as anya --slug gate-a-replay --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --verify_commands "$sample" \
      --live_verify_commands '[{"cmd":["true"],"expect_exit":0}]' 2>&1 >/dev/null); rc=$?
    assert_exit 2 "$rc" "VERIFYFIELD_A1 production path" || return 1
    [[ "$err" == *"Gate A"* && "$err" == *'git rev-parse --show-toplevel'* && "$err" == *"--live_verify_commands"* ]] \
      || fail "VERIFYFIELD_A1: error is not actionable: $err" || return 1
  done
  after="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  [[ "$before" == "$after" ]] || fail "VERIFYFIELD_A1: rejected create wrote a task" || return 1
  return 0
}

# Gate A covers every named production-target family while allowing the
# worktree-relative form and a production path used only as a grep literal.
test_VERIFYFIELD_A2() {
  local sample rc out tid
  local samples=(
    '[{"cmd":["test","-f","/usr/local/lib/python3.11/site-packages/pkg.py"]}]'
    '[{"cmd":["test","-f","/etc/systemd/system/mvp.service"]}]'
    '[{"cmd":["test","-d","/opt/mvp"]}]'
    '[{"cmd":["curl","-fsS","http://127.0.0.1:8090/health"]}]'
  )
  for sample in "${samples[@]}"; do
    run_cli_exact create --as anya --slug gate-a-family --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --verify_commands "$sample" \
      --live_verify_commands '[{"cmd":["true"]}]' >/dev/null 2>&1; rc=$?
    assert_exit 2 "$rc" "VERIFYFIELD_A2 production family" || return 1
  done
  out=$(run_cli_exact create --as anya --json --slug gate-a-good --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --assigned anna --reviewer bella \
    --verify_commands '[{"cmd":["bash","-c","cd \"$(git rev-parse --show-toplevel)\" && bash shared/tests/fatq-cli-test.sh"],"expect_exit":0}]' \
    --live_verify_commands '[{"cmd":["bash","-c","printf x | grep -F \"/home/oldrabbit/.claude-bots/\""],"expect_exit":1}]' 2>/dev/null); rc=$?
  assert_exit 0 "$rc" "VERIFYFIELD_A2 worktree form" || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  [[ -f "$FATQ_ROOT/pending/$tid.json" ]] || fail "VERIFYFIELD_A2: valid task missing" || return 1
  return 0
}

test_VERIFYFIELD_B1() {
  local both err rc
  both='[{"cmd":["bash","-c","cd \"$(git rev-parse --show-toplevel)\" && bash shared/tests/fatq-cli-test.sh"],"expect_exit":0}]'
  err=$(run_cli_exact create --as anya --slug gate-b --goal g --background b --context c \
    --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
    --review_focus r --assigned anna --reviewer bella --verify_commands "$both" \
    --live_verify_commands "$both" 2>&1 >/dev/null); rc=$?
  assert_exit 2 "$rc" "VERIFYFIELD_B1 identical fields" || return 1
  [[ "$err" == *"Gate B"* && "$err" == *"builder worktree"* && "$err" == *"host-apply"* && "$err" == *"curl"* ]] \
    || fail "VERIFYFIELD_B1: error is not actionable: $err" || return 1
  return 0
}

test_VERIFYFIELD_C1() {
  local f="$FATQ_ROOT/done/gate-c-fail.json" err rc before after
  make_task "$f" '{"task_id":"gate-c-fail","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  err=$(run_cli set-live-verify gate-c-fail --as anya \
    --value '[{"cmd":["bash","-c","cd /home/oldrabbit/.claude-bots && grep -q \"does not block the normal review transition\" shared/blocks/block-codex-builder-delivery-discipline.md"],"expect_exit":99,"desc":"9891 replay forced red"}]' \
    --reason replay 2>&1 >/dev/null); rc=$?
  after="$(sha256sum "$f")"
  assert_exit 5 "$rc" "VERIFYFIELD_C1 failing probe" || return 1
  [[ "$before" == "$after" && "$(jq '.live_verify_commands | length' "$f")" == "0" ]] \
    || fail "VERIFYFIELD_C1: failed probe consumed write-once state" || return 1
  [[ "$err" == *"Gate C"* && "$err" == *"exit 0 != expected 99"* && "$err" == *"live_verify_commands 尚未寫入"* ]] \
    || fail "VERIFYFIELD_C1: verifier detail/action missing: $err" || return 1
  return 0
}

test_VERIFYFIELD_C2() {
  local f="$FATQ_ROOT/done/gate-c-pass.json" rc
  make_task "$f" '{"task_id":"gate-c-pass","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  run_cli set-live-verify gate-c-pass --as anya --value '[{"cmd":["true"],"expect_exit":0,"desc":"pure passing probe"}]' \
    --reason pass >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "VERIFYFIELD_C2 passing probe" || return 1
  [[ "$(jq -r '.live_verify_commands[0].cmd[0]' "$f")" == "true" ]] \
    || fail "VERIFYFIELD_C2: passing probe was not written" || return 1
  return 0
}

test_VERIFYFIELD_D1() {
  local sample err rc before after
  local samples=(
    '[{"cmd":["bash","-c","cd /home/oldrabbit/.claude-bots/shared/memocean-mcp && bash ops/deploy.sh >/dev/null 2>&1 && bash ops/check-deploy-drift.sh"]}]'
    '[{"cmd":["systemctl","restart","mvp-server"]}]'
    '[{"cmd":["pip3","install","pkg"]}]'
    '[{"cmd":["git","push","origin","main"]}]'
    '[{"cmd":["bash","ops/host-apply.sh"]}]'
  )
  before="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  for sample in "${samples[@]}"; do
    err=$(run_cli_exact create --as anya --slug gate-d --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --live_verify_commands "$sample" 2>&1 >/dev/null); rc=$?
    assert_exit 2 "$rc" "VERIFYFIELD_D1 mutating live probe" || return 1
    [[ "$err" == *"Gate D"* && "$err" == *"只能觀測"* && "$err" == *"curl"* ]] \
      || fail "VERIFYFIELD_D1: error is not actionable: $err" || return 1
  done
  after="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  [[ "$before" == "$after" ]] || fail "VERIFYFIELD_D1: rejected create wrote a task" || return 1
  return 0
}

test_VERIFYFIELD_D2() {
  local f="$FATQ_ROOT/done/gate-d-set.json" before after rc
  make_task "$f" '{"task_id":"gate-d-set","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  run_cli set-live-verify gate-d-set --as anya --value '[{"cmd":["bash","-c","systemctl restart mvp-server"]}]' \
    --reason no >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 2 "$rc" "VERIFYFIELD_D2 set-live mutation" || return 1
  [[ "$before" == "$after" ]] || fail "VERIFYFIELD_D2: rejected probe changed task" || return 1
  return 0
}

# Gate D must recognize normal shell prefixes before Gate C gets a chance to
# execute the probe.  These are regression cases from Bella's R1 review.
test_VERIFYFIELD_D3() {
  local sample rc before after
  local samples=(
    '[{"cmd":["bash","-c"," bash ops/deploy.sh"]}]'
    '[{"cmd":["bash","-c","MEMOCEAN_PIP_BREAK_SYSTEM_PACKAGES=1 bash ops/deploy.sh"]}]'
    '[{"cmd":["bash","-c","cd /tmp && VAR=1 bash ops/deploy.sh"]}]'
    '[{"cmd":["bash","-c","sudo VAR=1 bash ops/deploy.sh"]}]'
    '[{"cmd":["bash","-c","VAR=1 systemctl restart mvp-server"]}]'
    '[{"cmd":["bash","-c","VAR=1 pip3 install pkg"]}]'
    '[{"cmd":["bash","-c","VAR=1 git push origin main"]}]'
    '[{"cmd":["bash","-c","env FOO=1 bash ops/deploy.sh"]}]'
    '[{"cmd":["bash","-c","env FOO=1 systemctl restart mvp-server"]}]'
    '[{"cmd":["bash","-c","env FOO=1 pip install requests"]}]'
    '[{"cmd":["bash","-c","env FOO=1 git push origin main"]}]'
    '[{"cmd":["bash","-c","sudo env FOO=1 bash ops/deploy.sh"]}]'
  )
  before="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  for sample in "${samples[@]}"; do
    run_cli_exact create --as anya --slug gate-d-prefix --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --live_verify_commands "$sample" \
      >/dev/null 2>&1; rc=$?
    assert_exit 2 "$rc" "VERIFYFIELD_D3 prefixed mutation" || return 1
  done
  after="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  [[ "$before" == "$after" ]] || fail "VERIFYFIELD_D3: rejected create wrote a task" || return 1
  return 0
}

# A rejected prefixed deploy must leave neither a canary nor a field write.
# This proves Gate D rejects before Gate C invokes fatq-verify.sh.
test_VERIFYFIELD_D4() {
  local f="$FATQ_ROOT/done/gate-d-canary.json" deploy="$TMPROOT/ops/deploy.sh"
  local canary="$TMPROOT/gate-d-canary" before after rc
  mkdir -p "$(dirname "$deploy")"
  cat > "$deploy" <<EOF
#!/usr/bin/env bash
touch "$canary"
EOF
  chmod +x "$deploy"
  make_task "$f" '{"task_id":"gate-d-canary","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  run_cli set-live-verify gate-d-canary --as anya \
    --value "[{\"cmd\":[\"bash\",\"-c\",\" VAR=1 bash $deploy\"]}]" \
    --reason no >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 2 "$rc" "VERIFYFIELD_D4 reject before execute" || return 1
  [[ ! -e "$canary" ]] || fail "VERIFYFIELD_D4: Gate C executed rejected mutator" || return 1
  [[ "$before" == "$after" && "$(jq '.live_verify_commands | length' "$f")" == "0" ]] \
    || fail "VERIFYFIELD_D4: rejected probe changed task" || return 1
  return 0
}

# The env-prefix variant must also be rejected before Gate C can execute it.
test_VERIFYFIELD_D6() {
  local f="$FATQ_ROOT/done/gate-d-env-canary.json" deploy="$TMPROOT/env-ops/deploy.sh"
  local canary="$TMPROOT/gate-d-env-canary" before after rc
  mkdir -p "$(dirname "$deploy")"
  cat > "$deploy" <<EOF
#!/usr/bin/env bash
touch "$canary"
EOF
  chmod +x "$deploy"
  make_task "$f" '{"task_id":"gate-d-env-canary","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  run_cli set-live-verify gate-d-env-canary --as anya \
    --value "[{\"cmd\":[\"bash\",\"-c\",\"env FOO=1 bash $deploy\"]}]" \
    --reason no >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 2 "$rc" "VERIFYFIELD_D6 env reject before execute" || return 1
  [[ ! -e "$canary" ]] || fail "VERIFYFIELD_D6: Gate C executed env-prefixed mutator" || return 1
  [[ "$before" == "$after" && "$(jq '.live_verify_commands | length' "$f")" == "0" ]] \
    || fail "VERIFYFIELD_D6: rejected env-prefixed probe changed task" || return 1
  return 0
}

# Opaque shell constructs fail closed instead of reaching Gate C.  This bounds
# the parser: callers must rewrite complex probes into a direct/simple form.
test_VERIFYFIELD_D7() {
  local shell sample rc before after
  local shells=(
    'bash -c "curl -fsS http://127.0.0.1/health"'
    'echo $(date)'
    'echo `date`'
    $'echo first\necho second'
    $'echo first \\\necho second'
    'nohup bash ops/deploy.sh'
    'timeout 5 bash ops/deploy.sh'
    'nice bash ops/deploy.sh'
    'printf x | xargs bash ops/deploy.sh'
    'command bash ops/deploy.sh'
    'eval bash ops/deploy.sh'
  )
  before="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  for shell in "${shells[@]}"; do
    sample="$(jq -cn --arg shell "$shell" '[{cmd:["bash","-c",$shell]}]')"
    run_cli_exact create --as anya --slug gate-d-fail-closed --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --live_verify_commands "$sample" \
      >/dev/null 2>&1; rc=$?
    assert_exit 2 "$rc" "VERIFYFIELD_D7 unmodeled shell" || return 1
  done
  after="$(find "$FATQ_ROOT/pending" -name '*.json' | wc -l)"
  [[ "$before" == "$after" ]] || fail "VERIFYFIELD_D7: rejected create wrote a task" || return 1

  local f="$FATQ_ROOT/done/gate-d-opaque-canary.json" deploy="$TMPROOT/opaque-ops/deploy.sh"
  local canary="$TMPROOT/gate-d-opaque-canary"
  mkdir -p "$(dirname "$deploy")"
  cat > "$deploy" <<EOF
#!/usr/bin/env bash
touch "$canary"
EOF
  chmod +x "$deploy"
  make_task "$f" '{"task_id":"gate-d-opaque-canary","status":"done","assigned":"anna","created_by":"anya","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f")"
  # Exact shape observed in cancelled production-queue canary 1eca:
  # bash -c "bash -c \"bash /tmp/.../deploy.sh\""
  sample="$(jq -cn --arg shell "bash -c \"bash $deploy\"" '[{cmd:["bash","-c",$shell]}]')"
  run_cli set-live-verify gate-d-opaque-canary --as anya --value "$sample" \
    --reason no >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 2 "$rc" "VERIFYFIELD_D7 opaque reject before execute" || return 1
  [[ ! -e "$canary" ]] || fail "VERIFYFIELD_D7: Gate C executed opaque mutator" || return 1
  [[ "$before" == "$after" && "$(jq '.live_verify_commands | length' "$f")" == "0" ]] \
    || fail "VERIFYFIELD_D7: rejected opaque probe changed task" || return 1
  return 0
}

# Read-only service observation is the intended live-probe shape.  The first
# sample is the exact argv emitted by MVP proposeRegroup in production.
test_VERIFYFIELD_D5() {
  local out rc tid sample
  local samples=(
    '[{"cmd":["systemctl","--user","is-active","--quiet","pod@reviewer"]}]'
    '[{"cmd":["systemctl","--user","is-enabled","pod@reviewer"]}]'
    '[{"cmd":["bash","-c","VAR=1 systemctl --user show pod@reviewer"]}]'
    '[{"cmd":["bash","-c","service mvp-server status"]}]'
  )
  for sample in "${samples[@]}"; do
    out=$(run_cli_exact create --as anya --json --slug gate-d-readonly --goal g --background b --context c \
      --deliverables '["d"]' --acceptance_criteria '["a"]' --out_of_scope '["o"]' \
      --review_focus r --assigned anna --reviewer bella --live_verify_commands "$sample" 2>/dev/null); rc=$?
    assert_exit 0 "$rc" "VERIFYFIELD_D5 readonly service probe" || return 1
    tid=$(jq -r '.task_id' <<<"$out")
    [[ -f "$FATQ_ROOT/pending/$tid.json" ]] || fail "VERIFYFIELD_D5: valid task missing" || return 1
  done
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
  assert_relay_real_newline_mention "$relay_file" "AP8 mapped requester relay" \
    || fail "AP8: real producer relay must route through firstRelayMention" || return 1
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
  assert_relay_real_newline_mention "$relay_file" "AP9 unmapped requester fallback relay" \
    || fail "AP9: real producer relay must route through firstRelayMention" || return 1
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

# INFRA10 — the real create producer must emit LF-delimited mention fallback.
# Explicit Yitang + critical systemd wording forces Bella and writes the relay.
test_INFRA10() {
  local out tid relay_file
  out=$(run_cli create --as anya --slug infra-relay-newline --goal "修 systemd production restart guard" \
    --background b --context "shared/bin/fatq-cli.sh" \
    --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --reviewer yitang --json 2>/dev/null) || return 1
  tid=$(jq -r '.task_id' <<<"$out")
  relay_file=$(grep -l "$tid" "$FATQ_RELAY_DIR"/fatq-infra-gate-rewrite-*.json 2>/dev/null | head -1)
  [[ -n "$relay_file" ]] || fail "INFRA10: real create producer did not write infra-gate relay" || return 1
  [[ "$(jq -r '.recipient' "$relay_file")" == "" ]] \
    || fail "INFRA10: Anya fallback recipient semantics changed" || return 1
  assert_relay_real_newline_mention "$relay_file" "INFRA10 infra-gate relay" \
    || fail "INFRA10: real producer relay must route through firstRelayMention" || return 1
  return 0
}

# INFRA11 — critical gate treats the threshold as maximum capacity, counts only
# runnable pending/in_progress/review tasks, and reroutes through bot-routing.
test_INFRA11() {
  local out rc tid f i
  for i in 1 2 3; do
    make_task "$FATQ_ROOT/pending/infra-load-bella-$i.json" \
      "{\"task_id\":\"infra-load-bella-$i\",\"reviewer\":\"bella\"}"
  done
  make_task "$FATQ_ROOT/pending/infra-load-bella-held.json" \
    '{"task_id":"infra-load-bella-held","reviewer":"bella","not_before":"2999-01-01T00:00:00+08:00"}'

  out=$(FATQ_INFRA_REVIEWER_LOAD_THRESHOLD=2 run_cli create --as anya \
    --slug infra-load-fallback --goal "修 systemd production deploy gate" \
    --background b --context "shared/bin/fatq-cli.sh" \
    --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --reviewer bella --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "INFRA11 overloaded forced target reroutes" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.reviewer' "$f")" == "yitang" ]] \
    || fail "INFRA11: overloaded Bella should reroute to routing-pool Yitang" || return 1
  jq -e 'any(.history[]; .action=="infra_gate_fallback"
    and .forced_target=="bella" and .selected_reviewer=="yitang"
    and .target_active_load==3 and .selected_active_load==0
    and .load_threshold==2 and (.reasons | index("load_threshold")))' "$f" >/dev/null \
    || fail "INFRA11: load fallback history missing; held task may have been counted" || return 1
  echo "  EVIDENCE INFRA11_REVIEWER=$(jq -r '.reviewer' "$f")"
  echo "  EVIDENCE INFRA11_HISTORY=$(jq -c '.history[] | select(.action=="infra_gate_fallback")' "$f")"
  return 0
}

# INFRA12 — a critical forced target may not equal assigned; this closes the
# historical verdict_check_locked deadlock shape even when creator differs.
test_INFRA12() {
  local out rc tid f
  out=$(run_cli create --as anya --slug infra-assigned-fallback \
    --goal "修 systemd deployment guard" --background b \
    --context "shared/bin/fatq-cli.sh" --deliverables '["shared/bin/fatq-cli.sh"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
    --assigned bella --reviewer yitang --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "INFRA12 forced target assigned collision reroutes" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.assigned + "|" + .reviewer' "$f")" == "bella|yitang" ]] \
    || fail "INFRA12: reviewer must differ from assigned after gate fallback" || return 1
  jq -e 'any(.history[]; .action=="infra_gate_fallback"
    and (.reasons | index("assigned_collision")))' "$f" >/dev/null \
    || fail "INFRA12: assigned collision audit missing" || return 1
  return 0
}

# INFRA13 — if routing config offers no independent reviewer below capacity,
# fail closed before creating a task instead of silently enabling self-review.
test_INFRA13() {
  local before after out rc
  make_task "$FATQ_ROOT/review/infra-load-ron-reviewer.json" \
    '{"task_id":"infra-load-ron-reviewer","status":"review","reviewer":"ron-reviewer"}'
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  out=$(FATQ_INFRA_REVIEWER_LOAD_THRESHOLD=1 run_cli create --as bella \
    --slug infra-no-fallback --goal "修 systemd security deploy gate" \
    --background b --context "shared/bin/fatq-cli.sh" \
    --deliverables '["shared/bin/fatq-cli.sh"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --assigned yitang --reviewer yitang 2>&1)
  rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 4 "$rc" "INFRA13 no eligible fallback rejects create" || return 1
  [[ "$out" == *"無非 created_by／非 assigned 且低於門檻的替代 reviewer"* ]] \
    || fail "INFRA13: rejection must explain exhausted routing pool: $out" || return 1
  [[ "$before" == "$after" ]] || fail "INFRA13: rejected create wrote a task" || return 1
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
# CREATESR1-7（3df9）：create 當下禁止 created_by 自審。檢查必須覆蓋
# 明文 reviewer、affinity 預填與 critical infra 強制目標；gate 碰到
# created_by 必須改派獨立 reviewer，不再有 self_review_by_gate 例外。
# ═══════════════════════════════════════════════════════════════════════════

test_CREATESR1() {
  local before after out rc
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  out=$(run_cli create --as anya --slug self-review-explicit --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --reviewer AnYa 2>&1)
  rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 2 "$rc" "CREATESR1 explicit self-review" || return 1
  [[ "$out" == *"改指獨立 reviewer"* ]] \
    || fail "CREATESR1: error must tell the creator to choose an independent reviewer, got: $out" || return 1
  [[ "$before" == "$after" ]] || fail "CREATESR1: rejected create wrote a task" || return 1
  return 0
}

test_CREATESR2() {
  local out rc tid
  out=$(run_cli create --as anya --slug independent-reviewer --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --reviewer yitang --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "CREATESR2 independent reviewer" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  [[ "$(jq -r '.created_by + "|" + .reviewer' "$FATQ_ROOT/pending/${tid}.json")" == "anya|yitang" ]] \
    || fail "CREATESR2: normal reviewer assignment changed" || return 1
  return 0
}

test_CREATESR3() {
  local before after out rc
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  out=$(run_cli create --as bella --slug self-review-affinity --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r 2>&1)
  rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 2 "$rc" "CREATESR3 affinity-prefilled self-review" || return 1
  [[ "$out" == *"改指獨立 reviewer"* ]] \
    || fail "CREATESR3: affinity rejection must be actionable, got: $out" || return 1
  [[ "$before" == "$after" ]] || fail "CREATESR3: rejected affinity create wrote a task" || return 1
  return 0
}

test_CREATESR4() {
  local out rc tid f
  out=$(run_cli create --as anya --slug self-review-infra-rewrite \
    --goal "修 systemd restart security guard" --background b \
    --context "shared/bin/fatq-cli.sh" --deliverables '["shared/bin/fatq-cli.sh"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
    --reviewer anya --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "CREATESR4 critical infra rewrite before self-review gate" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.created_by + "|" + .reviewer' "$f")" == "anya|bella" ]] \
    || fail "CREATESR4: critical infra gate no longer forces Bella" || return 1
  jq -e 'any(.history[]; .action=="infra_gate_rewrite"
    and .original_reviewer=="anya" and .forced_reviewer=="bella")' "$f" >/dev/null \
    || fail "CREATESR4: critical rewrite audit missing" || return 1
  return 0
}

test_CREATESR5() {
  local out rc tid f err
  out=$(run_cli create --as bella --slug self-review-bella-priority \
    --goal "修 systemd security gate" --background b \
    --context "shared/bin/fatq-cli.sh" --deliverables '["shared/bin/fatq-cli.sh"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
    --reviewer yitang --json 2>"$TMPROOT/createsr5.err")
  rc=$?
  assert_exit 0 "$rc" "CREATESR5 critical infra creator collision reroutes" || return 1
  err="$(<"$TMPROOT/createsr5.err")"
  [[ "$err" == *"依 bot-routing.yml 改派 'yitang'"* ]] \
    || fail "CREATESR5: routing fallback NOTICE missing, got: $err" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.created_by + "|" + .reviewer' "$f")" == "bella|yitang" ]] \
    || fail "CREATESR5: critical gate must not leave Bella self-review" || return 1
  jq -e 'any(.history[]; .action=="infra_gate_fallback"
    and .pattern=="shared/" and .forced_target=="bella"
    and .selected_reviewer=="yitang"
    and (.reasons == ["created_by_collision"]))' "$f" >/dev/null \
    || fail "CREATESR5: independent fallback audit entry missing or incomplete" || return 1
  jq -e 'all(.history[]; .action!="self_review_by_gate")' "$f" >/dev/null \
    || fail "CREATESR5: obsolete self-review exception was written" || return 1
  return 0
}

test_CREATESR6() {
  local before after out rc
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  out=$(run_cli create --as bella --slug self-review-bella-non-infra --goal g --background b \
    --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
    --out_of_scope '["o"]' --review_focus r --reviewer bella 2>&1)
  rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 2 "$rc" "CREATESR6 non-infra Bella self-review" || return 1
  [[ "$out" == *"改指獨立 reviewer"* ]] \
    || fail "CREATESR6: rejection must remain actionable, got: $out" || return 1
  [[ "$before" == "$after" ]] || fail "CREATESR6: rejected create wrote a task" || return 1
  return 0
}

test_CREATESR7() {
  local before after out rc tid f
  before="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  out=$(run_cli create --as bella --slug self-review-balanced-infra \
    --goal "修改共用腳本" --background b \
    --context "shared/bin/fatq-cli.sh" --deliverables '["shared/bin/fatq-cli.sh"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r 2>&1)
  rc=$?
  after="$(find "$FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
  assert_exit 2 "$rc" "CREATESR7 balanced non-priority infra self-review" || return 1
  [[ "$out" == *"改指獨立 reviewer"* ]] \
    || fail "CREATESR7: balanced infra rejection must be actionable, got: $out" || return 1
  [[ "$before" == "$after" ]] || fail "CREATESR7: rejected create wrote a task" || return 1

  out=$(run_cli create --as bella --slug self-review-balanced-infra-retry \
    --goal "修改共用腳本" --background b \
    --context "shared/bin/fatq-cli.sh" --deliverables '["shared/bin/fatq-cli.sh"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
    --reviewer yitang --json 2>/dev/null)
  rc=$?
  assert_exit 0 "$rc" "CREATESR7 independent reviewer retry" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/${tid}.json"
  [[ "$(jq -r '.reviewer' "$f")" == "yitang" ]] \
    || fail "CREATESR7: explicit independent reviewer retry changed" || return 1
  jq -e 'all(.history[]; .action!="self_review_by_gate")' "$f" >/dev/null \
    || fail "CREATESR7: non-priority infra must not receive gate exception" || return 1
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
    .closeout == {state:"pending",host_effect_policy:"required_for_commits"}
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
  make_task "$f" '{"task_id":"closeout10","status":"done","reviewer":"bella","closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
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

# CLOSEOUT15 — deployed code is not closed until the creator-owned host probe
# really passes.  The CLI records a compact, machine-auditable proof itself;
# callers cannot hand-write this object.
test_CLOSEOUT15() {
  local f="$FATQ_ROOT/done/closeout15.json" marker="$TMPROOT/host-effect.marker" rc
  printf '%s\n' registered > "$marker"
  make_task "$f" "{\"task_id\":\"closeout15\",\"status\":\"done\",\"reviewer\":\"bella\",\"live_verify_commands\":[{\"cmd\":[\"grep\",\"-qx\",\"registered\",\"$marker\"],\"expect_exit\":0}],\"closeout\":{\"state\":\"pending\",\"host_effect_policy\":\"required_for_commits\"}}"
  run_cli closeout closeout15 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT15 (passing host probe closes)" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.host_effect_proof.field == "live_verify_commands"
    and .closeout.host_effect_proof.result == "pass"
    and .closeout.host_effect_proof.command_count == 1
    and (.closeout.host_effect_proof.output_sha256 | test("^[0-9a-f]{64}$"))
    and .history[-1].wrote_host_effect_proof == true
  ' "$f" >/dev/null || fail "CLOSEOUT15: machine proof missing or invalid" || return 1
  return 0
}

# CLOSEOUT16 — historical Diana/2438 shape: git says deployed, but the host
# registration is absent.  The real command must run and fail closed, with no
# partial closeout evidence persisted.
test_CLOSEOUT16() {
  local f="$FATQ_ROOT/done/closeout16.json" absent="$TMPROOT/missing-host-registration" before after rc
  make_task "$f" "{\"task_id\":\"closeout16\",\"status\":\"done\",\"reviewer\":\"bella\",\"live_verify_commands\":[{\"cmd\":[\"test\",\"-f\",\"$absent\"],\"expect_exit\":0}],\"closeout\":{\"state\":\"pending\",\"host_effect_policy\":\"required_for_commits\"}}"
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout16 --as anya \
    --deploy-evidence '{"commits":["looks-deployed"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"commit exists"}' \
    --state closed >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "CLOSEOUT16 (missing host registration blocked)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT16: failed probe changed task" || return 1
  return 0
}

# CLOSEOUT17 — omission is not a bypass: commit-bearing closeout without a
# creator-defined live probe is rejected.  Spec/design tasks remain covered by
# CLOSEOUT10's existing explicit not_applicable path.
test_CLOSEOUT17() {
  local f="$FATQ_ROOT/done/closeout17.json" before after rc
  make_task "$f" '{"task_id":"closeout17","status":"done","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli closeout closeout17 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"commit only"}' \
    --state closed >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "CLOSEOUT17 (missing creator probe blocked)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT17: rejected omission changed task" || return 1
  return 0
}

# CLOSEOUT18 — mutation self-proof: deleting the single guard call makes the
# focused negative fixture fail (rc != 0), then restoring the candidate leaves
# it byte-identical to the original.
test_CLOSEOUT18() {
  local mutation_test="$SCRIPT_DIR/fatq-closeout-host-effect-mutation-test.sh" rc
  bash "$mutation_test" "$CLI_SH" "$VERIFY_SH" >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT18 (guard mutation is detected and restored)" || return 1
  return 0
}

# CLOSEOUT19 — proof hashes the bytes observed by the probe, not a templated
# verifier summary.  An output-free `true` probe is the recognizable empty hash,
# while a probe that emits host evidence must leave a different digest.
test_CLOSEOUT19() {
  local true_file="$FATQ_ROOT/done/closeout19-true.json"
  local output_file="$FATQ_ROOT/done/closeout19-output.json"
  local true_sha output_sha rc
  make_task "$true_file" '{"task_id":"closeout19-true","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  make_task "$output_file" '{"task_id":"closeout19-output","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["printf","observed-host-state"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'

  run_cli closeout closeout19-true --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT19 (empty-output probe closes with auditable hash)" || return 1
  run_cli closeout closeout19-output --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT19 (output-bearing probe closes)" || return 1

  true_sha="$(jq -r '.closeout.host_effect_proof.output_sha256' "$true_file")"
  output_sha="$(jq -r '.closeout.host_effect_proof.output_sha256' "$output_file")"
  [[ "$true_sha" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] \
    || fail "CLOSEOUT19: output-free probe did not leave empty-output SHA-256" || return 1
  [[ "$output_sha" == "$(printf '%s' 'observed-host-state' | sha256sum | awk '{print $1}')" ]] \
    || fail "CLOSEOUT19: proof did not hash the probe's real stdout" || return 1
  [[ "$true_sha" != "$output_sha" ]] \
    || fail "CLOSEOUT19: vacuous and output-bearing probes produced identical proof" || return 1
  return 0
}

# CLOSEOUT20 — diagnostics retain bounded stdout/stderr independently.  A
# failing probe prints both streams for immediate diagnosis without mutating
# the task; a noisy passing probe stores only 8 KiB per stream and marks both
# samples truncated while hashing the complete observations.
test_CLOSEOUT20() {
  local pass_file="$FATQ_ROOT/done/closeout20-pass.json"
  local fail_file="$FATQ_ROOT/done/closeout20-fail.json"
  local before after output rc expected_sha
  make_task "$pass_file" '{"task_id":"closeout20-pass","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["bash","-c","printf %09000d 0 | tr 0 O; printf %09001d 0 | tr 0 E >&2"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  run_cli closeout closeout20-pass --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT20 (noisy probe closes with bounded diagnostics)" || return 1
  expected_sha="$( { printf %09000d 0 | tr 0 O; printf %09001d 0 | tr 0 E; } | sha256sum | awk '{print $1}')"
  jq -e --arg sha "$expected_sha" '
    .closeout.host_effect_proof.output_sha256 == $sha
    and .closeout.host_effect_proof.sample_limit_bytes_per_stream == 8192
    and (.closeout.host_effect_proof.commands | length) == 1
    and (.closeout.host_effect_proof.commands[0].stdout.sample | length) == 8192
    and (.closeout.host_effect_proof.commands[0].stderr.sample | length) == 8192
    and .closeout.host_effect_proof.commands[0].stdout.bytes == 9000
    and .closeout.host_effect_proof.commands[0].stderr.bytes == 9001
    and .closeout.host_effect_proof.commands[0].stdout.truncated == true
    and .closeout.host_effect_proof.commands[0].stderr.truncated == true
  ' "$pass_file" >/dev/null || fail "CLOSEOUT20: bounded stream evidence is missing or invalid" || return 1

  make_task "$fail_file" '{"task_id":"closeout20-fail","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["bash","-c","printf diagnostic-out; printf diagnostic-err >&2; exit 7"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$fail_file" | awk '{print $1}')"
  output="$(run_cli closeout closeout20-fail --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed 2>&1)"; rc=$?
  after="$(sha256sum "$fail_file" | awk '{print $1}')"
  assert_exit 4 "$rc" "CLOSEOUT20 (failing probe remains fail-closed)" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT20: failed probe changed task" || return 1
  [[ "$output" == *"diagnostic-out"* && "$output" == *"diagnostic-err"* ]] \
    || fail "CLOSEOUT20: failure output did not retain both diagnostic streams" || return 1
  return 0
}

# CLOSEOUT21 — a post-create probe cannot be closed on auto-probe alone.
test_CLOSEOUT21() {
  local f="$FATQ_ROOT/done/closeout21.json" before after rc output
  make_task "$f" '{"task_id":"closeout21","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","live_verify_backfill":{"by":"anya","ts":"2026-08-02T00:00:00+08:00","reason":"late deployment"}}}'
  before="$(sha256sum "$f")"
  output=$(run_cli closeout closeout21 --as deploy-pipeline \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"probe passed"}' \
    --state closed 2>&1); rc=$?
  after="$(sha256sum "$f")"
  assert_exit 4 "$rc" "CLOSEOUT21 (backfill requires reviewer-live)" || return 1
  [[ "$output" == *"reviewer-live"* ]] || fail "CLOSEOUT21: rejection did not explain reviewer-live requirement" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT21: rejected closeout mutated task" || return 1
  return 0
}

test_CLOSEOUT22() {
  local f="$FATQ_ROOT/done/closeout22.json" rc
  make_task "$f" '{"task_id":"closeout22","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","live_verify_backfill":{"by":"anya","ts":"2026-08-02T00:00:00+08:00","reason":"late deployment"}}}'
  run_cli closeout closeout22 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed post-create probe and production result"}' \
    --state closed >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT22 (reviewer-live closes backfilled probe)" || return 1
  jq -e '.closeout.state == "closed" and .closeout.live_check.method == "reviewer-live" and .closeout.host_effect_proof.result == "pass"' \
    "$f" >/dev/null || fail "CLOSEOUT22: reviewer-live closeout evidence incomplete" || return 1
  return 0
}

# CLOSEOUT23 — 無探針但有部署 commit 的歷史單，可用顯式理由誠實記為
# verification=none；不得偽造 live_check 或 host-effect proof。
test_CLOSEOUT23() {
  local f="$FATQ_ROOT/done/closeout23.json" output rc
  make_task "$f" '{"task_id":"closeout23","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  output="$(run_cli closeout closeout23 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --unverified '  task was created without a live probe  ' --state closed 2>&1)"; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT23 (explicit unverified closes no-probe deployment)" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.verification == "none"
    and .closeout.unverified.reason == "task was created without a live probe"
    and .closeout.unverified.by == "anya"
    and (.closeout.unverified.ts | type == "string" and length > 0)
    and (.closeout | has("live_check") | not)
    and (.closeout | has("host_effect_proof") | not)
    and .history[-1].verification == "none"
    and .history[-1].unverified_reason == "task was created without a live probe"
  ' "$f" >/dev/null || fail "CLOSEOUT23: unverified closeout shape incomplete" || return 1
  echo "  EVIDENCE CLOSEOUT23_OUTPUT=$output"
  echo "  EVIDENCE CLOSEOUT23_CLOSEOUT=$(jq -c '.closeout' "$f")"
  return 0
}

test_CLOSEOUT24() {
  local blank="$FATQ_ROOT/done/closeout24-blank.json"
  local no_commit="$FATQ_ROOT/done/closeout24-no-commit.json" before after rc
  make_task "$blank" '{"task_id":"closeout24-blank","status":"done","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$blank")"
  run_cli closeout closeout24-blank --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --unverified '   ' --state closed >/dev/null 2>&1; rc=$?
  assert_exit 2 "$rc" "CLOSEOUT24 (blank unverified reason rejected)" || return 1
  after="$(sha256sum "$blank")"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT24: blank reason changed task" || return 1

  make_task "$no_commit" '{"task_id":"closeout24-no-commit","status":"done","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$no_commit")"
  run_cli closeout closeout24-no-commit --as deploy-pipeline \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"artifact"}' \
    --unverified 'no probe' --state closed >/dev/null 2>&1; rc=$?
  assert_exit 4 "$rc" "CLOSEOUT24 (unverified requires deployed commit)" || return 1
  after="$(sha256sum "$no_commit")"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT24: no-commit rejection changed task" || return 1
  return 0
}

# CLOSEOUT25 — --unverified 不能蓋過非空探針；同一條紅燈探針走一般路徑時
# 仍會真的執行並阻止 closeout。
test_CLOSEOUT25() {
  local bypass="$FATQ_ROOT/done/closeout25-bypass.json"
  local normal="$FATQ_ROOT/done/closeout25-normal.json" before after output rc
  make_task "$bypass" '{"task_id":"closeout25-bypass","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["false"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$bypass")"
  output="$(run_cli closeout closeout25-bypass --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --unverified 'attempted bypass' --state closed 2>&1)"; rc=$?
  after="$(sha256sum "$bypass")"
  assert_exit 4 "$rc" "CLOSEOUT25 (unverified cannot bypass non-empty red probe)" || return 1
  [[ "$output" == *"live_verify_commands 為空"* ]] || fail "CLOSEOUT25: bypass diagnostic missing: $output" || return 1
  echo "  EVIDENCE CLOSEOUT25_BYPASS_REJECT=$output"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT25: bypass rejection changed task" || return 1

  make_task "$normal" '{"task_id":"closeout25-normal","status":"done","reviewer":"bella","live_verify_commands":[{"cmd":["false"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  before="$(sha256sum "$normal")"
  output="$(run_cli closeout closeout25-normal --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed"}' \
    --state closed 2>&1)"; rc=$?
  after="$(sha256sum "$normal")"
  assert_exit 4 "$rc" "CLOSEOUT25 (red probe remains fail-closed)" || return 1
  [[ "$output" == *"主機生效探針失敗"* ]] || fail "CLOSEOUT25: red-probe diagnostic missing: $output" || return 1
  echo "  EVIDENCE CLOSEOUT25_RED_PROBE_REJECT=$(tr '\n' ' ' <<< "$output")"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT25: red probe changed task" || return 1
  return 0
}

# CLOSEOUT26 — reviewer-live 仍以最後 verdict 歷史作者為準，不退回較弱的
# reviewer 欄位。
test_CLOSEOUT26() {
  local f="$FATQ_ROOT/done/closeout26.json" before after output rc
  make_task "$f" '{"task_id":"closeout26","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"},"history":[{"ts":"2026-08-01T00:00:00+08:00","by":"yitang","action":"verdict_approve"}]}'
  before="$(sha256sum "$f")"
  output="$(run_cli closeout closeout26 --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"wrong reviewer"}' \
    --state closed 2>&1)"; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 3 "$rc" "CLOSEOUT26 (verdict author remains authoritative)" || return 1
  [[ "$output" == *"實際審查者是 yitang"* && "$output" == *"來源：verdict 歷史"* ]] \
    || fail "CLOSEOUT26: reviewer attribution diagnostic missing: $output" || return 1
  echo "  EVIDENCE CLOSEOUT26_REVIEWER_REJECT=$output"
  [[ "$before" == "$after" ]] || fail "CLOSEOUT26: attribution rejection changed task" || return 1
  return 0
}

# CLOSEOUT27 — third closed shape: no deployment evidence and no probe. It is
# explicit, auditable, and jq-disjoint from verified and unverified shapes.
test_CLOSEOUT27() {
  local nohost="$FATQ_ROOT/done/closeout27-nohost.json"
  local unverified="$FATQ_ROOT/done/closeout27-unverified.json"
  local verified="$FATQ_ROOT/done/closeout27-verified.json"
  local output rc nohost_count unverified_count verified_count
  make_task "$nohost" '{"task_id":"closeout27-nohost","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  output="$(run_cli closeout closeout27-nohost --as anya \
    --no-host-effect '  research artifact only; no host mutation  ' --state closed 2>&1)"; rc=$?
  assert_exit 0 "$rc" "CLOSEOUT27 no-host-effect closes zero-commit zero-probe task" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.host_effect == "none"
    and .closeout.no_host_effect.reason == "research artifact only; no host mutation"
    and .closeout.no_host_effect.by == "anya"
    and (.closeout.no_host_effect.ts | type == "string" and length > 0)
    and (.closeout | has("deploy_evidence") | not)
    and (.closeout | has("live_check") | not)
    and (.closeout | has("host_effect_proof") | not)
    and (.closeout | has("verification") | not)
    and (.closeout | has("unverified") | not)
    and .history[-1].host_effect == "none"
    and .history[-1].no_host_effect_reason == "research artifact only; no host mutation"
  ' "$nohost" >/dev/null || fail "CLOSEOUT27: no-host-effect closeout/history shape invalid" || return 1

  make_task "$unverified" '{"task_id":"closeout27-unverified","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  run_cli closeout closeout27-unverified --as anya \
    --deploy-evidence '{"commits":["abc123"],"services_restarted":[]}' \
    --unverified 'deployed before probe existed' --state closed >/dev/null 2>&1 || return 1
  make_task "$verified" '{"task_id":"closeout27-verified","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"}}'
  run_cli closeout closeout27-verified --as anya \
    --deploy-evidence '{"commits":["def456"],"services_restarted":[]}' \
    --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"probe reviewed"}' \
    --state closed >/dev/null 2>&1 || return 1

  nohost_count="$(jq -s '[.[] | select(.closeout.state=="closed" and .closeout.host_effect=="none" and (.closeout.no_host_effect|type=="object") and (.closeout|has("verification")|not) and (.closeout|has("live_check")|not))] | length' "$FATQ_ROOT/done/"*.json)"
  unverified_count="$(jq -s '[.[] | select(.closeout.state=="closed" and .closeout.verification=="none" and (.closeout.unverified|type=="object") and ((.closeout.deploy_evidence.commits//[])|length)>0 and (.closeout|has("host_effect")|not) and (.closeout|has("live_check")|not))] | length' "$FATQ_ROOT/done/"*.json)"
  verified_count="$(jq -s '[.[] | select(.closeout.state=="closed" and (.closeout.live_check|type=="object") and (.closeout|has("host_effect")|not) and (.closeout|has("verification")|not) and (.closeout|has("unverified")|not))] | length' "$FATQ_ROOT/done/"*.json)"
  [[ "$nohost_count|$unverified_count|$verified_count" == "1|1|1" ]] \
    || fail "CLOSEOUT27: three closed shapes are not mutually queryable: $nohost_count|$unverified_count|$verified_count" || return 1
  echo "  EVIDENCE CLOSEOUT27_OUTPUT=$output"
  echo "  EVIDENCE CLOSEOUT27_CLOSEOUT=$(jq -c '.closeout' "$nohost")"
  echo '  EVIDENCE CLOSEOUT27_JQ_NOHOST=[.[] | select(.closeout.host_effect=="none" and (.closeout.no_host_effect|type=="object"))] | length => 1'
  echo '  EVIDENCE CLOSEOUT27_JQ_UNVERIFIED=[.[] | select(.closeout.verification=="none" and (.closeout.unverified|type=="object"))] | length => 1'
  echo '  EVIDENCE CLOSEOUT27_JQ_VERIFIED=[.[] | select((.closeout.live_check|type=="object") and (.closeout|has("verification")|not) and (.closeout|has("host_effect")|not))] | length => 1'
  return 0
}

# CLOSEOUT28 — probe presence alone forbids no-host-effect, regardless of
# whether that probe would be green or red. Neither command is executed.
test_CLOSEOUT28() {
  local color f before after output rc command
  for color in green red; do
    [[ "$color" == "green" ]] && command="true" || command="false"
    f="$FATQ_ROOT/done/closeout28-$color.json"
    make_task "$f" "{\"task_id\":\"closeout28-$color\",\"status\":\"done\",\"reviewer\":\"bella\",\"live_verify_commands\":[{\"cmd\":[\"$command\"],\"expect_exit\":0}],\"closeout\":{\"state\":\"pending\",\"host_effect_policy\":\"required_for_commits\"}}"
    before="$(sha256sum "$f")"
    output="$(run_cli closeout "closeout28-$color" --as anya \
      --no-host-effect "attempt $color probe bypass" --state closed 2>&1)"; rc=$?
    after="$(sha256sum "$f")"
    assert_exit 4 "$rc" "CLOSEOUT28 $color probe rejects no-host-effect" || return 1
    [[ "$output" == *"live_verify_commands 為空"* ]] \
      || fail "CLOSEOUT28: $color probe rejection diagnostic missing: $output" || return 1
    [[ "$before" == "$after" ]] || fail "CLOSEOUT28: $color probe rejection mutated task" || return 1
    echo "  EVIDENCE CLOSEOUT28_${color^^}_REJECT=$output"
  done
  return 0
}

# CLOSEOUT29 — existing deployment commits exclude the third shape; evidence is
# write-once and cannot be relabelled as no host effect.
test_CLOSEOUT29() {
  local f="$FATQ_ROOT/done/closeout29.json" before after output rc
  make_task "$f" '{"task_id":"closeout29","status":"done","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-16T00:00:00+08:00"}}}'
  before="$(sha256sum "$f")"
  output="$(run_cli closeout closeout29 --as anya \
    --no-host-effect 'attempt deployed-commit bypass' --state closed 2>&1)"; rc=$?
  after="$(sha256sum "$f")"
  assert_exit 4 "$rc" "CLOSEOUT29 deployed commit rejects no-host-effect" || return 1
  [[ "$output" == *"零部署 commit"* ]] \
    || fail "CLOSEOUT29: deployed-commit diagnostic missing: $output" || return 1
  [[ "$before" == "$after" ]] || fail "CLOSEOUT29: rejection mutated deployment evidence" || return 1
  echo "  EVIDENCE CLOSEOUT29_COMMIT_REJECT=$output"
  return 0
}

# FINALIZE1 — existing write-once evidence is reused byte-for-byte while the
# host-effect gate runs and only closeout.state/audit proof change.
test_FINALIZE1() {
  local f="$FATQ_ROOT/done/finalize1.json" before_evidence after_evidence rc validate_out
  make_task "$f" '{"task_id":"finalize1","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","live_verify_backfill":{"by":"anya","ts":"2026-08-02T00:00:00+08:00","reason":"late deployment"},"deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed production result","ts":"2026-08-02T01:05:00+08:00"}}}'
  before_evidence="$(jq -c '{deploy_evidence:.closeout.deploy_evidence,live_check:.closeout.live_check}' "$f")"
  run_cli finalize-existing finalize1 --as anya >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "FINALIZE1 (pending existing evidence closes)" || return 1
  after_evidence="$(jq -c '{deploy_evidence:.closeout.deploy_evidence,live_check:.closeout.live_check}' "$f")"
  [[ "$before_evidence" == "$after_evidence" ]] \
    || fail "FINALIZE1: write-once evidence changed" || return 1
  jq -e '
    .closeout.state == "closed"
    and .closeout.host_effect_proof.result == "pass"
    and .history[-1].action == "closeout_finalize_existing"
    and .history[-1].via == "fatq-cli-finalize-existing"
    and .history[-1].reused_deploy_evidence == true
    and .history[-1].reused_live_check == true
  ' "$f" >/dev/null || fail "FINALIZE1: state/proof/audit shape invalid" || return 1
  validate_out="$(run_cli validate --as anya --json)" || return 1
  [[ "$(jq '[.violations[] | select(.task_id == "finalize1" and .issue == "transition_token_mismatch")] | length' <<< "$validate_out")" == "0" ]] \
    || fail "FINALIZE1: transition token was not restamped" || return 1
  return 0
}

# FINALIZE2 — both write-once evidence objects are mandatory; either omission
# fails without changing the task.
test_FINALIZE2() {
  local kind f before after output rc closeout
  for kind in deploy live; do
    f="$FATQ_ROOT/done/finalize2-$kind.json"
    if [[ "$kind" == "deploy" ]]; then
      closeout='{"state":"pending","live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed","ts":"2026-08-02T01:05:00+08:00"}}'
    else
      closeout='{"state":"pending","deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"}}'
    fi
    make_task "$f" "{\"task_id\":\"finalize2-$kind\",\"status\":\"done\",\"assigned\":\"anna\",\"reviewer\":\"bella\",\"closeout\":$closeout}"
    before="$(sha256sum "$f" | awk '{print $1}')"
    output="$(run_cli finalize-existing "finalize2-$kind" --as anya 2>&1)"; rc=$?
    after="$(sha256sum "$f" | awk '{print $1}')"
    assert_exit 4 "$rc" "FINALIZE2 (missing $kind evidence rejected)" || return 1
    [[ "$output" == *"$kind"* ]] || fail "FINALIZE2: missing-$kind diagnostic absent: $output" || return 1
    [[ "$before" == "$after" ]] || fail "FINALIZE2: missing-$kind rejection changed task" || return 1
  done
  return 0
}

# FINALIZE3 — closed is immutable and cannot be re-finalized.
test_FINALIZE3() {
  local f="$FATQ_ROOT/done/finalize3.json" before after output rc
  make_task "$f" '{"task_id":"finalize3","status":"done","assigned":"anna","reviewer":"bella","closeout":{"state":"closed","deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed","ts":"2026-08-02T01:05:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  output="$(run_cli finalize-existing finalize3 --as anya 2>&1)"; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "FINALIZE3 (closed re-entry rejected)" || return 1
  [[ "$output" == *"pending"* ]] || fail "FINALIZE3: state diagnostic absent: $output" || return 1
  [[ "$before" == "$after" ]] || fail "FINALIZE3: re-entry changed task" || return 1
  return 0
}

# FINALIZE4 — existing auto-probe evidence cannot bypass the reviewer-live
# requirement when live probes are present.
test_FINALIZE4() {
  local f="$FATQ_ROOT/done/finalize4.json" before after output rc
  make_task "$f" '{"task_id":"finalize4","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[{"cmd":["true"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"deploy-pipeline","method":"auto-probe","evidence":"probe passed","ts":"2026-08-02T01:05:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  output="$(run_cli finalize-existing finalize4 --as deploy-pipeline 2>&1)"; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "FINALIZE4 (reviewer-live bypass rejected)" || return 1
  [[ "$output" == *"reviewer-live"* ]] || fail "FINALIZE4: reviewer-live diagnostic absent: $output" || return 1
  [[ "$before" == "$after" ]] || fail "FINALIZE4: bypass rejection changed task" || return 1
  return 0
}

# FINALIZE5 — authorization is identical to closeout.
test_FINALIZE5() {
  local f="$FATQ_ROOT/done/finalize5.json" before after rc
  make_task "$f" '{"task_id":"finalize5","status":"done","assigned":"anna","reviewer":"bella","closeout":{"state":"pending","deploy_evidence":{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"artifact only","by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed","ts":"2026-08-02T01:05:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  run_cli finalize-existing finalize5 --as anna >/dev/null 2>&1; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 3 "$rc" "FINALIZE5 (unauthorized identity rejected)" || return 1
  [[ "$before" == "$after" ]] || fail "FINALIZE5: unauthorized call changed task" || return 1
  return 0
}

# FINALIZE6 — Gate C must execute; a failing live probe cannot be converted
# into a closed state by reusing old reviewer evidence.
test_FINALIZE6() {
  local f="$FATQ_ROOT/done/finalize6.json" before after output rc
  make_task "$f" '{"task_id":"finalize6","status":"done","assigned":"anna","reviewer":"bella","live_verify_commands":[{"cmd":["false"],"expect_exit":0}],"closeout":{"state":"pending","host_effect_policy":"required_for_commits","deploy_evidence":{"commits":["abc123"],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed","ts":"2026-08-02T01:05:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  output="$(run_cli finalize-existing finalize6 --as anya 2>&1)"; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "FINALIZE6 (failing Gate C rejected)" || return 1
  [[ "$output" == *"主機生效探針失敗"* ]] || fail "FINALIZE6: Gate C diagnostic absent: $output" || return 1
  [[ "$before" == "$after" ]] || fail "FINALIZE6: failing probe changed task" || return 1
  return 0
}

# FINALIZE7 — malformed persisted evidence is not grandfathered into closed.
test_FINALIZE7() {
  local f="$FATQ_ROOT/done/finalize7.json" before after output rc
  make_task "$f" '{"task_id":"finalize7","status":"done","assigned":"anna","reviewer":"bella","closeout":{"state":"pending","deploy_evidence":{"commits":[],"services_restarted":[],"by":"anya","ts":"2026-08-02T01:00:00+08:00"},"live_check":{"verified_by":"bella","method":"reviewer-live","evidence":"reviewed","ts":"2026-08-02T01:05:00+08:00"}}}'
  before="$(sha256sum "$f" | awk '{print $1}')"
  output="$(run_cli finalize-existing finalize7 --as anya 2>&1)"; rc=$?
  after="$(sha256sum "$f" | awk '{print $1}')"
  assert_exit 4 "$rc" "FINALIZE7 (malformed stored evidence rejected)" || return 1
  [[ "$output" == *"格式無效"* ]] || fail "FINALIZE7: evidence diagnostic absent: $output" || return 1
  [[ "$before" == "$after" ]] || fail "FINALIZE7: malformed evidence rejection changed task" || return 1
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

# CALLER1 — a real claude ancestor supplies workspace/cwd/session evidence.
# A child-only TELEGRAM_STATE_DIR override must not replace the ancestor value.
test_CALLER1() {
  local bot_cwd="$TMPROOT/workspaces/anna" out rc tid f
  mkdir -p "$bot_cwd"
  out="$(run_with_claude_parent "/fixture/bots/anna" "$bot_cwd" "session-caller1" "/fixture/bots/bella" \
    bash "$CLI_SH" create --as anna --json --slug caller-normal --goal g --background b \
      --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer bella \
      --no-live-verify fixture 2>"$TMPROOT/caller1.err")"; rc=$?
  assert_exit 0 "$rc" "CALLER1 (normal caller evidence and child env spoof resistance)" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/$tid.json"
  jq -e '.history[0].action == "create"
    and .history[0].caller == {workspace:"anna",cwd_bot:"anna",session_id:"session-caller1",pid_chain_ok:true}
    and (.history[0] | has("identity_mismatch") | not)' "$f" >/dev/null \
    || fail "CALLER1: caller evidence missing, spoofed, or falsely mismatched: $(jq -c '.history[0]' "$f")" || return 1
  echo "  EVIDENCE CALLER1_CHILD_OVERRIDE_REQUESTED=bella"
  echo "  EVIDENCE CALLER1_HISTORY=$(jq -c '.history[0]' "$f")"
  return 0
}

# CALLER2 — caller/--as mismatch is evidence only: create still succeeds.
test_CALLER2() {
  local bot_cwd="$TMPROOT/workspaces/anna" out rc tid f
  mkdir -p "$bot_cwd"
  out="$(run_with_claude_parent "/fixture/bots/anna" "$bot_cwd" "session-caller2" "" \
    bash "$CLI_SH" create --as anya --json --slug caller-mismatch --goal g --background b \
      --context c --deliverables '["d"]' --acceptance_criteria '["a"]' \
      --out_of_scope '["o"]' --review_focus r --assigned anna --reviewer bella \
      --no-live-verify fixture 2>"$TMPROOT/caller2.err")"; rc=$?
  assert_exit 0 "$rc" "CALLER2 (mismatch remains non-blocking)" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/$tid.json"
  jq -e '.history[0].caller.workspace == "anna"
    and .history[0].caller.pid_chain_ok == true
    and .history[0].identity_mismatch == true' "$f" >/dev/null \
    || fail "CALLER2: mismatch evidence missing: $(jq -c '.history[0]' "$f")" || return 1
  echo "  EVIDENCE CALLER2_STDOUT=$out"
  echo "  EVIDENCE CALLER2_EXIT=$rc"
  echo "  EVIDENCE CALLER2_HISTORY=$(jq -c '.history[0]' "$f")"
  return 0
}

# CALLER3 — first reproduce the reject exactly: `setsid -f -w` leaves a parent
# in the old session beneath a real claude process, and the walk must stop at
# that session boundary instead of latching onto claude. Then prove a true
# setsid + double fork is adopted by PID 1 or a subreaper before the same action
# is executed.
# Both missing-provenance paths remain null/false and non-blocking.
test_CALLER3() {
  local bot_cwd="$TMPROOT/workspaces/bella" boundary_out boundary_rc boundary_tid boundary_file
  local out rc tid f detached_out="$TMPROOT/caller3.out" detached_rc="$TMPROOT/caller3.rc"
  local detached_ppid="$TMPROOT/caller3.ppid" detached_parent detached_adopter i
  mkdir -p "$bot_cwd"
  boundary_out="$(run_with_claude_parent "/fixture/bots/bella" "$bot_cwd" "session-caller3" "" \
    setsid -f -w bash "$CLI_SH" create --as anya --json --slug caller-session-boundary \
      --goal g --background b --context c --deliverables '["d"]' \
      --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
      --assigned anna --reviewer bella --no-live-verify fixture \
      2>"$TMPROOT/caller3-boundary.err")"; boundary_rc=$?
  assert_exit 0 "$boundary_rc" "CALLER3 (session-boundary evidence remains non-blocking)" || return 1
  boundary_tid="$(jq -r '.task_id' <<<"$boundary_out")"
  boundary_file="$FATQ_ROOT/pending/$boundary_tid.json"
  jq -e '.history[0].caller == {workspace:null,cwd_bot:null,session_id:null,pid_chain_ok:false}
    and (.history[0] | has("identity_mismatch") | not)' "$boundary_file" >/dev/null \
    || fail "CALLER3: walk crossed session boundary: $(jq -c '.history[0]' "$boundary_file")" || return 1

  run_after_true_detach "$detached_out" "$TMPROOT/caller3.err" "$detached_rc" "$detached_ppid" \
    bash "$CLI_SH" create --as anya --json --slug caller-detached \
      --goal g --background b --context c --deliverables '["d"]' \
      --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus r \
      --assigned anna --reviewer bella --no-live-verify fixture
  for i in $(seq 1 500); do
    [[ -s "$detached_rc" ]] && break
    sleep 0.01
  done
  [[ -s "$detached_rc" ]] || fail "CALLER3: detached command did not finish" || return 1
  rc="$(<"$detached_rc")"
  out="$(<"$detached_out")"
  assert_exit 0 "$rc" "CALLER3 (detached chain remains non-blocking)" || return 1
  read -r detached_parent detached_adopter < "$detached_ppid"
  [[ -n "$detached_parent" && -n "$detached_adopter" && "$detached_adopter" != "$detached_parent" ]] \
    || fail "CALLER3: daemon was not reparented before CLI execution (parent=$detached_parent adopter=$detached_adopter)" || return 1
  tid="$(jq -r '.task_id' <<<"$out")"
  f="$FATQ_ROOT/pending/$tid.json"
  jq -e '.history[0].caller == {workspace:null,cwd_bot:null,session_id:null,pid_chain_ok:false}
    and (.history[0] | has("identity_mismatch") | not)' "$f" >/dev/null \
    || fail "CALLER3: detached evidence must be null/fail-open: $(jq -c '.history[0]' "$f")" || return 1
  echo "  EVIDENCE CALLER3_BOUNDARY_STDOUT=$boundary_out"
  echo "  EVIDENCE CALLER3_BOUNDARY_EXIT=$boundary_rc"
  echo "  EVIDENCE CALLER3_BOUNDARY_HISTORY=$(jq -c '.history[0]' "$boundary_file")"
  echo "  EVIDENCE CALLER3_DETACHED_STDOUT=$out"
  echo "  EVIDENCE CALLER3_DETACHED_EXIT=$rc"
  echo "  EVIDENCE CALLER3_DAEMON_PARENT=$detached_parent"
  echo "  EVIDENCE CALLER3_DAEMON_ADOPTER=$detached_adopter"
  echo "  EVIDENCE CALLER3_HISTORY=$(jq -c '.history[0]' "$f")"
  return 0
}

# CALLER4 — every permanent-audit action receives the same forward-compatible
# caller object: create is covered above; exercise archive/force-mv/closeout.
test_CALLER4() {
  local bot_cwd="$TMPROOT/workspaces/anna" f rc action
  mkdir -p "$bot_cwd"

  f="$FATQ_ROOT/done/caller-archive.json"
  make_task "$f" '{"task_id":"caller-archive","status":"done"}'
  run_with_claude_parent "/fixture/bots/anna" "$bot_cwd" "session-archive" "" \
    bash "$CLI_SH" archive caller-archive --as anya >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CALLER4 archive" || return 1

  f="$FATQ_ROOT/pending/caller-force.json"
  make_task "$f" '{"task_id":"caller-force","status":"pending","assigned":"anna"}'
  run_with_claude_parent "/fixture/bots/anna" "$bot_cwd" "session-force" "" \
    bash "$CLI_SH" force-mv caller-force review --as anya --reason fixture >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CALLER4 force-mv" || return 1

  f="$FATQ_ROOT/done/caller-closeout.json"
  make_task "$f" '{"task_id":"caller-closeout","status":"done","reviewer":"bella","closeout":{"state":"pending"}}'
  run_with_claude_parent "/fixture/bots/anna" "$bot_cwd" "session-closeout" "" \
    bash "$CLI_SH" closeout caller-closeout --as deploy-pipeline \
      --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"fixture"}' \
      --state pending >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "CALLER4 closeout" || return 1

  for action in archive force_mv closeout_update; do
    case "$action" in
      archive) f="$FATQ_ROOT/archived/caller-archive.json" ;;
      force_mv) f="$FATQ_ROOT/review/caller-force.json" ;;
      closeout_update) f="$FATQ_ROOT/done/caller-closeout.json" ;;
    esac
    jq -e --arg action "$action" '.history[-1].action == $action
      and .history[-1].caller.workspace == "anna"
      and .history[-1].caller.cwd_bot == "anna"
      and .history[-1].caller.pid_chain_ok == true' "$f" >/dev/null \
      || fail "CALLER4: $action caller object missing: $(jq -c '.history[-1]' "$f")" || return 1
    echo "  EVIDENCE CALLER4_${action}=$(jq -c '.history[-1]' "$f")"
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

for t in P1 P2 P3 P4 P5 P6 P7 P8 SUBMIT_HOLD1 SUBMIT_HOLD2 P9 P10 P11 P12 VERIFYDIAG1 SUBMIT_DEFER1 VERDICT_LOCK1 VERDICT_LOCK2 P13 P14 P15 P16 P17 P18 P19 P20 \
         P21 P22 P23 P24 P25 P26 P27 P28 P29 P30 \
         ARCHIVE1 ARCHIVE2 ARCHIVE3 ARCHIVE4 ARCHIVE5 ARCHIVE6 ARCHIVE7 CANCEL1 CANCEL2 CANCEL3 CANCEL4 \
         P31 CREATEVC1 CREATEVC2 CREATEVC3 CREATETITLE1 CREATETITLE2 CREATE_LIVE1 CREATE_LIVE2 CREATE_LIVE3 CREATE_LIVE4 SETLIVE1 SETLIVE2 SETLIVE3 SETLIVE4 \
         VERIFYFIELD_A1 VERIFYFIELD_A2 VERIFYFIELD_B1 VERIFYFIELD_C1 VERIFYFIELD_C2 VERIFYFIELD_D1 VERIFYFIELD_D2 VERIFYFIELD_D3 VERIFYFIELD_D4 VERIFYFIELD_D5 VERIFYFIELD_D6 VERIFYFIELD_D7 \
         P32 ESTATE ENOTFOUND CONC1 CLAIM_NOCLOBBER VALIDATE_DUP FIND_TASK_FILE_DUP REDLINE \
         AP1 AP2 AP3 AP4 AP5 AP6 AP7 AP8 AP9 AP10 INFRA1 INFRA2 INFRA3 INFRA4 INFRA5 INFRA6 INFRA7 INFRA8 INFRA9 INFRA10 INFRA11 INFRA12 INFRA13 \
         CREATEAFF1 CREATEAFF2 CREATEAFF3 CREATEAFF4 CREATESR1 CREATESR2 CREATESR3 CREATESR4 CREATESR5 CREATESR6 CREATESR7 EXTID1 EXTID2 \
         CLOCK1 CLOCK2 CLOCK3 CLOCK4 CLOCK5 \
         ATTACH1 ATTACH2 ATTACH3 ATTACH4 ATTACH5 \
         ENFORCE1 PERMPOOL1 ENFORCE2 ENFORCE3 ENFORCE4 \
         ADVISOR1 ADVISOR2 ADVISOR3 \
         CLOSEOUT1 CLOSEOUT2 CLOSEOUT3 CLOSEOUT4 CLOSEOUT5 CLOSEOUT6 CLOSEOUT7 CLOSEOUT8 \
         CLOSEOUT9 CLOSEOUT10 CLOSEOUT11 CLOSEOUT12 CLOSEOUT13 CLOSEOUT14 CLOSEOUT15 CLOSEOUT16 CLOSEOUT17 CLOSEOUT18 CLOSEOUT19 CLOSEOUT20 CLOSEOUT21 CLOSEOUT22 CLOSEOUT23 CLOSEOUT24 CLOSEOUT25 CLOSEOUT26 CLOSEOUT27 CLOSEOUT28 CLOSEOUT29 \
         FINALIZE1 FINALIZE2 FINALIZE3 FINALIZE4 FINALIZE5 FINALIZE6 FINALIZE7 \
         BACKFILL1 BACKFILL2 BACKFILL3 BACKFILL4 BACKFILL5 \
         DELIVER1 DELIVER2 DELIVER3 DELIVER4 DELIVER5 CALLER1 CALLER2 CALLER3 CALLER4 TOKENSTAMP; do
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

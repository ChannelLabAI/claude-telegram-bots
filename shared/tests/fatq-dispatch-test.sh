#!/usr/bin/env bash
# fatq-dispatch-test.sh — fixture tests for shared/bin/fatq-dispatch.sh
#
# Spec §5 (handover/fatq-dispatch-cron-spec-20260705.md). All fixtures are
# self-made in mktemp -d dirs — never asserts against real tasks/ (see
# feedback_closed_loop_test_fixture).
#
# Usage: fatq-dispatch-test.sh
# Exit:  0 = all A1-A16 pass (A12/A13 = regression cases, A14-A16 = not_before/Q7), 1 = one or more failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"

TOTAL_PASS=0
TOTAL_FAIL=0
FAIL_NAMES=()

BASE_EPOCH=1783000000   # fixed reference epoch for reproducibility

# ── fixture scaffolding ────────────────────────────────────────────────────
setup() {
  TMPROOT=$(mktemp -d)
  export FATQ_ROOT="$TMPROOT/tasks"
  export FATQ_RELAY_DIR="$TMPROOT/relay"
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,design,design_review,spec_review,reviews,proposals}
  mkdir -p "$FATQ_RELAY_DIR"
  unset FATQ_NOW_EPOCH || true
  export FATQ_STALE_SECS=7200
  export FATQ_NUDGE_COOLDOWN_SECS=7200
  export FATQ_MAX_NUDGES=3
  export FATQ_CLAIM_TTL_SECS=14400
  export FATQ_MAX_DISPATCH=3
  export FATQ_DRY_RUN=0
  export FATQ_UNASSIGNED_ALERT_SECS=3600
  export FATQ_UNASSIGNED_REMIND_SECS=86400
  export FATQ_STALE_RELAY_WARN_SECS=7200
  export FATQ_STATE_DIR="$TMPROOT/state"
  export FATQ_MATTERMOST_DISABLE=1   # 測試絕不真的打 mm_post
  mkdir -p "$FATQ_STATE_DIR"

  # 固定 fixture 業務線親和+公共財偵測表（d5c3）：不讀真實 shared/lib/
  # dispatch-affinity.json，避免該表被未來擴充後改變本測試的斷言基礎
  # （既有 A1-A19 案例先前意外讀到真實檔，只是剛好沒踩到受影響欄位；
  # 新增 A20+ 案例會實際命中，此處補上隔離）。
  export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
  cat > "$FATQ_DISPATCH_AFFINITY" <<'EOF'
{
  "infra_patterns": ["shared/", "crontab", "gateway", "調度", "fatq-dispatch"],
  "lines": {
    "anya": {"builder": "anna", "reviewer": "bella"},
    "caijie-zhuchu": {"builder": "sancai", "reviewer": "yitang"},
    "ron-assistant": {"builder": "eric", "reviewer": "ron-reviewer"},
    "default": {"builder": "anna", "reviewer": "bella"}
  }
}
EOF

  # 固定 fixture team-config（供 A25+ 的跨組件整合測試呼叫 fatq-cli.sh 用，
  # Bella QA REJECT 要求：relay 指示的動作必須以 CLI 實跑驗證會成功，不能
  # 只斷言 relay 檔的 recipient 欄位）
  export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
  export FATQ_VERIFY_SH="$SCRIPT_DIR/../bin/fatq-verify.sh"
  cat > "$FATQ_TEAM_CONFIG" <<'EOF'
{
  "assistants": [{"state_dir": "anya"}],
  "shared_pools": {
    "builder": [{"state_dir": "anna"}, {"state_dir": "sancai"}, {"state_dir": "eric"}],
    "reviewer": [{"state_dir": "bella"}, {"state_dir": "yitang"}, {"state_dir": "ron-reviewer"}]
  },
  "external_identities": ["mac-agent", "laotu"]
}
EOF
}

teardown() {
  rm -rf "$TMPROOT"
}

run_dispatch() {
  bash "$DISPATCH_SH" >>"$TMPROOT/dispatch.log" 2>&1
}

run_cli() {
  bash "$CLI_SH" "$@"
}

# make_task <path> <overrides-json>
make_task() {
  local path="$1" overrides="$2"
  jq -n --argjson ov "$overrides" \
    '{task_id: "override-me", slug: "t", status: "pending", history: []} * $ov' \
    > "$path"
}

relay_count() {
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# 模擬 gateway 消費：把 relay/ 頂層檔案移進 read/（讓下一輪的 rule-2 relay_file_exists 判定為已消費）
consume_relay() {
  mkdir -p "$FATQ_RELAY_DIR/read"
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' -exec mv {} "$FATQ_RELAY_DIR/read/" \; 2>/dev/null || true
}

history_len() {
  jq '.history | length' "$1"
}

history_actions() {
  jq -r '[.history[].action] | join(",")' "$1"
}

fail() {
  echo "    ✗ $*"
  return 1
}

# ══════════════════════════════════════════════════════════════════════════
# A1 — pending 有主 → 首派
# ══════════════════════════════════════════════════════════════════════════
test_A1() {
  local f="$FATQ_ROOT/pending/20260705-0000-a1a1-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a1a1-t1","assigned":"anna"}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "1" ]] || fail "relay count expected 1, got $(relay_count)" || return 1
  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "anna" ]] || fail "recipient wrong: $(jq -r '.recipient' "$rf")" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "history len expected 1, got $(history_len "$f")" || return 1
  [[ "$(jq -r '.status' "$f")" == "pending" ]] || fail "status field must not change" || return 1
  [[ -f "$f" ]] || fail "task must still be in pending/" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A2 — 同一任務連跑 3 輪（claim 未過期）→ relay 檔仍 1
# ══════════════════════════════════════════════════════════════════════════
test_A2() {
  local f="$FATQ_ROOT/pending/20260705-0000-a2a2-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a2a2-t1","assigned":"anna"}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  run_dispatch
  run_dispatch
  [[ "$(relay_count)" == "1" ]] || fail "relay count expected 1 after 3 runs, got $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "history should still be 1 entry (idempotent), got $(history_len "$f")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A3 — claim 過期 + 無活動 → 重派 attempt=2,3；達上限(4th) → escalate 不再派
# ══════════════════════════════════════════════════════════════════════════
test_A3() {
  local f="$FATQ_ROOT/pending/20260705-0000-a3a3-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a3a3-t1","assigned":"anna"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch   # attempt 1
  consume_relay  # 模擬 gateway 已撿走上一份，才有資格判斷 TTL 重派（rule 2 vs rule 3）
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_CLAIM_TTL_SECS + 100))
  run_dispatch   # attempt 2
  consume_relay
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 2*FATQ_CLAIM_TTL_SECS + 200))
  run_dispatch   # attempt 3
  consume_relay
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 3*FATQ_CLAIM_TTL_SECS + 300))
  run_dispatch   # would-be attempt 4 → escalate instead

  local actions
  actions=$(history_actions "$f")
  [[ "$(echo "$actions" | tr ',' '\n' | grep -c '^dispatch$')" == "3" ]] || fail "expected 3 dispatch entries, got actions=$actions" || return 1
  [[ "$(echo "$actions" | tr ',' '\n' | grep -c '^escalate$')" == "1" ]] || fail "expected 1 escalate entry, got actions=$actions" || return 1
  # 含已消費（移進 read/）的檔一起算，才是「這輪測試總共產生過幾個」
  local dispatch_relays escalate_relays
  dispatch_relays=$(find "$FATQ_RELAY_DIR" -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  escalate_relays=$(find "$FATQ_RELAY_DIR" -type f -name '*escalate.json' | wc -l | tr -d ' ')
  [[ "$dispatch_relays" == "3" ]] || fail "expected 3 dispatch relay files total, got $dispatch_relays" || return 1
  [[ "$escalate_relays" == "1" ]] || fail "expected 1 escalate relay file, got $escalate_relays" || return 1

  # 再跑一輪不應再 escalate 第二次
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 4*FATQ_CLAIM_TTL_SECS + 400))
  run_dispatch
  escalate_relays=$(find "$FATQ_RELAY_DIR" -type f -name '*escalate.json' | wc -l | tr -d ' ')
  [[ "$escalate_relays" == "1" ]] || fail "escalate must stay one-time, got $escalate_relays" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A4 — in_progress 停滯 2h+ → nudge；cooldown 內不加發；assignee 活動後歸零
# ══════════════════════════════════════════════════════════════════════════
test_A4() {
  local f="$FATQ_ROOT/in_progress/20260705-0000-a4a4-t1.json"
  make_task "$f" "{\"task_id\":\"20260705-0000-a4a4-t1\",\"assigned\":\"anna\",\"history\":[{\"ts\":\"$(TZ='Asia/Taipei' date -d "@$BASE_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')\",\"by\":\"anna\",\"action\":\"claimed\"}]}"

  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))
  run_dispatch
  local nudge_count
  nudge_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*nudge.json' | wc -l | tr -d ' ')
  [[ "$nudge_count" == "1" ]] || fail "expected 1 nudge file, got $nudge_count" || return 1

  # cooldown 內重跑不加發
  run_dispatch
  nudge_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*nudge.json' | wc -l | tr -d ' ')
  [[ "$nudge_count" == "1" ]] || fail "cooldown should prevent 2nd nudge, got $nudge_count" || return 1

  # 假造 assignee 新活動（重置計時器）
  local now_iso
  now_iso=$(TZ='Asia/Taipei' date -d "@$FATQ_NOW_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')
  local tmp; tmp=$(mktemp)
  jq --arg ts "$now_iso" '.history += [{"ts":$ts,"by":"anna","action":"progress_update"}]' "$f" > "$tmp" && mv "$tmp" "$f"

  # 同一時鐘立即重跑：距新活動 age=0 < STALE_SECS → 不該再催
  run_dispatch
  nudge_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*nudge.json' | wc -l | tr -d ' ')
  [[ "$nudge_count" == "1" ]] || fail "after assignee activity, no new nudge expected, got $nudge_count" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A5 — 3 次 nudge 無回應 → escalate 恰 1 次
# ══════════════════════════════════════════════════════════════════════════
test_A5() {
  local f="$FATQ_ROOT/in_progress/20260705-0000-a5a5-t1.json"
  make_task "$f" "{\"task_id\":\"20260705-0000-a5a5-t1\",\"assigned\":\"anna\",\"history\":[{\"ts\":\"$(TZ='Asia/Taipei' date -d "@$BASE_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')\",\"by\":\"anna\",\"action\":\"claimed\"}]}"

  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100));                                    run_dispatch  # nudge 1
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + FATQ_NUDGE_COOLDOWN_SECS + 200));          run_dispatch  # nudge 2
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 2*FATQ_NUDGE_COOLDOWN_SECS + 300));        run_dispatch  # nudge 3
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 3*FATQ_NUDGE_COOLDOWN_SECS + 400));        run_dispatch  # → escalate

  local nudges escs
  nudges=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*nudge.json' | wc -l | tr -d ' ')
  escs=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*escalate.json' | wc -l | tr -d ' ')
  [[ "$nudges" == "3" ]] || fail "expected 3 nudge files, got $nudges" || return 1
  [[ "$escs" == "1" ]] || fail "expected 1 escalate file, got $escs" || return 1

  # 再跑一輪不重複 escalate
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 4*FATQ_NUDGE_COOLDOWN_SECS + 500))
  run_dispatch
  escs=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*escalate.json' | wc -l | tr -d ' ')
  [[ "$escs" == "1" ]] || fail "escalate must not repeat, got $escs" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A6 — design_review / review 各 1 → 派給 reviewer 欄位者；缺省 Bella
# ══════════════════════════════════════════════════════════════════════════
test_A6() {
  local f1="$FATQ_ROOT/design_review/20260705-0000-a6a1-t1.json"
  local f2="$FATQ_ROOT/review/20260705-0000-a6a2-t2.json"
  make_task "$f1" '{"task_id":"20260705-0000-a6a1-t1","reviewer":"bella"}'
  make_task "$f2" '{"task_id":"20260705-0000-a6a2-t2"}'   # 無 reviewer 欄位 → 缺省 Bella

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local r1 r2
  r1=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a6a1*' 2>/dev/null | head -1)
  # 檔名不含 task 全名（deterministic 用 4hex），改用內容比對 fatq_task_id
  r1=$(grep -l "20260705-0000-a6a1-t1" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  r2=$(grep -l "20260705-0000-a6a2-t2" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$r1" ]] || fail "design_review dispatch relay not found" || return 1
  [[ -n "$r2" ]] || fail "review dispatch relay not found" || return 1
  [[ "$(jq -r '.recipient' "$r1")" == "Bella" ]] || fail "design_review recipient should be Bella, got $(jq -r '.recipient' "$r1")" || return 1
  [[ "$(jq -r '.recipient' "$r2")" == "Bella" ]] || fail "review (no reviewer field) should default Bella, got $(jq -r '.recipient' "$r2")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A7 — double-dispatch race（無 outer flock 併發 + outer flock 保護兩種都測）
# ══════════════════════════════════════════════════════════════════════════
test_A7() {
  # (a) 無 outer flock：兩個 dispatcher 同時跑，靠 script 內建 tmp+ln noclobber 去重
  local f="$FATQ_ROOT/pending/20260705-0000-a7a1-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a7a1-t1","assigned":"anna"}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH

  ( bash "$DISPATCH_SH" >>"$TMPROOT/race1.log" 2>&1 ) &
  local pid1=$!
  ( bash "$DISPATCH_SH" >>"$TMPROOT/race2.log" 2>&1 ) &
  local pid2=$!
  wait "$pid1" "$pid2" 2>/dev/null

  local dispatch_files
  dispatch_files=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  [[ "$dispatch_files" == "1" ]] || fail "(a) race without outer flock: expected exactly 1 dispatch relay, got $dispatch_files" || return 1
  # attempt 不應失控（只允許 attempt=1 這個檔名，無 a2/a3 冒出）
  local a1_only
  a1_only=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*-a1-dispatch.json' | wc -l | tr -d ' ')
  [[ "$a1_only" == "1" ]] || fail "(a) expected the single dispatch file to be attempt=1, found a1 count=$a1_only" || return 1

  # (b) outer flock 保護：第二實例應立即因搶不到鎖而退出，不執行本體
  local f2="$FATQ_ROOT/pending/20260705-0000-a7b2-t2.json"
  make_task "$f2" '{"task_id":"20260705-0000-a7b2-t2","assigned":"anna"}'
  local lockfile="$TMPROOT/outer.lock"

  ( flock -x "$lockfile" bash -c 'sleep 0.4; bash "'"$DISPATCH_SH"'"' >>"$TMPROOT/race3.log" 2>&1 ) &
  local pid3=$!
  sleep 0.05   # 確保 pid3 先拿到鎖
  flock -n "$lockfile" bash "$DISPATCH_SH" >>"$TMPROOT/race4.log" 2>&1
  local second_rc=$?
  wait "$pid3" 2>/dev/null

  [[ "$second_rc" -ne 0 ]] || fail "(b) second instance should fail to acquire outer flock (rc!=0), got rc=$second_rc" || return 1
  local t2_dispatch
  t2_dispatch=$(grep -l "20260705-0000-a7b2-t2" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [[ "$t2_dispatch" == "1" ]] || fail "(b) exactly one dispatch relay expected for t2, got $t2_dispatch" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A8 — crash 殘局：history 有 claim、relay 檔不存在
# ══════════════════════════════════════════════════════════════════════════
test_A8() {
  local f="$FATQ_ROOT/pending/20260705-0000-a8a8-t1.json"
  local claim_ts
  claim_ts=$(TZ='Asia/Taipei' date -d "@$BASE_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')
  make_task "$f" "{\"task_id\":\"20260705-0000-a8a8-t1\",\"assigned\":\"anna\",\"history\":[{\"ts\":\"$claim_ts\",\"by\":\"fatq-dispatch-cron\",\"action\":\"dispatch\",\"relay_file\":\"fatq-a8a8-a1-dispatch.json\",\"target\":\"anna\",\"attempt\":1}]}"
  # 注意：relay_file 刻意不建立在 $FATQ_RELAY_DIR（模擬寫入 relay 前 crash）

  # TTL 內：不應派發（信任 claim，即使 relay 實體缺失）
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 100))
  run_dispatch
  local rc
  rc=$(relay_count)
  [[ "$rc" == "0" ]] || fail "within TTL should not dispatch even if relay missing, relay count=$rc" || return 1

  # TTL 過後：恰補 1 檔
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_CLAIM_TTL_SECS + 100))
  run_dispatch
  rc=$(relay_count)
  [[ "$rc" == "1" ]] || fail "after TTL expiry should backfill exactly 1 relay file, got $rc" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A9 — 髒輸入：全部 skip + WARN，零 relay 產出，原檔零改動
# ══════════════════════════════════════════════════════════════════════════
test_A9() {
  local bad1="$FATQ_ROOT/pending/bad-not-json.json"
  echo "this is not json {{{" > "$bad1"
  local bad2="$FATQ_ROOT/pending/bad-no-taskid.json"
  echo '{"assigned":"anna"}' > "$bad2"
  local bad3="$FATQ_ROOT/spec_review/bad-review.md"
  echo "# some markdown review, not a task json" > "$bad3"
  local bad4="$FATQ_ROOT/proposals/PROP-001.json"
  echo '{"prop_id":"PROP-001"}' > "$bad4"

  local sum1 sum2 sum3 sum4
  sum1=$(md5sum "$bad1" | awk '{print $1}')
  sum2=$(md5sum "$bad2" | awk '{print $1}')
  sum3=$(md5sum "$bad3" | awk '{print $1}')
  sum4=$(md5sum "$bad4" | awk '{print $1}')

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "0" ]] || fail "dirty inputs must produce zero relay files, got $(relay_count)" || return 1
  [[ "$(md5sum "$bad1" | awk '{print $1}')" == "$sum1" ]] || fail "bad1 must be untouched" || return 1
  [[ "$(md5sum "$bad2" | awk '{print $1}')" == "$sum2" ]] || fail "bad2 must be untouched" || return 1
  [[ "$(md5sum "$bad3" | awk '{print $1}')" == "$sum3" ]] || fail "bad3 (.md) must be untouched" || return 1
  [[ "$(md5sum "$bad4" | awk '{print $1}')" == "$sum4" ]] || fail "bad4 (proposals/) must be untouched" || return 1
  grep -q "WARN" "$TMPROOT/dispatch.log" || fail "expected WARN log lines for dirty input" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A10 — FATQ_DRY_RUN=1：決策 log 齊全、檔案系統零寫入
# ══════════════════════════════════════════════════════════════════════════
test_A10() {
  local f="$FATQ_ROOT/pending/20260705-0000-a1010-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a1010-t1","assigned":"anna"}'
  local before_sum
  before_sum=$(md5sum "$f" | awk '{print $1}')

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  export FATQ_DRY_RUN=1
  run_dispatch

  [[ "$(relay_count)" == "0" ]] || fail "dry-run must not write relay files, got $(relay_count)" || return 1
  [[ "$(md5sum "$f" | awk '{print $1}')" == "$before_sum" ]] || fail "dry-run must not modify task file" || return 1
  grep -q "decision=dispatch" "$TMPROOT/dispatch.log" || fail "dry-run must still log the decision" || return 1
  export FATQ_DRY_RUN=0
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A11 — 紅線稽核：task 檔除 history append 外零變動、零跨目錄 mv
# ══════════════════════════════════════════════════════════════════════════
test_A11() {
  local f="$FATQ_ROOT/pending/20260705-0000-a1111-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a1111-t1","assigned":"anna","slug":"audit-me","priority":"P2"}'
  local before
  before=$(jq 'del(.history)' "$f")

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ -f "$f" ]] || fail "task must not have moved to another directory" || return 1
  local after
  after=$(jq 'del(.history)' "$f")
  [[ "$before" == "$after" ]] || fail "non-history fields changed:\nBEFORE=$before\nAFTER=$after" || return 1
  [[ "$(history_len "$f")" -ge "1" ]] || fail "history should have gained at least 1 entry" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A12（regression，Bella REJECT 2026-07-05 建議）— relay 檔名不可從 task_id
# 內容「抓字」。舊版 grep -oE '[0-9a-f]{4}' 會把兩個結尾都是合法 hex 字（如
# face）的不同 task_id 撞成同一個檔名；新版 task_hex_id() 消毒整個 task_id
# 天然 collision-free。
# ══════════════════════════════════════════════════════════════════════════
test_A12() {
  local f1="$FATQ_ROOT/pending/20260705-1200-face-alpha.json"
  local f2="$FATQ_ROOT/pending/20260705-1300-face-beta.json"
  make_task "$f1" '{"task_id":"20260705-1200-face-alpha","assigned":"anna"}'
  make_task "$f2" '{"task_id":"20260705-1300-face-beta","assigned":"anna"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "2" ]] || fail "expected 2 distinct dispatch relay files (no collision), got $(relay_count)" || return 1

  local r1 r2
  r1=$(grep -l "20260705-1200-face-alpha" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  r2=$(grep -l "20260705-1300-face-beta" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$r1" ]] || fail "no relay file found carrying task 1's content" || return 1
  [[ -n "$r2" ]] || fail "no relay file found carrying task 2's content" || return 1
  [[ "$r1" != "$r2" ]] || fail "task 1 and task 2 collided onto the same relay file: $r1" || return 1
  [[ "$(jq -r '.fatq_task_id' "$r1")" == "20260705-1200-face-alpha" ]] || fail "r1 content mismatched task_id" || return 1
  [[ "$(jq -r '.fatq_task_id' "$r2")" == "20260705-1300-face-beta" ]] || fail "r2 content mismatched task_id" || return 1
  [[ "$(history_len "$f1")" == "1" ]] || fail "task1 history should have exactly 1 dispatch entry" || return 1
  [[ "$(history_len "$f2")" == "1" ]] || fail "task2 history should have exactly 1 dispatch entry" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A13（regression，Anya rider 2026-07-05）— relay 檔名跨階段撞名：同一 task_id
# 先在 pending/ 被派給 assignee（type=dispatch, attempt=1），之後進了 review/
# 被派給 reviewer（同樣 type=dispatch, attempt=1）——沒有 phase 標記時兩次會
# 撞同一個檔名（read/ 舊檔被覆蓋、審計軌跡疊掉）。task_phase() 修好後兩者的
# relay 檔名應該不同（分別含 pending / review）。
# ══════════════════════════════════════════════════════════════════════════
test_A13() {
  local tid="20260705-1400-a13x-cross-phase"
  local f_pending="$FATQ_ROOT/pending/${tid}.json"
  make_task "$f_pending" "{\"task_id\":\"$tid\",\"assigned\":\"anna\"}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch   # pending 階段派工 assignee，attempt=1

  local pending_relay
  pending_relay=$(grep -l "$tid" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$pending_relay" ]] || fail "pending 階段沒派出 relay" || return 1
  [[ "$(basename "$pending_relay")" == *"-pending-"* ]] || fail "pending 階段 relay 檔名應含 phase=pending，實際：$(basename "$pending_relay")" || return 1

  # 模擬 assignee 真的做完工作（pending→in_progress→review 走完，留下真實
  # 非 cron 活動記錄），才把任務移到 review/ 補上 reviewer 欄位 —— 這才是
  # Anya 描述的真實情境：舊 dispatch claim 因為有 assignee 活動而不再擋路，
  # attempt 才會被重算為 1，跟 pending 階段的 attempt=1 同名（若無 phase 標記）。
  consume_relay
  local now_iso
  now_iso=$(TZ='Asia/Taipei' date -d "@$BASE_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')
  local tmp; tmp=$(mktemp)
  jq --arg ts "$now_iso" '.history += [{"ts":$ts,"by":"anna","action":"completed_and_submitted"}] | .reviewer = "bella"' "$f_pending" > "$tmp"
  local f_review="$FATQ_ROOT/review/${tid}.json"
  mv "$tmp" "$f_review"
  rm_moved_pending_fixture "$f_pending"

  run_dispatch   # review 階段派工 reviewer，同樣 attempt=1，但 phase 不同

  # pending_relay 此時已被 consume_relay 移進 read/，relay/ 根目錄裡剩下的
  # 唯一 .json 檔就是這次 review 階段新派出的（不能再用 -newer 比對已被移走的
  # 舊檔路徑，那個路徑此刻已不存在）
  local review_relay
  review_relay=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | head -1)
  [[ -n "$review_relay" ]] || fail "review 階段沒派出新 relay" || return 1
  [[ "$(basename "$review_relay")" == *"-review-"* ]] || fail "review 階段 relay 檔名應含 phase=review，實際：$(basename "$review_relay")" || return 1
  [[ "$(basename "$pending_relay")" != "$(basename "$review_relay")" ]] || fail "pending 與 review 階段撞成同一個檔名：$(basename "$pending_relay")" || return 1
  return 0
}

# 測試 fixture 專用：移除已被「模擬轉移」的 pending 檔（非 cron 行為，純測試佈景清理）
rm_moved_pending_fixture() {
  rm -f "$1"
}

# ══════════════════════════════════════════════════════════════════════════
# A14（Q7 正式解，2026-07-06）— not_before 未到 → skip:not_before，零派工零催工
# ══════════════════════════════════════════════════════════════════════════
test_A14() {
  local nb_future
  # 要蓋過下面用來觸發 in_progress stale 門檻的 FATQ_NOW_EPOCH（BASE_EPOCH+STALE_SECS+100），
  # 否則 not_before 會在測試檢查前就先「到點」，失去驗證意義。
  nb_future=$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH + FATQ_STALE_SECS + 3600))" '+%Y-%m-%dT%H:%M:%S+08:00')
  local f_pending="$FATQ_ROOT/pending/20260706-0000-a14a-t1.json"
  make_task "$f_pending" "{\"task_id\":\"20260706-0000-a14a-t1\",\"assigned\":\"anna\",\"not_before\":\"$nb_future\"}"

  local claim_ts
  claim_ts=$(TZ='Asia/Taipei' date -d "@$BASE_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')
  local f_inprog="$FATQ_ROOT/in_progress/20260706-0000-a14b-t2.json"
  make_task "$f_inprog" "{\"task_id\":\"20260706-0000-a14b-t2\",\"assigned\":\"anna\",\"not_before\":\"$nb_future\",\"history\":[{\"ts\":\"$claim_ts\",\"by\":\"anna\",\"action\":\"claimed\"}]}"

  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))   # in_progress 早已過 stale 門檻，若無 not_before 早該催了
  run_dispatch

  [[ "$(relay_count)" == "0" ]] || fail "not_before 未到：relay 應為 0，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f_pending")" == "0" ]] || fail "pending 任務 history 不應被寫入（skip 不留 claim）" || return 1
  [[ "$(history_len "$f_inprog")" == "1" ]] || fail "in_progress 任務 history 不應新增 nudge，仍應為 1" || return 1
  grep -q "decision=skip:not_before" "$TMPROOT/dispatch.log" || fail "log 應含 skip:not_before 決策" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A15（Q7 正式解）— not_before 到點（過去時間）→ 正常派工/催工
# ══════════════════════════════════════════════════════════════════════════
test_A15() {
  local nb_past
  nb_past=$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH - 600))" '+%Y-%m-%dT%H:%M:%S+08:00')
  local f="$FATQ_ROOT/pending/20260706-0000-a15a-t1.json"
  make_task "$f" "{\"task_id\":\"20260706-0000-a15a-t1\",\"assigned\":\"anna\",\"not_before\":\"$nb_past\"}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "1" ]] || fail "not_before 已過：應正常派工 1 筆 relay，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "應寫入 1 筆 dispatch history" || return 1
  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "anna" ]] || fail "recipient 錯誤" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A16（Q7 正式解）— not_before 未到 + 無 assigned（無主）→ 仍走 skip:not_before，
# 不觸發 unassigned_alert（兩者互斥，not_before 優先）
# ══════════════════════════════════════════════════════════════════════════
test_A16() {
  local nb_future
  nb_future=$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH + 600))" '+%Y-%m-%dT%H:%M:%S+08:00')
  local f="$FATQ_ROOT/pending/20260706-0000-a16a-t1.json"
  make_task "$f" "{\"task_id\":\"20260706-0000-a16a-t1\",\"not_before\":\"$nb_future\",\"created_at\":\"$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH - FATQ_UNASSIGNED_ALERT_SECS - 100))" '+%Y-%m-%dT%H:%M:%S+08:00')\"}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH   # 已超過 unassigned alert 門檻，若無 not_before 互斥早該告警了
  run_dispatch

  [[ "$(relay_count)" == "0" ]] || fail "not_before 未到：無主任務也不該產生 unassigned_alert relay，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "0" ]] || fail "不應寫入 unassigned_alert 或任何 history" || return 1
  grep -q "decision=skip:not_before" "$TMPROOT/dispatch.log" || fail "log 應含 skip:not_before 決策（優先於 unassigned 判斷）" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A17-A19（Anya 裁決 2026-07-07，Part 2 spec_conflict 結案，task a7e5）：
# approval 門控——pending 任務 approval.decision 為 null（含 expired）→
# skip:approval_gated，不派工、不寫 history。三態斷言：approved 正常派工、
# expired 在 pending 被 skip、無 approval 物件不受影響。
# ══════════════════════════════════════════════════════════════════════════
test_A17() {
  # approved：decision != null → 正常派工，不受門控影響
  local f="$FATQ_ROOT/pending/20260707-0000-a17a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a17a-t1","assigned":"anna","approval":{"status":"approved","domain":"security","requested_by":"anna","approvers":["laotu"],"decided_by":"laotu","decided_at":"2026-07-07T10:00:00+08:00","decision":"approve","reason":null,"evidence":"tg:1","expires":"2026-07-08T00:00:00+08:00","return_state":"pending"}}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "1" ]] || fail "A17: approved 任務應正常派工，relay 應為 1，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "A17: 應寫入 1 筆 dispatch history" || return 1
  grep -q "decision=dispatch" "$TMPROOT/dispatch.log" || fail "A17: log 應為 dispatch 決策" || return 1
  return 0
}

test_A18() {
  # expired：decision 為 null（含 status=expired）→ skip:approval_gated，不派不寫 history
  local f="$FATQ_ROOT/pending/20260707-0000-a18a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a18a-t1","assigned":"anna","approval":{"status":"expired","domain":"security","requested_by":"anna","approvers":["laotu"],"decided_by":null,"decided_at":null,"decision":null,"reason":null,"evidence":null,"expires":"2026-07-06T00:00:00+08:00","return_state":"pending"}}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "0" ]] || fail "A18: expired 任務不該被派工，relay 應為 0，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "0" ]] || fail "A18: 不應寫入任何 history（紅線：cron 對此情形零寫入）" || return 1
  grep -q "decision=skip:approval_gated" "$TMPROOT/dispatch.log" || fail "A18: log 應含 skip:approval_gated 決策" || return 1
  return 0
}

test_A19() {
  # 無 approval 物件：完全不受影響，正常派工（對照組）
  local f="$FATQ_ROOT/pending/20260707-0000-a19a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a19a-t1","assigned":"anna"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "1" ]] || fail "A19: 無 approval 物件的任務應正常派工，relay 應為 1，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "A19: 應寫入 1 筆 dispatch history" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A20-A24（org-design-lines-20260707 決議 #2/#3，d5c3）：業務線軟親和 +
# 公共財 infra gate。改 shared/lib/dispatch-affinity.json 不動代碼即生效
# （測試用固定 fixture 表，見 setup()）。
# ══════════════════════════════════════════════════════════════════════════

test_A20() {
  # ①軟親和「建議制」（Bella QA REJECT 修正，2026-07-07）：assigned 為空時
  # 不可直接拿親和預設當 assigned 派工——task 檔欄位仍是空的，relay 收件人
  # claim 時會被 claim_locked 的 assigned==identity 檢查擋下 E_PERM（Bella
  # fixture 實測抓到）。改回走原本的 unassigned_pending 告警，只是文案帶上
  # 親和建議人選（caijie-zhuchu→sancai）供 Anya 參考+一鍵 reassign 指令。
  local f="$FATQ_ROOT/pending/20260707-0000-a20a-t1.json"
  make_task "$f" "{\"task_id\":\"20260707-0000-a20a-t1\",\"created_by\":\"caijie-zhuchu\",\"created_at\":\"$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH - FATQ_UNASSIGNED_ALERT_SECS - 100))" '+%Y-%m-%dT%H:%M:%S+08:00')\"}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "1" ]] || fail "A20: 應產生 1 個 unassigned_alert relay（非直接派工），實得 $(relay_count)" || return 1
  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  grep -q "sancai" "$rf" || fail "A20: 告警文案應含親和建議人選 sancai" || return 1
  grep -q "fatq reassign" "$rf" || fail "A20: 告警文案應含 reassign 指引" || return 1
  [[ "$(history_actions "$f")" == "unassigned_alert" ]] || fail "A20: history 應為 unassigned_alert（非直接 dispatch），實得 $(history_actions "$f")" || return 1
  return 0
}

test_A21() {
  # 明文指定不被覆蓋：即使 created_by=caijie-zhuchu（親和=sancai），assigned
  # 已明文寫 anna → 一律尊重 anna，不套用親和預設
  local f="$FATQ_ROOT/pending/20260707-0000-a21a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a21a-t1","created_by":"caijie-zhuchu","assigned":"anna"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "anna" ]] || fail "A21: 明文指定的 assigned=anna 不該被親和表覆蓋，實得 $(jq -r '.recipient' "$rf")" || return 1
  return 0
}

test_A22() {
  # reviewer 為空維持舊版硬編碼預設 bella（Bella QA REJECT 修正）：親和表不可
  # 指向非 bella/anya 身份填空欄位——欄位仍是空的，該身份 verdict 時會被 E4
  # 的 reviewer-of-record 檢查拒絕（bella 是唯一「欄位空也有權審」的身份，
  # 因為 E4 允許集合是 reviewer 欄位者 ∪ {bella, anya}）。
  local f="$FATQ_ROOT/review/20260707-0000-a22a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a22a-t1","created_by":"ron-assistant","assigned":"eric"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local rf
  rf=$(grep -l "a22a" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$rf" ]] || fail "A22: 找不到 review 派工 relay" || return 1
  [[ "$(jq -r '.recipient' "$rf")" == "Bella" ]] || fail "A22: reviewer 為空應維持預設 Bella（不套用親和表），實得 $(jq -r '.recipient' "$rf")" || return 1
  return 0
}

test_A23() {
  # ②infra gate：goal 命中公共財模式（"shared/"）→ reviewer 強制 bella，
  # 即使已明文指定 yitang 也覆蓋；history 記 1 次性 infra_gate_override
  local f="$FATQ_ROOT/review/20260707-0000-a23a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a23a-t1","assigned":"anna","reviewer":"yitang","goal":"修改 shared/bin/some-script.sh"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local rf
  rf=$(grep -l "a23a" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$rf" ]] || fail "A23: 找不到 review 派工 relay" || return 1
  [[ "$(jq -r '.recipient' "$rf")" == "Bella" ]] || fail "A23: infra gate 應強制 recipient=Bella，實得 $(jq -r '.recipient' "$rf")" || return 1
  local override_count
  override_count=$(jq '[.history[] | select(.action=="infra_gate_override")] | length' "$f")
  [[ "$override_count" == "1" ]] || fail "A23: 應恰有 1 筆 infra_gate_override history，實得 $override_count" || return 1
  [[ "$(jq -r '.history[] | select(.action=="infra_gate_override") | .original_reviewer' "$f")" == "yitang" ]] || fail "A23: history 應記錄原本的 reviewer=yitang" || return 1

  # 再跑一輪：不應重複寫入 infra_gate_override（1 次性）
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 100))
  run_dispatch
  override_count=$(jq '[.history[] | select(.action=="infra_gate_override")] | length' "$f")
  [[ "$override_count" == "1" ]] || fail "A23: infra_gate_override 應維持 1 次性，重跑後實得 $override_count" || return 1
  return 0
}

test_A24() {
  # 自指驗證（acceptance_criteria③）：本任務（d5c3）自己的 goal 含「調度」
  # 字樣，理當被 infra gate 判定強制 bella
  local f="$FATQ_ROOT/review/20260707-0000-a24a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a24a-t1","assigned":"anna","reviewer":"yitang","goal":"調度層兩條新規則（老兔 2026-07-07 拍板的組織設計落地）：①按線軟親和派工 ②共用基建路徑偵測→reviewer 強制 bella。"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local rf
  rf=$(grep -l "a24a" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$rf" ]] || fail "A24: 找不到 review 派工 relay" || return 1
  [[ "$(jq -r '.recipient' "$rf")" == "Bella" ]] || fail "A24（自指驗證）：本案自己的 goal 應觸發 infra gate 強制 Bella，實得 $(jq -r '.recipient' "$rf")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A25-A28（Bella QA REJECT，2026-07-07）：跨組件整合測試——relay 指示的動作
# 必須以 fatq-cli.sh 實跑成功，不能只斷言 relay 檔的 recipient 欄位。
# [[feedback_cross_component_handoff_test]]：分層測試各自全綠≠交接正確。
# ══════════════════════════════════════════════════════════════════════════

test_A25() {
  # 明文 assigned 的正常派工：relay 叫 anna claim，anna 真的用 fatq-cli claim 必須成功
  local f="$FATQ_ROOT/pending/20260707-0000-a25a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a25a-t1","assigned":"anna"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "1" ]] || fail "A25: 應正常派工，relay 應為 1" || return 1

  local rc
  run_cli claim 20260707-0000-a25a-t1 --as anna >/dev/null 2>&1; rc=$?
  [[ "$rc" == "0" ]] || fail "A25: relay 叫 anna claim，anna 用 fatq-cli claim 實跑應成功，實得 exit=$rc" || return 1
  [[ -f "$FATQ_ROOT/in_progress/20260707-0000-a25a-t1.json" ]] || fail "A25: 應成功轉移到 in_progress/" || return 1
  return 0
}

test_A26() {
  # reviewer 為空預設 bella：relay 叫 Bella verdict，bella 真的用 fatq-cli verdict approve 必須成功
  local f="$FATQ_ROOT/review/20260707-0000-a26a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a26a-t1","assigned":"anna","status":"review"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  local rf
  rf=$(grep -l "a26a" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "Bella" ]] || fail "A26: reviewer 為空應預設 Bella" || return 1

  local rc
  run_cli verdict approve 20260707-0000-a26a-t1 --as bella --evidence "test" >/dev/null 2>&1; rc=$?
  [[ "$rc" == "0" ]] || fail "A26: relay 叫 Bella verdict，bella 用 fatq-cli verdict approve 實跑應成功（reviewer 欄位雖空，bella 有 E4 萬用審查權），實得 exit=$rc" || return 1
  [[ -f "$FATQ_ROOT/done/20260707-0000-a26a-t1.json" ]] || fail "A26: 應成功轉移到 done/" || return 1
  return 0
}

test_A27() {
  # infra gate 覆蓋：原本 reviewer=yitang 被強制改 Bella，relay 叫 Bella
  # verdict，bella 用 fatq-cli 實跑必須成功（即使欄位仍寫 yitang 未被改寫）
  local f="$FATQ_ROOT/review/20260707-0000-a27a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a27a-t1","assigned":"anna","reviewer":"yitang","status":"review","goal":"修改 shared/bin/some-script.sh"}'

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  local rf
  rf=$(grep -l "a27a" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "Bella" ]] || fail "A27: infra gate 應強制 Bella" || return 1
  [[ "$(jq -r '.reviewer' "$f")" == "yitang" ]] || fail "A27: task 檔的 reviewer 欄位本身不應被 dispatch 改寫（cron 只 append history）" || return 1

  local rc
  run_cli verdict approve 20260707-0000-a27a-t1 --as bella --evidence "test" >/dev/null 2>&1; rc=$?
  [[ "$rc" == "0" ]] || fail "A27: relay 叫 Bella verdict（infra gate 覆蓋），bella 用 fatq-cli 實跑應成功，實得 exit=$rc" || return 1
  return 0
}

test_A28() {
  # 軟親和「建議制」修復確認：unassigned_alert 的建議人選（親和預設）在
  # task 檔的 assigned 欄位真的沒被寫入前，該身份用 fatq-cli claim 必須失敗
  # （E_PERM）——證明修復前的死路徑（relay 叫 claim 但欄位空）不會再發生。
  # Anya 真的執行 fatq reassign 寫入欄位後，claim 才會成功。
  local f="$FATQ_ROOT/pending/20260707-0000-a28a-t1.json"
  make_task "$f" "{\"task_id\":\"20260707-0000-a28a-t1\",\"created_by\":\"caijie-zhuchu\",\"created_at\":\"$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH - FATQ_UNASSIGNED_ALERT_SECS - 100))" '+%Y-%m-%dT%H:%M:%S+08:00')\"}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(history_actions "$f")" == "unassigned_alert" ]] || fail "A28: 應走 unassigned_alert（前提：A20 已驗證此行為）" || return 1

  # 修復前的死路徑：親和建議人選 sancai 此刻 assigned 欄位仍是空的，claim 必敗
  local rc
  run_cli claim 20260707-0000-a28a-t1 --as sancai >/dev/null 2>&1; rc=$?
  [[ "$rc" == "3" ]] || fail "A28: 親和建議人選在欄位未寫入前 claim 應該失敗（E_PERM），實得 exit=$rc（若這裡是 0，代表死路徑又回來了）" || return 1

  # 正確流程：Anya 執行 reassign 後，sancai 才能 claim 成功
  run_cli reassign 20260707-0000-a28a-t1 --as anya --to sancai >/dev/null 2>&1; rc=$?
  [[ "$rc" == "0" ]] || fail "A28: anya reassign 應成功，實得 exit=$rc" || return 1
  run_cli claim 20260707-0000-a28a-t1 --as sancai >/dev/null 2>&1; rc=$?
  [[ "$rc" == "0" ]] || fail "A28: reassign 之後 sancai claim 應該成功，實得 exit=$rc" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A29 — e4c8 builder_fix：同一任務被兩個併發觸發源（fatq-watch + cron 重疊）
# 同時掃到 → 恰好只留 1 筆 dispatch history + 1 個 relay 檔（22:17:27/22:18:47
# 事故重現：舊版 append-history-then-claim-relay 順序下，history 會被寫 2 筆
# 即使 relay 檔名去重擋住了重複 TG 通知）。用真的併發起多個 dispatch 進程
# （非序列跑兩次）才逼得出這個 race——序列跑第二次一定會看到第一次已寫的
# history 而正常跳過，測不出兩個進程「同時都還沒看到對方寫入」的窗口。
# ══════════════════════════════════════════════════════════════════════════
test_A29() {
  local f="$FATQ_ROOT/review/20260707-0000-a29a-t1.json"
  make_task "$f" '{"task_id":"20260707-0000-a29a-t1","assigned":"anna","reviewer":"bella"}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH

  # 真併發：8 個 dispatch 進程同時起跑，逼出「都還沒看到對方寫入」的窗口
  local pids=() i
  for i in $(seq 1 8); do
    ( bash "$DISPATCH_SH" >>"$TMPROOT/dispatch-concurrent-$i.log" 2>&1 ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  local dispatch_count relay_count_now
  dispatch_count=$(echo "$(history_actions "$f")" | tr ',' '\n' | grep -c '^dispatch$')
  relay_count_now=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  [[ "$dispatch_count" == "1" ]] || fail "A29: 8 個併發 dispatch 進程後 history 應恰 1 筆 dispatch，實得 $dispatch_count（22:17:27/22:18:47 事故重現＝race 未修）" || return 1
  [[ "$relay_count_now" == "1" ]] || fail "A29: relay 檔應恰 1 個，實得 $relay_count_now" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "A29: history 總長度應為 1（無其他雜訊條目），實得 $(history_len "$f")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# runner
# ══════════════════════════════════════════════════════════════════════════
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

for t in A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A12 A13 A14 A15 A16 A17 A18 A19 \
         A20 A21 A22 A23 A24 A25 A26 A27 A28 A29; do
  run_test "$t"
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-dispatch-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail (of $((TOTAL_PASS+TOTAL_FAIL)))"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-dispatch-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
echo "[fatq-dispatch-test] All cases passed ✅"
exit 0

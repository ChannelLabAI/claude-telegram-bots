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
}

teardown() {
  rm -rf "$TMPROOT"
}

run_dispatch() {
  bash "$DISPATCH_SH" >>"$TMPROOT/dispatch.log" 2>&1
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

for t in A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A12 A13 A14 A15 A16; do
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

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
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review,reviews,proposals}
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
# A6 — design_review / review 各 1 → 派給 reviewer 欄位者；缺省 bella
# ══════════════════════════════════════════════════════════════════════════
test_A6() {
  local f1="$FATQ_ROOT/design_review/20260705-0000-a6a1-t1.json"
  local f2="$FATQ_ROOT/review/20260705-0000-a6a2-t2.json"
  make_task "$f1" '{"task_id":"20260705-0000-a6a1-t1","reviewer":"bella"}'
  make_task "$f2" '{"task_id":"20260705-0000-a6a2-t2"}'   # 無 reviewer 欄位 → 缺省 bella

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local r1 r2
  r1=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a6a1*' 2>/dev/null | head -1)
  # 檔名不含 task 全名（deterministic 用 4hex），改用內容比對 fatq_task_id
  r1=$(grep -l "20260705-0000-a6a1-t1" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  r2=$(grep -l "20260705-0000-a6a2-t2" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$r1" ]] || fail "design_review dispatch relay not found" || return 1
  [[ -n "$r2" ]] || fail "review dispatch relay not found" || return 1
  [[ "$(jq -r '.recipient' "$r1")" == "bella" ]] || fail "design_review recipient should be bella, got $(jq -r '.recipient' "$r1")" || return 1
  [[ "$(jq -r '.recipient' "$r2")" == "bella" ]] || fail "review (no reviewer field) should default bella, got $(jq -r '.recipient' "$r2")" || return 1
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
  [[ "$(jq -r '.recipient' "$rf")" == "bella" ]] || fail "A22: reviewer 為空應維持預設 bella（不套用親和表），實得 $(jq -r '.recipient' "$rf")" || return 1
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
  [[ "$(jq -r '.recipient' "$rf")" == "bella" ]] || fail "A23: infra gate 應強制 recipient=bella，實得 $(jq -r '.recipient' "$rf")" || return 1
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
  [[ "$(jq -r '.recipient' "$rf")" == "bella" ]] || fail "A24（自指驗證）：本案自己的 goal 應觸發 infra gate 強制 bella，實得 $(jq -r '.recipient' "$rf")" || return 1
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
  [[ "$(jq -r '.recipient' "$rf")" == "bella" ]] || fail "A26: reviewer 為空應預設 bella" || return 1

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
  [[ "$(jq -r '.recipient' "$rf")" == "bella" ]] || fail "A27: infra gate 應強制 bella" || return 1
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
  dispatch_count=$(echo "$(history_actions "$f")" | tr ',' '\n' | grep -c '^dispatch$' || echo 0)
  relay_count_now=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  [[ "$dispatch_count" == "1" ]] || fail "A29: 8 個併發 dispatch 進程後 history 應恰 1 筆 dispatch，實得 $dispatch_count（22:17:27/22:18:47 事故重現＝race 未修）" || return 1
  [[ "$relay_count_now" == "1" ]] || fail "A29: relay 檔應恰 1 個，實得 $relay_count_now" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "A29: history 總長度應為 1（無其他雜訊條目），實得 $(history_len "$f")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A30/A31 — d7e2：c2d1 剛建檔即被誤報無主+假 56 年年齡的事故硬化
#
# 這兩個 case 直接單元測內部函式，不透過完整 run_dispatch 掃描——真的重現
# 「檔案在 readdir 列出之後、被這個函式讀到之前消失」這個時序窗口極短，用
# 時間精準複現本來就不穩定（跟 A29 的「多進程搶同一份穩定檔案」不同類型的
# race，A29 可以靠併發硬逼出來，這個窗口小到逼不出來）。測的是函式的契約：
# 兩路都失敗必須顯式回傳失敗、不能被 caller 的算術當 0 用；重驗邏輯本身
# 也不依賴時序，直接餵一個「重驗當下已經有 assigned」的檔案就能測到。
#
# source 技巧：main "$@" 和 exit 0 是檔案最後兩行，直接 source 整支腳本會
# 真的觸發一次完整掃描、而且 exit 0 會讓當前 shell 直接終止——剝掉最後兩行
# 只留函式定義（不改動原始檔案，只在暫存複本上操作）。
# ══════════════════════════════════════════════════════════════════════════
source_dispatch_functions() {
  local stripped
  stripped=$(mktemp)
  head -n -2 "$DISPATCH_SH" > "$stripped"
  source "$stripped"
  rm -f "$stripped"
}

test_A30() {
  (
    source_dispatch_functions

    # 兩路都失敗（檔案不存在＝mtime fallback 也拿不到）→ 必須明確 exit!=0，
    # 不能印出任何東西讓 caller 誤當合法 epoch 用
    out=$(get_created_epoch "$TMPROOT/does-not-exist.json" 2>/dev/null)
    rc=$?
    [[ "$rc" -ne 0 ]] || { echo "    ✗ A30: 對不存在的檔案應該失敗(exit!=0)，卻成功了：$out"; exit 1; }
    [[ -z "$out" ]] || { echo "    ✗ A30: 失敗時不該印任何東西到 stdout，卻印了：$out"; exit 1; }

    # 正常路：created_at 有效值 → 成功，epoch 合理
    f="$TMPROOT/valid.json"
    echo '{"task_id":"x","created_at":"2026-07-08T10:00:00+08:00"}' > "$f"
    ep=$(get_created_epoch "$f")
    rc=$?
    [[ "$rc" -eq 0 && "$ep" -gt 0 ]] || { echo "    ✗ A30: 正常 created_at 應該成功且 epoch>0，得到 rc=$rc ep=$ep"; exit 1; }

    # 退回路：created_at 缺，但檔案存在 → 退回 mtime，仍要成功（不是本次修復
    # 要動的路徑，但改動後這條既有行為不能跟著壞）
    f2="$TMPROOT/no-created.json"
    echo '{"task_id":"x"}' > "$f2"
    ep2=$(get_created_epoch "$f2")
    rc2=$?
    [[ "$rc2" -eq 0 && "$ep2" -gt 0 ]] || { echo "    ✗ A30: 缺 created_at 但檔案存在，應退回 mtime 成功，得到 rc=$rc2 ep=$ep2"; exit 1; }
    exit 0
  )
}

test_A31() {
  (
    source_dispatch_functions
    export FATQ_ROOT="$TMPROOT/tasks" FATQ_RELAY_DIR="$TMPROOT/relay" FATQ_STATE_DIR="$TMPROOT/state"
    export FATQ_NOW_EPOCH=$BASE_EPOCH
    mkdir -p "$FATQ_STATE_DIR"

    f="$TMPROOT/tasks/pending/a31-task.json"
    mkdir -p "$(dirname "$f")"
    old_ts=$(TZ='Asia/Taipei' date -d "@$((BASE_EPOCH - FATQ_UNASSIGNED_ALERT_SECS - 100))" '+%Y-%m-%dT%H:%M:%S+08:00')
    # 關鍵：assigned 這裡已經有值——模擬「外層 scan_dir_dispatch 讀到空、決定
    # 呼叫 handle_unassigned_pending，但真的執行到這裡之前任務已經被指派」。
    # 直接呼叫這個函式繞開外層那次判斷，專測函式內部有沒有重驗當下狀態。
    printf '{"task_id":"a31-task","created_at":"%s","assigned":"anna","history":[]}' "$old_ts" > "$f"

    handle_unassigned_pending "$f"

    relay_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*unassigned.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$relay_count" == "0" ]] || { echo "    ✗ A31: 已有 assigned 的任務不該觸發無主告警，卻發了 $relay_count 個 relay"; exit 1; }
    hist_len=$(jq '.history | length' "$f" 2>/dev/null)
    [[ "$hist_len" == "0" ]] || { echo "    ✗ A31: 不該寫入任何 history（history 應仍是空陣列），實得 $hist_len 筆"; exit 1; }
    exit 0
  )
}

# A32 — c2d1 事故的直接重現：handle_unassigned_pending 收到一個 get_created_epoch
# 兩路都會失敗的任務檔（這裡用「檔案不存在」模擬——跟 readdir 列出後、這個函式
# 真正執行前檔案已經消失，效果相同：jq 讀不到、stat 也讀不到），caller 不能
# 把失敗的空字串當 0 算出巨大假年齡、拿去發一則帶假年齡的無主告警。
# A30 測的是 get_created_epoch 這個葉函式自己的契約；A32 測的是呼叫端真的
# 有沒有守住這個契約——事故的根因其實在呼叫端沒檢查回傳值，不在葉函式本身
# （驗證見下：A30 對修復前的代碼其實就過，A32 才是真正抓到事故的那個）。
test_A32() {
  (
    source_dispatch_functions
    export FATQ_ROOT="$TMPROOT/tasks" FATQ_RELAY_DIR="$TMPROOT/relay" FATQ_STATE_DIR="$TMPROOT/state"
    export FATQ_NOW_EPOCH=$BASE_EPOCH
    mkdir -p "$FATQ_STATE_DIR" "$TMPROOT/tasks/pending"
    f="$TMPROOT/tasks/pending/a32-ghost.json"
    # 故意不建立這個檔案。

    handle_unassigned_pending "$f" 2>/dev/null

    relay_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*unassigned.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$relay_count" == "0" ]] || {
      bogus=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*unassigned.json' -exec jq -r '.text' {} \; 2>/dev/null)
      echo "    ✗ A32: get_created_epoch 兩路都失敗時不該送出告警（可能帶假 56 年年齡），卻發了 $relay_count 個：$bogus"
      exit 1
    }
    exit 0
  )
}

# A33 — e6a8：Bella 親身回報的殘留派工源——任務在 scan_dir_dispatch 列出時還在
# review/，handle_dispatch_target 真的執行（含它自己那幾次 jq 讀 history 算
# attempt 的過程）之前，已經被 verdict 移到 done/ 或 rejected/，但舊版的
# dispatch_send 內部存在檢查發生在 write_relay_atomic「已經送出通知」之後，
# 太晚——Bella 因此收到過期的「請審」relay。用「直接餵一個不存在的路徑」
# 模擬這個窗口（等價於檔案在被讀到前就已經不在原路徑上）。
test_A33() {
  (
    source_dispatch_functions
    export FATQ_ROOT="$TMPROOT/tasks" FATQ_RELAY_DIR="$TMPROOT/relay" FATQ_STATE_DIR="$TMPROOT/state"
    export FATQ_NOW_EPOCH=$BASE_EPOCH
    mkdir -p "$FATQ_STATE_DIR" "$TMPROOT/tasks/review"
    f="$TMPROOT/tasks/review/a33-ghost.json"
    # 故意不建立這個檔案（模擬已經被 verdict 移走）。

    handle_dispatch_target "$f" "bella" "" "[FATQ 派工] 請審"

    relay_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$relay_count" == "0" ]] || { echo "    ✗ A33: 任務已離開來源目錄（review 審完移 done/rejected），不該送出過期請審通知，卻發了 $relay_count 個"; exit 1; }
    exit 0
  )
}

# A34 — A33 的對照組：任務真的還在 review/（沒被移走）→ 正常派，防呆本身
# 不能連正常路徑一起誤傷（review_focus 明講「不誤傷仍在 review 的單」）。
test_A34() {
  (
    source_dispatch_functions
    export FATQ_ROOT="$TMPROOT/tasks" FATQ_RELAY_DIR="$TMPROOT/relay" FATQ_STATE_DIR="$TMPROOT/state"
    export FATQ_NOW_EPOCH=$BASE_EPOCH
    mkdir -p "$FATQ_STATE_DIR" "$TMPROOT/tasks/review"
    f="$TMPROOT/tasks/review/a34-real.json"
    echo '{"task_id":"a34-real","assigned":"anna","reviewer":"bella","history":[]}' > "$f"

    handle_dispatch_target "$f" "bella" "" "[FATQ 派工] 請審"

    relay_count=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$relay_count" == "1" ]] || { echo "    ✗ A34: 任務仍在 review/，應該正常派工，實得 relay_count=$relay_count"; exit 1; }
    hist_action=$(jq -r '.history[-1].action' "$f" 2>/dev/null)
    [[ "$hist_action" == "dispatch" ]] || { echo "    ✗ A34: history 應記一筆 dispatch，實得 $hist_action"; exit 1; }
    exit 0
  )
}

# ══════════════════════════════════════════════════════════════════════════
# f9c3 — done/ 完成通知（老兔 2026-07-08 診斷：派工有通知、完成沒通知的缺口）
# ══════════════════════════════════════════════════════════════════════════

# A35 — 回溯轟炸防呆：completion_notify_seeded marker 還不存在（這支 rule 第一次
# 跑）時，done/ 裡本來就堆著的舊任務（有 verdict_approve、無 completion_notified）
# 只補標記、絕不發 relay——deliverable 明講「done/ 歷史堆積的不回溯轟炸」。
test_A35() {
  local f="$FATQ_ROOT/done/20260701-0000-a35a-t1.json"
  make_task "$f" '{"task_id":"20260701-0000-a35a-t1","slug":"old-backlog","reviewer":"bella","created_by":"anya",
    "history":[{"ts":"2026-07-01T00:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_approve","from":"review/","to":"done/"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "0" ]] || fail "第一次跑（seed 模式）不該發 relay，卻發了 $(relay_count) 個" || return 1
  local last_action
  last_action=$(jq -r '.history[-1].action' "$f")
  [[ "$last_action" == "completion_notified" ]] || fail "應補上 completion_notified 標記，實得 $last_action" || return 1
  local note
  note=$(jq -r '.history[-1].note // ""' "$f")
  [[ "$note" == "backfill_seed_no_relay" ]] || fail "補標記應帶 backfill_seed_no_relay 註記，實得 note=$note" || return 1
  [[ -f "$FATQ_STATE_DIR/completion_notify_seeded" ]] || fail "seed marker 應該在第一輪跑完後建立" || return 1
  return 0
}

# A36 — seed marker 已存在（模擬 rule 已經運作過）時，done/ 裡「新完成」（有
# verdict_approve、無 completion_notified）的任務要真的收到一次 relay 通知 Anya。
test_A36() {
  mkdir -p "$FATQ_STATE_DIR"
  touch "$FATQ_STATE_DIR/completion_notify_seeded"
  local f="$FATQ_ROOT/done/20260708-0000-a36a-t1.json"
  make_task "$f" '{"task_id":"20260708-0000-a36a-t1","slug":"fresh-complete","reviewer":"bella","created_by":"anya",
    "history":[{"ts":"2026-07-08T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_approve","from":"review/","to":"done/"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "1" ]] || fail "seed marker 已存在時，新完成任務應該真的發一次 relay，實得 $(relay_count)" || return 1
  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "" ]] || fail "recipient 應留空（靠 @Anyachl_bot 常駐自撿），實得 $(jq -r '.recipient' "$rf")" || return 1
  echo "$(jq -r '.text' "$rf")" | grep -q "@Anyachl_bot" || fail "relay 文案應含 @Anyachl_bot" || return 1
  echo "$(jq -r '.text' "$rf")" | grep -q "fresh-complete" || fail "relay 文案應含 slug" || return 1
  local last_action
  last_action=$(jq -r '.history[-1].action' "$f")
  [[ "$last_action" == "completion_notified" ]] || fail "應記一筆 completion_notified，實得 $last_action" || return 1
  return 0
}

# A37 — 冪等：seed marker 已存在，同一個已通知過的任務連跑 3 輪 → relay 只 1 個，
# history 只多 1 筆（不重發）。
test_A37() {
  mkdir -p "$FATQ_STATE_DIR"
  touch "$FATQ_STATE_DIR/completion_notify_seeded"
  local f="$FATQ_ROOT/done/20260708-0000-a37a-t1.json"
  make_task "$f" '{"task_id":"20260708-0000-a37a-t1","slug":"idempotent-check","reviewer":"bella","created_by":"anya",
    "history":[{"ts":"2026-07-08T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_approve","from":"review/","to":"done/"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  run_dispatch
  run_dispatch
  [[ "$(relay_count)" == "1" ]] || fail "重複跑 3 輪 relay 應該還是 1，實得 $(relay_count)" || return 1
  [[ "$(history_len "$f")" == "2" ]] || fail "history 應該只有 2 筆(verdict_approve+completion_notified)，實得 $(history_len "$f")" || return 1
  return 0
}

# A38 — created_by 非 anya 且能映射到已知 bot → 額外補一份給建單者本人（可選功能）。
test_A38() {
  mkdir -p "$FATQ_STATE_DIR"
  touch "$FATQ_STATE_DIR/completion_notify_seeded"
  local f="$FATQ_ROOT/done/20260708-0000-a38a-t1.json"
  make_task "$f" '{"task_id":"20260708-0000-a38a-t1","slug":"creator-notify","reviewer":"bella","created_by":"sancai",
    "history":[{"ts":"2026-07-08T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_approve","from":"review/","to":"done/"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "2" ]] || fail "created_by=sancai（非 anya）應多發一份給建單者，relay 應該是 2，實得 $(relay_count)" || return 1
  local creator_relay
  creator_relay=$(grep -l "sancai" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$creator_relay" ]] || fail "找不到給建單者 sancai 的 relay 檔" || return 1
  return 0
}

# A39 — done/ 裡沒有 verdict_approve 的任務（人工搬入/舊格式）→ 完全跳過，不補
# 標記、不發 relay（不是這支 rule 的適用範圍，避免誤把非審批完成的任務當通知源）。
test_A39() {
  mkdir -p "$FATQ_STATE_DIR"
  touch "$FATQ_STATE_DIR/completion_notify_seeded"
  local f="$FATQ_ROOT/done/20260708-0000-a39a-t1.json"
  make_task "$f" '{"task_id":"20260708-0000-a39a-t1","slug":"no-verdict","history":[{"ts":"2026-07-08T10:00:00+08:00","by":"anya","action":"manual_close"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "0" ]] || fail "無 verdict_approve 的 done 任務不該發 relay，卻發了 $(relay_count) 個" || return 1
  [[ "$(history_len "$f")" == "1" ]] || fail "無 verdict_approve 不該補任何標記，history 應維持 1 筆，實得 $(history_len "$f")" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A40 — f7c1 核心：任務剛被 REJECT（history 帶真實 claim+verdict_reject，模擬
# b8f4 那種真實案例）→ 不必等 FATQ_STALE_SECS(2h)，同一輪 run_dispatch 就立刻
# 收到一個「退件重派」relay（非舊的 2h nudge 路徑），文案要點出 REJECT/修復。
# ══════════════════════════════════════════════════════════════════════════
test_A40() {
  local f="$FATQ_ROOT/rejected/20260705-0000-a40a-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a40a-t1","assigned":"anna","reviewer":"bella","history":[
    {"ts":"2026-07-02T21:16:40+08:00","by":"fatq-dispatch-cron","action":"dispatch","relay_file":"fatq-a40a-pending-a1-dispatch.json","target":"anna","attempt":1},
    {"ts":"2026-07-02T21:21:40+08:00","by":"anna","via":"fatq-cli","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-02T21:41:40+08:00","by":"anna","via":"fatq-cli","action":"submit","from":"in_progress/","to":"review/"},
    {"ts":"2026-07-02T21:45:40+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH   # 遠早於 FATQ_STALE_SECS 門檻，證明不是靠 2h nudge 觸發
  run_dispatch

  local dispatch_relays
  dispatch_relays=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  [[ "$dispatch_relays" == "1" ]] || fail "剛退件同一輪 builder 應立刻收到 1 個 dispatch relay（非等 2h），實得 $dispatch_relays" || return 1
  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | head -1)
  [[ "$(jq -r '.recipient' "$rf")" == "anna" ]] || fail "recipient 應為 anna，實得 $(jq -r '.recipient' "$rf")" || return 1
  echo "$rf" | grep -q "dispatch.json" || fail "relay 檔名應是 dispatch 類（複用 handle_dispatch_target），實得 $rf" || return 1
  local msg
  msg=$(jq -r '.text // .message // empty' "$rf")
  echo "$msg" | grep -q "REJECT" || fail "relay 文案應提到 REJECT，實得: $msg" || return 1
  local actions
  actions=$(history_actions "$f")
  [[ "$(echo "$actions" | tr ',' '\n' | grep -c '^dispatch$')" == "2" ]] || fail "history 應有 2 筆 dispatch(首派+退件重派)，實得 actions=$actions" || return 1
  [[ -f "$f" ]] || fail "task 檔仍應留在 rejected/（本腳本紅線：永不 mv）" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A41 — 冪等：同一張退件連跑 3 輪（無新的非 cron 活動）→ relay 仍只 1 個，
# 不因為每輪 cron/事件觸發就重派（防重派風暴）。
# ══════════════════════════════════════════════════════════════════════════
test_A41() {
  local f="$FATQ_ROOT/rejected/20260705-0000-a41a-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a41a-t1","assigned":"anna","reviewer":"bella","history":[
    {"ts":"2026-07-02T21:16:40+08:00","by":"fatq-dispatch-cron","action":"dispatch","relay_file":"fatq-a41a-pending-a1-dispatch.json","target":"anna","attempt":1},
    {"ts":"2026-07-02T21:45:40+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  run_dispatch
  run_dispatch
  local dispatch_relays
  dispatch_relays=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*dispatch.json' | wc -l | tr -d ' ')
  [[ "$dispatch_relays" == "1" ]] || fail "退件重派連跑 3 輪 builder dispatch relay 應仍是 1（冪等），實得 $dispatch_relays" || return 1
  local actions
  actions=$(history_actions "$f")
  [[ "$(echo "$actions" | tr ',' '\n' | grep -c '^dispatch$')" == "2" ]] || fail "history dispatch 筆數應維持 2（首派+退件重派各 1），不應每輪增加，實得 actions=$actions" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A42 — 二次催工保留：退件即時重派後，assignee 仍 2h 沒動作 → scan_dir_nudge
# 這條既有的 2h 催工路徑要照樣獨立觸發（即時派跟 2h 催工並存、互不覆蓋）。
# ══════════════════════════════════════════════════════════════════════════
test_A42() {
  local f="$FATQ_ROOT/rejected/20260705-0000-a42a-t1.json"
  make_task "$f" '{"task_id":"20260705-0000-a42a-t1","assigned":"anna","reviewer":"bella","history":[
    {"ts":"2026-07-02T21:16:40+08:00","by":"fatq-dispatch-cron","action":"dispatch","relay_file":"fatq-a42a-pending-a1-dispatch.json","target":"anna","attempt":1},
    {"ts":"2026-07-02T21:45:40+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch   # 即時重派（A40/A41 驗過的行為）
  consume_relay  # 模擬 gateway 已撿走，才輪得到 2h 後的 nudge 判斷（同 A3 手法）
  [[ "$(history_actions "$f")" == *"dispatch"* ]] || fail "前置：應先有即時重派的 dispatch 記錄" || return 1

  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))
  run_dispatch   # 2h 後仍無 assignee 活動 → 舊有 scan_dir_nudge("rejected") 該接手催工

  local actions
  actions=$(history_actions "$f")
  echo "$actions" | grep -q "nudge" || fail "2h 後應該還有 scan_dir_nudge 的 nudge 記錄，二次催工未失效，實得 actions=$actions" || return 1
  local nudge_relays
  nudge_relays=$(find "$FATQ_RELAY_DIR" -type f -name '*nudge.json' | wc -l | tr -d ' ')
  [[ "$nudge_relays" == "1" ]] || fail "應有 1 個 nudge relay 檔，實得 $nudge_relays" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A43 — pending/review 等既有派工路徑、completion_notified 不受影響（防這次
# 改動波及 scan_dir_dispatch 對其他目錄的行為，非只靠 A1-A39 全過反推）。
# ══════════════════════════════════════════════════════════════════════════
test_A43() {
  local fp="$FATQ_ROOT/pending/20260705-0000-a43a-t1.json"
  make_task "$fp" '{"task_id":"20260705-0000-a43a-t1","assigned":"anna"}'
  local fd="$FATQ_ROOT/done/20260705-0000-a43b-t1.json"
  touch "$FATQ_STATE_DIR/completion_notify_seeded"
  make_task "$fd" '{"task_id":"20260705-0000-a43b-t1","slug":"done-check","reviewer":"bella","created_by":"anya",
    "history":[{"ts":"2026-07-05T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_approve","from":"review/","to":"done/"}]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(relay_count)" == "2" ]] || fail "pending 首派(1)+done completion_notified(1)應共 2 個 relay，實得 $(relay_count)" || return 1
  local pending_relay done_relay
  pending_relay=$(jq -r 'select(.recipient=="anna")' "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$pending_relay" ]] || fail "pending 首派 relay 遺失，f7c1 這次改動不該波及既有 pending 派工路徑" || return 1
  local done_actions
  done_actions=$(history_actions "$fd")
  echo "$done_actions" | grep -q "completion_notified" || fail "done/ completion_notified 不該被 f7c1 這次改動波及，實得 actions=$done_actions" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A44 — 74c3：rejected/ 任務同步通知 Anya，內容含 REJECT 原因摘要與累計次數。
# ══════════════════════════════════════════════════════════════════════════
test_A44() {
  local f="$FATQ_ROOT/rejected/20260709-0000-a44a-t1.json"
  make_task "$f" '{"task_id":"20260709-0000-a44a-t1","slug":"reject-notify","assigned":"anna","reviewer":"bella","history":[
    {"ts":"2026-07-09T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"BLOCKER: first reject reason should be summarized for Anya without polling task files.","issue_type":"execution_error"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local anya_relay
  anya_relay=$(jq -r 'select(.recipient=="anya") | input_filename' "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$anya_relay" ]] || fail "應產生 recipient=anya 的 REJECT 通知 relay" || return 1
  [[ "$(basename "$anya_relay")" == *"-rejected-r1-reject-notify.json" ]] || fail "relay 檔名應含 phase=rejected 與 r1，實得 $(basename "$anya_relay")" || return 1

  local msg
  msg=$(jq -r '.text // empty' "$anya_relay")
  echo "$msg" | grep -q "累計第 1 次 REJECT" || fail "文案應含累計 REJECT 次數，實得: $msg" || return 1
  echo "$msg" | grep -q "first reject reason" || fail "文案應含原因摘要，實得: $msg" || return 1
  echo "$msg" | grep -q "issue_type：execution_error" || fail "文案應含 issue_type，實得: $msg" || return 1

  local actions
  actions=$(history_actions "$f")
  echo "$actions" | grep -q "reject_notified" || fail "history 應記 reject_notified，實得 actions=$actions" || return 1
  [[ "$(jq -r '.history[-1].reject_count // 0' "$f")" == "1" ]] || fail "reject_notified 應記 reject_count=1" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A45 — 74c3 冪等：同一 REJECT 重掃不重發；下一次 REJECT（累計數 +1）才再通知。
# ══════════════════════════════════════════════════════════════════════════
test_A45() {
  local f="$FATQ_ROOT/rejected/20260709-0000-a45a-t1.json"
  make_task "$f" '{"task_id":"20260709-0000-a45a-t1","slug":"reject-idempotent","assigned":"anna","reviewer":"bella","history":[
    {"ts":"2026-07-09T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"first reject"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  run_dispatch
  run_dispatch

  local reject_relays
  reject_relays=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*reject-notify.json' | wc -l | tr -d ' ')
  [[ "$reject_relays" == "1" ]] || fail "同一 REJECT 重掃只應有 1 個 reject-notify relay，實得 $reject_relays" || return 1
  [[ "$(jq -r '[.history[] | select(.action=="reject_notified")] | length' "$f")" == "1" ]] || fail "同一 REJECT 只應寫 1 筆 reject_notified" || return 1

  jq '.history += [
    {"ts":"2026-07-09T10:10:00+08:00","by":"anna","via":"fatq-cli","action":"claim","from":"rejected/","to":"in_progress/"},
    {"ts":"2026-07-09T10:20:00+08:00","by":"anna","via":"fatq-cli","action":"submit","from":"in_progress/","to":"review/"},
    {"ts":"2026-07-09T10:30:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"second reject"}
  ]' "$f" > "$TMPROOT/a45.tmp" && mv "$TMPROOT/a45.tmp" "$f"
  run_dispatch

  reject_relays=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*reject-notify.json' | wc -l | tr -d ' ')
  [[ "$reject_relays" == "2" ]] || fail "第二次 REJECT 應再產生第 2 個 reject-notify relay，實得 $reject_relays" || return 1
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*-rejected-r2-reject-notify.json' | grep -q . || fail "第二次通知 relay 檔名應含 r2" || return 1
  [[ "$(jq -r '[.history[] | select(.action=="reject_notified")] | length' "$f")" == "2" ]] || fail "兩次 REJECT 應有 2 筆 reject_notified" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A46 — archived/ 不是 dispatch 掃描目錄：不派工、不催工、不 completion notify
# ══════════════════════════════════════════════════════════════════════════
test_A46() {
  local f="$FATQ_ROOT/archived/20260711-0000-a46a-archived.json"
  make_task "$f" '{"task_id":"20260711-0000-a46a-archived","assigned":"anna","reviewer":"bella","status":"wont_do","history":[
    {"ts":"2026-07-11T07:00:00+08:00","by":"anya","via":"fatq-cli","action":"archive","from":"wont_do/","to":"archived/"}
  ]}'
  local before
  before=$(jq -c '.history' "$f")
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  [[ "$(relay_count)" == "0" ]] || fail "archived/ should not produce relay, got $(relay_count)" || return 1
  [[ "$(jq -c '.history' "$f")" == "$before" ]] || fail "archived/ history should be untouched by dispatch" || return 1
  if grep -q "20260711-0000-a46a-archived" "$TMPROOT/dispatch.log"; then
    fail "dispatch log should not mention archived task" || return 1
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A47 — b4f7：stale rejected path 投遞前重驗；任務已在其他狀態時不投舊 relay。
# ══════════════════════════════════════════════════════════════════════════
test_A47() {
  local stale="$FATQ_ROOT/rejected/stale-reject-copy.json"
  local current="$FATQ_ROOT/done/20260712-0000-a47a-stale.json"
  make_task "$stale" '{"task_id":"20260712-0000-a47a-stale","slug":"stale-reject-relay","assigned":"anna","reviewer":"bella","status":"rejected","history":[
    {"ts":"2026-07-12T01:20:00+08:00","by":"bella","action":"verdict_reject","reason":"old reject"}
  ]}'
  make_task "$current" '{"task_id":"20260712-0000-a47a-stale","slug":"stale-reject-relay","assigned":"anna","reviewer":"bella","status":"done","history":[
    {"ts":"2026-07-12T01:30:00+08:00","by":"bella","action":"approve","from":"review/","to":"done/"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a47a*' | wc -l | tr -d ' ')" == "0" ]] || fail "stale rejected copy must not produce relay" || return 1
  [[ "$(history_actions "$stale")" == "verdict_reject" ]] || fail "stale rejected copy history must stay untouched, got $(history_actions "$stale")" || return 1
  grep -q "20260712-0000-a47a-stale decision=skip:moved" "$TMPROOT/dispatch.log" || fail "stale rejected copy should be logged as skip:moved" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A48 — b4f7：spec_amend/spec staleness 後的 nudge 內嵌「spec 已變更」旗標。
# ══════════════════════════════════════════════════════════════════════════
test_A48() {
  local f="$FATQ_ROOT/in_progress/20260712-0000-a48a-specflag.json"
  make_task "$f" '{"task_id":"20260712-0000-a48a-specflag","slug":"spec-amend-nudge-flag","assigned":"anna","reviewer":"bella","status":"in_progress","history":[
    {"ts":"2026-07-02T19:40:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-02T19:41:00+08:00","by":"fatq-watch","action":"spec_staleness_notified","changed_fields":["context"]}
  ]}'
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))
  run_dispatch

  local nudge_relay msg
  nudge_relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a48a*nudge.json' | head -1)"
  [[ -n "$nudge_relay" ]] || fail "spec-amended in_progress task should produce a nudge relay" || return 1
  msg="$(jq -r '.text // empty' "$nudge_relay")"
  echo "$msg" | grep -q "spec 已變更" || fail "nudge should include spec changed flag, got: $msg" || return 1
  echo "$msg" | grep -q "重讀任務檔" || fail "nudge should tell assignee to reread task file, got: $msg" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A49 — 1ea1：最後一筆 history=blocked 且標明外部依賴 → 例行 nudge skip + audit。
# ══════════════════════════════════════════════════════════════════════════
test_A49() {
  local f="$FATQ_ROOT/in_progress/20260713-0000-a49a-blocked-external.json"
  make_task "$f" '{"task_id":"20260713-0000-a49a-blocked-external","slug":"blocked-external","assigned":"anna","reviewer":"bella","status":"in_progress","last_run_summary":"blocked-on-external: codex sandbox has no network; needs production-runner and Cloudflare credentials","history":[
    {"ts":"2026-07-02T19:40:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-02T19:45:00+08:00","by":"anna","action":"blocked","note":"Waiting for production runner/manual credential step"}
  ]}'
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))
  run_dispatch

  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a49a*' | wc -l | tr -d ' ')" == "0" ]] || fail "blocked-on-external task must not produce nudge relay" || return 1
  [[ "$(history_actions "$f")" == "claim,blocked" ]] || fail "blocked-on-external task history must stay unchanged, got $(history_actions "$f")" || return 1
  grep -q "20260713-0000-a49a-blocked-external decision=skip:blocked_on_external" "$TMPROOT/dispatch.log" || fail "dispatch log should record blocked_on_external skip" || return 1
  local day audit_file
  day="$(TZ='Asia/Taipei' date -d "@$FATQ_NOW_EPOCH" '+%Y-%m-%d')"
  audit_file="$FATQ_STATE_DIR/nudge-skip-audit-${day}.log"
  grep -q "task=20260713-0000-a49a-blocked-external reason=blocked_on_external" "$audit_file" || fail "blocked skip should be visible in daily audit" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A50 — 1ea1：blocked 後有新 comment/relay → 不再視為 blocked，下一輪恢復 nudge。
# ══════════════════════════════════════════════════════════════════════════
test_A50() {
  local f="$FATQ_ROOT/in_progress/20260713-0000-a50a-comment-resumes.json"
  make_task "$f" '{"task_id":"20260713-0000-a50a-comment-resumes","slug":"comment-resumes","assigned":"anna","reviewer":"bella","status":"in_progress","last_run_summary":"previously blocked-on-external: no network","history":[
    {"ts":"2026-07-02T19:40:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-02T19:45:00+08:00","by":"anna","action":"blocked","note":"Waiting for production runner"},
    {"ts":"2026-07-02T20:00:00+08:00","by":"anya","action":"comment","note":"Production runner evidence attached; please continue"}
  ]}'
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 100))
  run_dispatch

  local nudge_relay
  nudge_relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a50a*nudge.json' | head -1)"
  [[ -n "$nudge_relay" ]] || fail "new comment after blocked should resume normal nudge" || return 1
  [[ "$(jq -r '.recipient' "$nudge_relay")" == "anna" ]] || fail "resumed nudge should target anna, got $(jq -r '.recipient' "$nudge_relay")" || return 1
  grep -q "20260713-0000-a50a-comment-resumes decision=nudge" "$TMPROOT/dispatch.log" || fail "dispatch log should record resumed nudge" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A51 — 1ea1：每單每日 nudge 上限 2 次；第 3 次改 audit，不發 relay。
# ══════════════════════════════════════════════════════════════════════════
test_A51() {
  local day n1 n2
  export FATQ_NOW_EPOCH=$((BASE_EPOCH + FATQ_STALE_SECS + 6*3600))
  day="$(TZ='Asia/Taipei' date -d "@$FATQ_NOW_EPOCH" '+%Y-%m-%d')"
  n1="${day}T09:00:00+08:00"
  n2="${day}T11:30:00+08:00"
  local f="$FATQ_ROOT/in_progress/20260713-0000-a51a-daily-cap.json"
  make_task "$f" "{\"task_id\":\"20260713-0000-a51a-daily-cap\",\"slug\":\"daily-cap\",\"assigned\":\"anna\",\"reviewer\":\"bella\",\"status\":\"in_progress\",\"history\":[
    {\"ts\":\"2026-07-02T19:40:00+08:00\",\"by\":\"anna\",\"action\":\"claim\",\"from\":\"pending/\",\"to\":\"in_progress/\"},
    {\"ts\":\"$n1\",\"by\":\"fatq-dispatch-cron\",\"action\":\"nudge\",\"relay_file\":\"fatq-a51a-in_progress-a1-nudge.json\",\"target\":\"anna\"},
    {\"ts\":\"$n2\",\"by\":\"fatq-dispatch-cron\",\"action\":\"nudge\",\"relay_file\":\"fatq-a51a-in_progress-a2-nudge.json\",\"target\":\"anna\"}
  ]}"
  run_dispatch

  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*a51a*' | wc -l | tr -d ' ')" == "0" ]] || fail "daily cap should suppress 3rd nudge relay" || return 1
  [[ "$(history_actions "$f")" == "claim,nudge,nudge" ]] || fail "daily cap should not append a 3rd nudge, got $(history_actions "$f")" || return 1
  grep -q "20260713-0000-a51a-daily-cap decision=skip:daily_nudge_limit" "$TMPROOT/dispatch.log" || fail "dispatch log should record daily cap skip" || return 1
  local audit_file="$FATQ_STATE_DIR/nudge-skip-audit-${day}.log"
  grep -q "task=20260713-0000-a51a-daily-cap reason=daily_nudge_limit" "$audit_file" || fail "daily cap skip should be visible in daily audit" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A52 — 0253：終態 done/ 的舊 schema 合法 JSON 靜默 skip，不刷 invalid-json WARN。
# ══════════════════════════════════════════════════════════════════════════
test_A52() {
  local f="$FATQ_ROOT/done/legacy-old-schema.json"
  local f2="$FATQ_ROOT/done/legacy-old-schema-no-id.json"
  cat > "$f" <<'EOF'
{
  "id": "legacy-old-schema",
  "title": "Old schema done task",
  "description": "Historical terminal task from before task_id became mandatory.",
  "assignee": "anna",
  "labels": ["legacy"]
}
EOF
  cat > "$f2" <<'EOF'
{
  "title": "Older schema done task without id",
  "spec": "Historical task variant that predates task_id and id.",
  "assigned_to": "anna",
  "status": "done"
}
EOF
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  ! grep -q "WARN invalid task json, skip: $f" "$TMPROOT/dispatch.log" || fail "terminal old-schema done task should not emit invalid-json WARN" || return 1
  ! grep -q "WARN invalid task json, skip: $f2" "$TMPROOT/dispatch.log" || fail "terminal old-schema done task without id should not emit invalid-json WARN" || return 1
  [[ "$(relay_count)" == "0" ]] || fail "terminal old-schema done task should not produce relay, got $(relay_count)" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A53 — 0253：活躍目錄缺 task_id 仍 WARN，不能被舊 schema 靜音規則吞掉。
# ══════════════════════════════════════════════════════════════════════════
test_A53() {
  local f="$FATQ_ROOT/pending/legacy-active-missing-task-id.json"
  cat > "$f" <<'EOF'
{
  "id": "legacy-active-missing-task-id",
  "title": "Active invalid task",
  "assignee": "anna"
}
EOF
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  grep -q "WARN invalid task json, skip: $f" "$TMPROOT/dispatch.log" || fail "active missing-task_id task must still emit invalid-json WARN" || return 1
  [[ "$(relay_count)" == "0" ]] || fail "invalid active task should not produce relay, got $(relay_count)" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A54 — 0253：終態目錄的壞 JSON 仍 WARN，只靜音可解析的舊 schema。
# ══════════════════════════════════════════════════════════════════════════
test_A54() {
  local f="$FATQ_ROOT/done/broken-json.json"
  printf '{"id":"broken-json","title":"Broken"\n' > "$f"
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  grep -q "WARN invalid task json, skip: $f" "$TMPROOT/dispatch.log" || fail "broken JSON in terminal dir must still emit invalid-json WARN" || return 1
  [[ "$(relay_count)" == "0" ]] || fail "broken terminal JSON should not produce relay, got $(relay_count)" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A55 — 35e2：reject-notify 在本輪 verdict_reject 沒有 reason/note 時，
# 才 fallback 到 review.findings，且真實陣列 schema 要格式化成人可讀摘要。
# ══════════════════════════════════════════════════════════════════════════
test_A55() {
  local f="$FATQ_ROOT/rejected/20260713-0000-a55a-review-findings.json"
  make_task "$f" '{"task_id":"20260713-0000-a55a-review-findings","slug":"review-findings","assigned":"anna","reviewer":"bella",
    "review":{"findings":[{"dimension":"seed boolean one-shot regression","status":"BLOCKER","detail":"review.findings array should be summarized as readable text, not raw JSON."}],"fix_required":"repair fixture"},
    "history":[
      {"ts":"2026-07-13T09:10:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","issue_type":"execution_error"}
    ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local anya_relay msg
  anya_relay=$(jq -r 'select(.recipient=="anya") | input_filename' "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$anya_relay" ]] || fail "A55: 應產生 recipient=anya 的 REJECT 通知 relay" || return 1
  msg=$(jq -r '.text // empty' "$anya_relay")
  echo "$msg" | grep -q "\\[BLOCKER\\] seed boolean one-shot regression: review.findings array should be summarized" || fail "A55: 文案應格式化 review.findings 陣列，實得: $msg" || return 1
  ! echo "$msg" | grep -Fq '[{"dimension"' || fail "A55: 不得輸出原始 findings JSON，實得: $msg" || return 1
  ! echo "$msg" | grep -q "<未填>" || fail "A55: review.findings 存在時不得顯示 <未填>，實得: $msg" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A56 — 35e2：同時存在舊輪 review.findings 與本輪 verdict_reject.reason
# 時，通知摘要必須取本輪 history reason，避免跨輪引用 task 級單例欄位。
# ══════════════════════════════════════════════════════════════════════════
test_A56() {
  local f="$FATQ_ROOT/rejected/20260713-0000-a56a-current-verdict-reason.json"
  make_task "$f" '{"task_id":"20260713-0000-a56a-current-verdict-reason","slug":"current-verdict-reason","assigned":"anna","reviewer":"bella",
    "review":{"findings":[{"dimension":"old stale review finding","status":"BLOCKER","detail":"must not appear when current verdict reason exists"}]},
    "history":[
      {"ts":"2026-07-13T09:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"first round old reason","issue_type":"execution_error"},
      {"ts":"2026-07-13T09:30:00+08:00","by":"anna","action":"claim","from":"rejected/","to":"in_progress/"},
      {"ts":"2026-07-13T09:45:00+08:00","by":"anna","action":"submit","from":"in_progress/","to":"review/"},
      {"ts":"2026-07-13T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"current round readable blocker reason","issue_type":"execution_error"}
    ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local anya_relay msg
  anya_relay=$(jq -r 'select(.recipient=="anya") | input_filename' "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$anya_relay" ]] || fail "A56: 應產生 recipient=anya 的 REJECT 通知 relay" || return 1
  msg=$(jq -r '.text // empty' "$anya_relay")
  echo "$msg" | grep -q "current round readable blocker reason" || fail "A56: 文案應讀本輪 verdict_reject.reason，實得: $msg" || return 1
  ! echo "$msg" | grep -q "old stale review finding" || fail "A56: 不得優先顯示舊輪 review.findings，實得: $msg" || return 1
  ! echo "$msg" | grep -q "first round old reason" || fail "A56: 不得回退到舊輪 history reason，實得: $msg" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A57 — 35e2：issue_type 也必須優先讀本輪 verdict_reject，
# 避免舊輪 task 級 review.issue_type 覆蓋本輪真值。
# ══════════════════════════════════════════════════════════════════════════
test_A57() {
  local f="$FATQ_ROOT/rejected/20260713-0000-a57a-current-issue-type.json"
  make_task "$f" '{"task_id":"20260713-0000-a57a-current-issue-type","slug":"current-issue-type","assigned":"anna","reviewer":"bella",
    "review":{"issue_type":"execution_error","findings":[{"dimension":"stale issue type","status":"BLOCKER","detail":"old review issue_type must not override current verdict issue_type"}]},
    "history":[
      {"ts":"2026-07-13T09:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","reason":"first round old reason","issue_type":"execution_error"},
      {"ts":"2026-07-13T09:30:00+08:00","by":"anna","action":"claim","from":"rejected/","to":"in_progress/"},
      {"ts":"2026-07-13T09:45:00+08:00","by":"anna","action":"submit","from":"in_progress/","to":"review/"},
      {"ts":"2026-07-13T10:00:00+08:00","by":"bella","via":"fatq-cli","action":"verdict_reject","from":"review/","to":"rejected/","issue_type":"spec_conflict"}
    ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local anya_relay msg
  anya_relay=$(jq -r 'select(.recipient=="anya") | input_filename' "$FATQ_RELAY_DIR"/*.json 2>/dev/null | head -1)
  [[ -n "$anya_relay" ]] || fail "A57: 應產生 recipient=anya 的 REJECT 通知 relay" || return 1
  msg=$(jq -r '.text // empty' "$anya_relay")
  echo "$msg" | grep -q "issue_type：spec_conflict" || fail "A57: issue_type 應讀本輪 verdict_reject.issue_type，實得: $msg" || return 1
  ! echo "$msg" | grep -q "issue_type：execution_error" || fail "A57: 不得讀舊輪 review.issue_type，實得: $msg" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# A58-A61（b8e8）：[BLOCKED-AUTH] 即時通知 Anya，history durable 去重。
# ══════════════════════════════════════════════════════════════════════════
test_A58() {
  local f="$FATQ_ROOT/in_progress/20260716-0000-a58a-blocked-auth.json"
  make_task "$f" '{"task_id":"20260716-0000-a58a-blocked-auth","slug":"blocked-auth","assigned":"anna","status":"in_progress","history":[
    {"ts":"2026-07-16T09:00:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-16T09:05:00+08:00","by":"anna","action":"blocked","note":"[BLOCKED-AUTH] patch ready at /tmp/fix.patch; Anya needs to apply on a branch"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local rf
  rf=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*blocked-auth.json' | head -1)
  [[ -n "$rf" ]] || fail "A58: [BLOCKED-AUTH] should create blocked-auth relay" || return 1
  [[ "$(jq -r '.recipient' "$rf")" == "anya" ]] || fail "A58: relay recipient should be internal name anya, got $(jq -r '.recipient' "$rf")" || return 1
  grep -q "patch ready at /tmp/fix.patch" "$rf" || fail "A58: relay text should include demand line" || return 1
  grep -q "@Anyachl_bot" "$rf" || fail "A58: relay text should keep human-readable Anya handle" || return 1
  [[ "$(jq '[.history[] | select(.action=="blocked_auth_notified")] | length' "$f")" == "1" ]] || fail "A58: history should record blocked_auth_notified" || return 1
  [[ "$(jq -r '.history[] | select(.action=="blocked_auth_notified") | .target' "$f")" == "anya" ]] || fail "A58: history target should be internal name anya" || return 1
  return 0
}

test_A59() {
  local f="$FATQ_ROOT/in_progress/20260716-0000-a59a-no-marker.json"
  make_task "$f" '{"task_id":"20260716-0000-a59a-no-marker","slug":"no-marker","assigned":"anna","status":"in_progress","history":[
    {"ts":"2026-07-16T09:00:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-16T09:05:00+08:00","by":"anna","action":"blocked","note":"Patch ready but marker intentionally absent"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*blocked-auth.json' | wc -l | tr -d ' ')" == "0" ]] || fail "A59: unmarked blocked task must not notify Anya" || return 1
  [[ "$(jq '[.history[] | select(.action=="blocked_auth_notified")] | length' "$f")" == "0" ]] || fail "A59: unmarked blocked task must not append notified marker" || return 1
  return 0
}

test_A60() {
  local f="$FATQ_ROOT/in_progress/20260716-0000-a60a-dedup.json"
  make_task "$f" '{"task_id":"20260716-0000-a60a-dedup","slug":"dedup","assigned":"anna","status":"in_progress","history":[
    {"ts":"2026-07-16T09:00:00+08:00","by":"anna","action":"claim","from":"pending/","to":"in_progress/"},
    {"ts":"2026-07-16T09:05:00+08:00","by":"anna","action":"blocked","note":"[BLOCKED-AUTH] apply /tmp/dedup.patch"}
  ]}'
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch
  run_dispatch
  run_dispatch

  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*blocked-auth.json' | wc -l | tr -d ' ')" == "1" ]] || fail "A60: same blocked event should notify once" || return 1
  [[ "$(jq '[.history[] | select(.action=="blocked_auth_notified")] | length' "$f")" == "1" ]] || fail "A60: same blocked event should have one durable marker" || return 1

  local tmp; tmp=$(mktemp)
  jq '.history += [{"ts":"2026-07-16T09:20:00+08:00","by":"anna","action":"blocked","note":"[BLOCKED-AUTH] second auth action needed"}]' "$f" > "$tmp" && mv "$tmp" "$f"
  run_dispatch
  [[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*blocked-auth.json' | wc -l | tr -d ' ')" == "2" ]] || fail "A60: new [BLOCKED-AUTH] event should notify again" || return 1
  [[ "$(jq '[.history[] | select(.action=="blocked_auth_notified")] | length' "$f")" == "2" ]] || fail "A60: new event should get its own marker" || return 1
  return 0
}

test_A61() {
  local f="$FATQ_ROOT/done/legacy-blocked-auth-old-schema.json"
  cat > "$f" <<'EOF'
{
  "id": "legacy-blocked-auth-old-schema",
  "title": "Old schema terminal task mentioning [BLOCKED-AUTH]",
  "status": "done",
  "history": [{"action": "blocked", "note": "[BLOCKED-AUTH] historical text only"}]
}
EOF
  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  ! grep -q "WARN invalid task json, skip: $f" "$TMPROOT/dispatch.log" || fail "A61: terminal old schema should be silent" || return 1
  [[ "$(relay_count)" == "0" ]] || fail "A61: terminal old schema should not produce relay, got $(relay_count)" || return 1
  return 0
}

# ═════════════════════════════════════════════════════════════════════════
# A62（a588 regression）— review 首派被 gateway 歸檔後，任務經
# review→rejected→in_progress→review 再送。attempt 依原設計重算為 1，
# 但持久 history 推導的 dispatch sequence 必須使新 relay 檔名不同；
# 舊檔留在 read/ 模擬 relay-dedup read-archive，新檔仍要出現在 relay/ 供投遞。
# ═════════════════════════════════════════════════════════════════════════
test_A62() {
  local tid="20260719-2129-a588-review-resubmit"
  local f_review="$FATQ_ROOT/review/${tid}.json"
  make_task "$f_review" "{\"task_id\":\"$tid\",\"status\":\"review\",\"assigned\":\"anna\",\"reviewer\":\"bella\",\"history\":[{\"ts\":\"2026-07-19T14:13:55+08:00\",\"by\":\"anna\",\"action\":\"submit\",\"from\":\"in_progress/\",\"to\":\"review/\"}]}"

  export FATQ_NOW_EPOCH=$BASE_EPOCH
  run_dispatch

  local first_relay first_name
  first_relay=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ -n "$first_relay" ]] || fail "A62: first review dispatch did not create relay" || return 1
  first_name=$(basename "$first_relay")
  [[ "$first_name" == *"-review-d1-a1-dispatch.json" ]] || fail "A62: first review filename missing durable d1 sequence: $first_name" || return 1
  consume_relay
  [[ -f "$FATQ_RELAY_DIR/read/$first_name" ]] || fail "A62: first relay was not preserved in read archive" || return 1

  # 完整模擬 28b9 的 reject/resubmit 狀態循環，不是只在 review/ 內追加一筆快樂路徑活動。
  local tmp f_rejected f_progress
  tmp=$(mktemp)
  jq '.status="rejected" | .history += [{"ts":"2026-07-19T14:22:43+08:00","by":"bella","action":"verdict_reject","from":"review/","to":"rejected/"}]' "$f_review" > "$tmp"
  f_rejected="$FATQ_ROOT/rejected/${tid}.json"
  mv "$tmp" "$f_rejected"
  rm_moved_pending_fixture "$f_review"

  tmp=$(mktemp)
  jq '.status="in_progress" | .history += [{"ts":"2026-07-19T14:24:43+08:00","by":"anna","action":"claim","from":"rejected/","to":"in_progress/"}]' "$f_rejected" > "$tmp"
  f_progress="$FATQ_ROOT/in_progress/${tid}.json"
  mv "$tmp" "$f_progress"
  rm_moved_pending_fixture "$f_rejected"

  tmp=$(mktemp)
  jq '.status="review" | .history += [{"ts":"2026-07-19T19:15:35+08:00","by":"anna","action":"submit","from":"in_progress/","to":"review/"}]' "$f_progress" > "$tmp"
  mv "$tmp" "$f_review"
  rm_moved_pending_fixture "$f_progress"

  export FATQ_NOW_EPOCH=$((BASE_EPOCH + 100))
  run_dispatch

  local second_relay second_name
  second_relay=$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)
  [[ -n "$second_relay" ]] || fail "A62: resubmit was silently lost while old filename remained archived" || return 1
  second_name=$(basename "$second_relay")
  [[ "$second_name" == *"-review-d2-a1-dispatch.json" ]] || fail "A62: resubmit filename missing monotonic d2 sequence: $second_name" || return 1
  [[ "$first_name" != "$second_name" ]] || fail "A62: reject→resubmit reused archived filename: $first_name" || return 1
  [[ "$(jq -r '.recipient' "$second_relay")" == "bella" ]] || fail "A62: resubmit relay not deliverable to bella" || return 1
  [[ "$(jq -r '[.history[] | select(.by=="fatq-dispatch-cron" and .action=="dispatch")] | last | [.attempt,.dispatch_seq] | @tsv' "$f_review")" == $'1\t2' ]] || fail "A62: resubmit history must retain attempt=1 and durable dispatch_seq=2" || return 1
  [[ "$(find "$FATQ_RELAY_DIR/read" -maxdepth 1 -type f -name "$first_name" | wc -l | tr -d ' ')" == "1" ]] || fail "A62: existing read-archive entry was altered" || return 1
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
         A20 A21 A22 A23 A24 A25 A26 A27 A28 A29 A30 A31 A32 A33 A34 \
         A35 A36 A37 A38 A39 A40 A41 A42 A43 A44 A45 A46 A47 A48 A49 A50 A51 \
         A52 A53 A54 A55 A56 A57 A58 A59 A60 A61 A62; do
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

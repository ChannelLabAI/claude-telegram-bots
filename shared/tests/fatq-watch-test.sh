#!/usr/bin/env bash
# fatq-watch-test.sh — fixture tests for shared/bin/fatq-watch.sh
#
# Spec §deliverables (handover/fatq-dispatch-cron-spec-20260705.md 系列 /
# tasks/{in_progress,done}/20260705-1425-a9f3-fatq-event-driven-dispatch.json):
#   ①事件→dispatch 延遲<60s ②風暴測試 ③監聽器重啟後 cron 保底補派
#
# 全部用 mktemp -d 隔離 fixture，從不對真實 tasks/ 斷言（見
# feedback_closed_loop_test_fixture）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_SH="$SCRIPT_DIR/../bin/fatq-watch.sh"
DISPATCH_SH="$SCRIPT_DIR/../bin/fatq-dispatch.sh"

TOTAL_PASS=0
TOTAL_FAIL=0
FAIL_NAMES=()

setup() {
  TMPROOT=$(mktemp -d)
  export FATQ_ROOT="$TMPROOT/tasks"
  export FATQ_RELAY_DIR="$TMPROOT/relay"
  export FATQ_STATE_DIR="$TMPROOT/state"
  export FATQ_MATTERMOST_DISABLE=1
  export FATQ_WATCH_LOG="$TMPROOT/fatq-watch.log"
  export FATQ_WATCH_DEBOUNCE_SECS=2
  export FATQ_WATCH_SKIP_INITIAL_DISPATCH=1
  export FATQ_DISPATCH_SH="$DISPATCH_SH"
  export FATQ_DISPATCH_LOCK="$TMPROOT/test.lock"  # 專屬臨時鎖，避免撞真實生產 cron 的 /tmp/cron-fatq-dispatch.lock（Bella a9f3 REJECT 根因）
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,done,cancelled,wont_do,design,design_review,spec_review,reviews,proposals}
  mkdir -p "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"
}

teardown() {
  if [[ -n "${WATCHER_PID:-}" ]]; then
    # fatq-watch.sh 內部是 inotifywait | while 的 pipeline，各自獨立 process；
    # 單純 kill 主 PID 殺不掉 pipeline 裡的 inotifywait 子進程（會變殭屍繼續跑），
    # 必須用 job control 起的 process group 整組砍（kill -- -PID，見 start_watcher 註解）。
    kill -TERM -- -"$WATCHER_PID" 2>/dev/null || kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    unset WATCHER_PID
  fi
  rm -rf "$TMPROOT"
}

make_task() {
  local path="$1" overrides="$2"
  jq -n --argjson ov "$overrides" \
    '{task_id: "override-me", slug: "t", status: "pending", history: []} * $ov' \
    > "$path"
}

start_watcher() {
  # 用 job control（set -m）讓背景 pipeline（bash 腳本 + inotifywait 子進程）
  # 自成一個 process group，$! 拿到的就是該 group 的 leader pid，才能用
  # kill -- -PID 整組砍乾淨。⚠️ 不能用「setsid CMD &」：setsid 內部會再 fork
  # 一次才 exec 真正的程式，$! 拿到的是那個轉瞬即逝的殼進程 pid，不是實際
  # 長駐的 watcher pid——砍它等於砍空氣，inotifywait 子進程會變孤兒繼續跑
  # （實測踩過這個坑）。
  set -m
  bash "$WATCH_SH" >>"$TMPROOT/watcher-stdout.log" 2>&1 &
  WATCHER_PID=$!
  set +m
  sleep 0.5   # 讓 inotifywait 掛好監聽再開始丟檔案
}

stop_watcher() {
  if [[ -n "${WATCHER_PID:-}" ]]; then
    # fatq-watch.sh 內部是 inotifywait | while 的 pipeline，各自獨立 process；
    # 單純 kill 主 PID 殺不掉 pipeline 裡的 inotifywait 子進程（會變殭屍繼續跑），
    # 必須用 job control 起的 process group 整組砍（kill -- -PID，見 start_watcher 註解）。
    kill -TERM -- -"$WATCHER_PID" 2>/dev/null || kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    unset WATCHER_PID
  fi
}

relay_count() {
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

fail() {
  echo "    ✗ $*"
  return 1
}

# ══════════════════════════════════════════════════════════════════════════
# W1 — 事件 → dispatch 延遲 <60s
# ══════════════════════════════════════════════════════════════════════════
test_W1() {
  start_watcher

  local tid="20260705-0000-w1w1-t1"
  make_task "$FATQ_ROOT/pending/${tid}.json" "{\"task_id\":\"$tid\",\"assigned\":\"anna\"}"

  local waited=0
  while [[ "$(relay_count)" -eq 0 && "$waited" -lt 60 ]]; do
    sleep 1
    waited=$((waited+1))
  done

  stop_watcher

  [[ "$(relay_count)" -ge 1 ]] || fail "60 秒內沒有產生 relay 派工（實際等了 ${waited}s）" || return 1
  echo "    (實際延遲約 ${waited}s)"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# W2 — 風暴測試：同時丟 10 個任務檔 → 有限次呼叫、每任務恰派 1 次
# ══════════════════════════════════════════════════════════════════════════
test_W2() {
  start_watcher

  local i tid
  for i in $(seq 1 10); do
    tid="20260705-0000-w2w2-t${i}"
    make_task "$FATQ_ROOT/pending/${tid}.json" "{\"task_id\":\"$tid\",\"assigned\":\"anna\"}"
  done

  # 等 debounce 視窗(2s) + 緩衝，讓合併後的單次 dispatch 執行完
  sleep 6

  stop_watcher

  local scan_count
  scan_count=$(grep -c "scan start" "$TMPROOT/fatq-watch-dispatch.log" 2>/dev/null || echo 0)
  [[ "$scan_count" -ge 1 && "$scan_count" -le 3 ]] || fail "預期 dispatch 呼叫次數在 1-3 次之間（debounce 有效合併），實際 ${scan_count} 次" || return 1

  local i tid dispatch_entries
  for i in $(seq 1 10); do
    tid="20260705-0000-w2w2-t${i}"
    dispatch_entries=$(jq '[.history[] | select(.action=="dispatch")] | length' "$FATQ_ROOT/pending/${tid}.json" 2>/dev/null)
    [[ "$dispatch_entries" == "1" ]] || fail "task ${tid} 應該恰好派工 1 次，實際 ${dispatch_entries} 次" || return 1
  done

  local relay_files_for_tasks
  relay_files_for_tasks=$(grep -l "w2w2" "$FATQ_RELAY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [[ "$relay_files_for_tasks" == "10" ]] || fail "預期 10 個任務各自 1 個 relay 檔，實際找到 ${relay_files_for_tasks} 個含 w2w2 內容的檔" || return 1

  echo "    (dispatch 呼叫 ${scan_count} 次，涵蓋 10 個任務全數恰派 1 次)"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# W3 — 監聽器重啟後，cron 保底補派（模擬監聽器離線期間掉的事件由巡迴撿回）
# ══════════════════════════════════════════════════════════════════════════
test_W3() {
  start_watcher
  sleep 1
  stop_watcher   # 模擬監聽器崩潰/重啟中，此刻沒有任何東西在監聽

  local tid="20260705-0000-w3w3-t1"
  make_task "$FATQ_ROOT/pending/${tid}.json" "{\"task_id\":\"$tid\",\"assigned\":\"anna\"}"

  sleep 3   # 監聽器離線期間，這個事件不會被任何人接住
  [[ "$(relay_count)" -eq 0 ]] || fail "監聽器已停止，不應該有任何 relay 產生" || return 1

  # 模擬 cron 保底巡迴：直接呼叫 fatq-dispatch.sh（不透過 watcher）
  bash "$DISPATCH_SH" >/dev/null 2>&1

  [[ "$(relay_count)" -ge 1 ]] || fail "cron 保底巡迴應該要補派這個任務，但沒有產生 relay" || return 1
  local dispatch_entries
  dispatch_entries=$(jq '[.history[] | select(.action=="dispatch")] | length' "$FATQ_ROOT/pending/${tid}.json" 2>/dev/null)
  [[ "$dispatch_entries" == "1" ]] || fail "cron 保底補派後應該恰好 1 筆 dispatch 記錄，實際 ${dispatch_entries}" || return 1
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

for t in W1 W2 W3; do
  run_test "$t"
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-watch-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail (of $((TOTAL_PASS+TOTAL_FAIL)))"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-watch-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
echo "[fatq-watch-test] All cases passed ✅"
exit 0

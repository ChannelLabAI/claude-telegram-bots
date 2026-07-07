#!/usr/bin/env bash
# fatq-deploy-gate-test.sh — fixture tests for shared/bin/fatq-deploy-gate.sh +
# shared/bin/install-deploy-hook.sh (e4c8 builder_fix).
#
# 事故背景：2026-07-07 22:39，Bella REJECT c9d2 後，該分支仍被裸 git merge 進
# mvp/ 的 production main。本測試證明：①裸 git merge 對受保護分支一律擋下
# ②只有 task 真的在 tasks/done/ 且有 verdict_approve 記錄才放行 merge
# ③token 單次使用，不能重放 ④非受保護分支不受影響。
#
# 鐵律：全部在 mktemp -d 拋棄式 git repo 跑，絕不對本репository 或任何真實
# repo 操作（feedback_git_ops_verify_in_throwaway_repo / _mutating_test_isolated_repo）。
#
# Usage: fatq-deploy-gate-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="$SCRIPT_DIR/../bin/fatq-deploy-gate.sh"
INSTALL_HOOK_SH="$SCRIPT_DIR/../bin/install-deploy-hook.sh"

TOTAL_PASS=0
TOTAL_FAIL=0
FAIL_NAMES=()

ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; return 1; }

setup() {
  TMPROOT=$(mktemp -d /tmp/deploy-gate-test-XXXXXX)
  REPO="$TMPROOT/repo"
  export FATQ_ROOT="$TMPROOT/tasks"
  mkdir -p "$REPO" "$FATQ_ROOT"/{done,review,rejected}
  git init -q -b master "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  git -C "$REPO" checkout -q -b feature
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m "feature work"
  git -C "$REPO" checkout -q master
  bash "$INSTALL_HOOK_SH" "$REPO" master >/dev/null
  export FATQ_DEPLOY_LOG="$TMPROOT/deploy.log"
}

teardown() {
  rm -rf "$TMPROOT"
}

make_done_task() {
  local id="$1" with_approve="$2"
  if [[ "$with_approve" == "1" ]]; then
    cat > "$FATQ_ROOT/done/${id}.json" <<EOF
{"task_id":"${id}","status":"done","history":[
  {"ts":"2026-07-07T23:00:00+08:00","by":"anna","action":"submit"},
  {"ts":"2026-07-07T23:05:00+08:00","by":"bella","action":"verdict_approve"}
]}
EOF
  else
    cat > "$FATQ_ROOT/done/${id}.json" <<EOF
{"task_id":"${id}","status":"done","history":[
  {"ts":"2026-07-07T23:00:00+08:00","by":"anna","action":"submit"}
]}
EOF
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# D1 — 裸 git merge 完全繞過 gate 腳本 → hook 擋下，master 不動
# ══════════════════════════════════════════════════════════════════════════
test_D1() {
  local before after
  before=$(git -C "$REPO" rev-parse master)
  git -C "$REPO" merge --ff-only feature >/dev/null 2>&1
  local rc=$?
  after=$(git -C "$REPO" rev-parse master)
  [[ "$rc" -ne 0 ]] || bad "D1: 裸 merge 應該失敗，實得 exit=0" || return 1
  [[ "$before" == "$after" ]] || bad "D1: master 不應改變，卻從 $before 變成 $after" || return 1
  git -C "$REPO" status --short | grep -q . && { bad "D1: working tree 應乾淨（git 應完整回滾）"; return 1; }
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D2 — task 不在 tasks/done/（還在 review/）→ gate 拒絕，不動 repo
# ══════════════════════════════════════════════════════════════════════════
test_D2() {
  cat > "$FATQ_ROOT/review/t-d2.json" <<'EOF'
{"task_id":"t-d2","status":"review","history":[{"ts":"x","by":"anna","action":"submit"}]}
EOF
  local before after
  before=$(git -C "$REPO" rev-parse master)
  bash "$GATE_SH" t-d2 "$REPO" feature >/dev/null 2>&1
  local rc=$?
  after=$(git -C "$REPO" rev-parse master)
  [[ "$rc" == "2" ]] || bad "D2: 期望 exit=2，實得 $rc" || return 1
  [[ "$before" == "$after" ]] || bad "D2: master 不應改變" || return 1
  [[ -f "$REPO/.git/DEPLOY_APPROVED" ]] && { bad "D2: 不應留下 token"; return 1; }
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D3 — task 在 done/ 但 history 沒有 verdict_approve（異常搬動）→ gate 拒絕
# ══════════════════════════════════════════════════════════════════════════
test_D3() {
  make_done_task "t-d3" 0
  bash "$GATE_SH" t-d3 "$REPO" feature >/dev/null 2>&1
  local rc=$?
  [[ "$rc" == "2" ]] || bad "D3: 期望 exit=2，實得 $rc" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D4 — task 真的 done+verdict_approve → gate 放行，merge 成功落地
# ══════════════════════════════════════════════════════════════════════════
test_D4() {
  make_done_task "t-d4" 1
  local target
  target=$(git -C "$REPO" rev-parse feature)
  bash "$GATE_SH" t-d4 "$REPO" feature >/dev/null 2>&1
  local rc=$?
  [[ "$rc" == "0" ]] || bad "D4: 期望 exit=0，實得 $rc" || return 1
  [[ "$(git -C "$REPO" rev-parse master)" == "$target" ]] || bad "D4: master 應前進到 feature 的 commit" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D5 — token 單次使用：D4 部署成功後，token 應被消耗；再一次裸 merge（新提交）
# 仍應被擋（不能拿舊 token 重放，也沒有新 token）
# ══════════════════════════════════════════════════════════════════════════
test_D5() {
  make_done_task "t-d5" 1
  bash "$GATE_SH" t-d5 "$REPO" feature >/dev/null 2>&1
  [[ -f "$REPO/.git/DEPLOY_APPROVED" ]] && { bad "D5: 部署成功後 token 應被清除"; return 1; }

  git -C "$REPO" checkout -q feature
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m "more work"
  git -C "$REPO" checkout -q master
  local before
  before=$(git -C "$REPO" rev-parse master)
  git -C "$REPO" merge --ff-only feature >/dev/null 2>&1
  local rc=$?
  [[ "$rc" -ne 0 ]] || bad "D5: 沒走 gate 的第二次裸 merge 應該失敗" || return 1
  [[ "$(git -C "$REPO" rev-parse master)" == "$before" ]] || bad "D5: master 不應被第二次裸 merge 改變" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D6 — 非受保護分支（scratch）不受 hook 影響，正常提交
# ══════════════════════════════════════════════════════════════════════════
test_D6() {
  git -C "$REPO" checkout -q -b scratch
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m "scratch work" >/dev/null 2>&1
  local rc=$?
  [[ "$rc" == "0" ]] || bad "D6: 非受保護分支的提交不應被擋，實得 exit=$rc" || return 1
  return 0
}

# ══════════════════════════════════════════════════════════════════════════
# D7 — branch 不是目前 HEAD 的 ff 後裔（已分叉）→ gate 拒絕，repo 不動
# 造分叉的方式：先合法部署一個手足分支 otherfeature 把 master 往前推，
# feature 仍停在舊的共同祖先——此時 master 已不是 feature 的祖先，真分叉。
# （不能直接在 master 上手動加 commit 製造分叉：master 受 hook 保護，連
# 一般 commit 都會被擋，這正是本機制刻意的行為，見 D1。）
# ══════════════════════════════════════════════════════════════════════════
test_D7() {
  git -C "$REPO" checkout -q -b otherfeature master
  git -C "$REPO" -c user.email=t@t -c user.name=t commit --allow-empty -q -m "sibling work"
  git -C "$REPO" checkout -q master
  make_done_task "t-d7-other" 1
  bash "$GATE_SH" t-d7-other "$REPO" otherfeature >/dev/null 2>&1
  [[ "$?" == "0" ]] || { bad "D7: 前置的 otherfeature 部署應先成功才能造出分叉情境"; return 1; }

  make_done_task "t-d7" 1
  local before after
  before=$(git -C "$REPO" rev-parse master)
  bash "$GATE_SH" t-d7 "$REPO" feature >/dev/null 2>&1
  local rc=$?
  after=$(git -C "$REPO" rev-parse master)
  [[ "$rc" == "3" ]] || bad "D7: 期望 exit=3（非 ff-able，feature 與 master 已分叉），實得 $rc" || return 1
  [[ "$before" == "$after" ]] || bad "D7: master 不應改變" || return 1
  return 0
}

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

for t in D1 D2 D3 D4 D5 D6 D7; do
  run_test "$t"
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-deploy-gate-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail (of $((TOTAL_PASS+TOTAL_FAIL)))"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-deploy-gate-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
echo "[fatq-deploy-gate-test] All cases passed ✅"

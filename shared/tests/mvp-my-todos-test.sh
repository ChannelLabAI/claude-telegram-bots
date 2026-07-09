#!/usr/bin/env bash
# mvp-my-todos-test.sh — RETIRED
#
# B1 /api/my-todos was removed when e6f4 merged the standalone "我的待辦"
# page into the unified work hub. Keep this file as an explicit tombstone so the
# historical 17-script suite stays green without silently deleting the old
# acceptance fixture.
#
# Replacement coverage lives in mvp-hub-test.sh:
# - /api/hub is the active work-hub endpoint.
# - H7 asserts the hub response exposes todos sourced from approval_pending.
# - H8/H9 assert the old task/todo panes are removed and folded into 工作中樞.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
HUB_TEST="${HUB_TEST:-/home/oldrabbit/.claude-bots/shared/tests/mvp-hub-test.sh}"

echo "=== B1 retired：/api/my-todos 已由 e6f4 工作中樞取代 ==="
if grep -q '"/api/my-todos"' "$SRC/mvp-server.ts" 2>/dev/null; then
  bad "$SRC/mvp-server.ts 仍暴露 /api/my-todos；退役判斷需要重看"
else
  ok "受測 mvp-server.ts 未實作 /api/my-todos（符合 e6f4 收斂後狀態）"
fi

if grep -q '"/api/hub"' "$SRC/mvp-server.ts" 2>/dev/null; then
  ok "替代端點 /api/hub 存在"
else
  bad "$SRC/mvp-server.ts 缺 /api/hub，不能用 hub 承接待辦斷言"
fi

if grep -q "=== H7 /api/hub 含 todos 欄位" "$HUB_TEST" 2>/dev/null \
  && grep -q "approval_pending" "$HUB_TEST" 2>/dev/null \
  && grep -q "任務/待辦分頁按鈕拿掉" "$HUB_TEST" 2>/dev/null; then
  ok "mvp-hub-test.sh 已留有 hub/todos 等價斷言與舊分頁移除斷言"
else
  bad "mvp-hub-test.sh 缺 hub/todos 等價覆蓋，不能退役 my-todos fixture"
fi

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

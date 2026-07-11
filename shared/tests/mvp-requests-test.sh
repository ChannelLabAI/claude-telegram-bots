#!/usr/bin/env bash
# mvp-requests-test.sh — retired B3 /api/requests fixture
#
# ad26 folded the old standalone requests page into the e6f4 work hub.  This
# suite now protects that migration instead of reviving the deleted endpoint.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

echo "=== retired /api/requests：standalone endpoint/page removed ==="
if grep -q '"/api/requests"' "$SRC/mvp-server.ts" 2>/dev/null; then
  bad "mvp-server.ts still exposes /api/requests; ad26 hub migration expects it retired"
else
  ok "/api/requests endpoint retired"
fi

if grep -q 'id="requestsPane"' "$SRC/app.html" 2>/dev/null || grep -q "api('/api/requests')" "$SRC/app.html" 2>/dev/null; then
  bad "app.html still references requestsPane or /api/requests"
else
  ok "standalone requestsPane/loadRequests wiring retired"
fi

echo "=== hub coverage for old requests intent ==="
grep -q '"/api/hub"' "$SRC/mvp-server.ts" && ok "/api/hub endpoint exists" || bad "missing /api/hub endpoint"
grep -q 'archivedProjects' "$SRC/mvp-server.ts" && ok "hub exposes archivedProjects separately" || bad "hub missing archivedProjects"
grep -q 'looseTasks' "$SRC/mvp-server.ts" && ok "hub exposes looseTasks for unprojected requests/tasks" || bad "hub missing looseTasks"
grep -q 'todos: approvalsFor(user)' "$SRC/mvp-server.ts" && ok "hub exposes approval todos" || bad "hub missing todos"
grep -q "api('/api/hub')" "$SRC/app.html" && ok "front-end loads /api/hub" || bad "front-end missing /api/hub load"
grep -q 'looseTaskList' "$SRC/app.html" && ok "front-end renders loose task list" || bad "front-end missing loose task list"
grep -q 'apprList' "$SRC/app.html" && ok "front-end renders approval/todo list" || bad "front-end missing approval/todo list"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

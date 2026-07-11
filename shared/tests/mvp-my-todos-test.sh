#!/usr/bin/env bash
# mvp-my-todos-test.sh — B1 /api/my-todos regression fixture
# This fixture is intentionally source-level: some worker sandboxes cannot bind
# local listener ports, while the security regression we must lock is visible in
# the route and frontend gates.
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
SERVER="$SRC/mvp-server.ts"
APP="$SRC/app.html"

echo "=== B1 /api/my-todos source regression ==="

grep -q 'if (u.pathname === "/api/my-todos" && req.method === "GET")' "$SERVER" \
  && ok "server exposes GET /api/my-todos" \
  || bad "server missing GET /api/my-todos"

awk '
  /if \(u.pathname === "\/api\/my-todos" && req.method === "GET"\)/ {in_route=1; n=0}
  in_route {buf=buf $0 "\n"; n++}
  in_route && n>28 {print buf; exit}
' "$SERVER" > /tmp/mvp-my-todos-route.$$
ROUTE=/tmp/mvp-my-todos-route.$$
trap 'rm -f "$ROUTE"' EXIT

grep -q 'user.role !== "admin"' "$ROUTE" \
  && grep -q 'status: 403' "$ROUTE" \
  && ok "admin-only gate returns 403 for non-admin" \
  || bad "admin-only gate missing or not 403"

grep -q 'const OWNER = "laotu"' "$ROUTE" \
  && ok "OWNER remains laotu" \
  || bad "OWNER laotu missing"

grep -q 'new Set(\["pending", "in_progress", "review"\])' "$ROUTE" \
  && ok "ACTIVE_STATES excludes terminal states" \
  || bad "ACTIVE_STATES does not match pending/in_progress/review"

# e1f4：my-todos 改 runFatqAsync + active-state scoped（全量 query >30s 且 spawnSync 凍 event loop）
# 不變式不變：唯讀 FATQ query 為唯一資料源、只掃 active states（與下方 filter 四態一致）
grep -q 'runFatqAsync(\["query", "--state", st, "--json"\])' "$ROUTE" \
  && grep -q 'MYTODO_STATES = \["pending", "in_progress", "review", "approval_pending"\]' "$ROUTE" \
  && ok "route uses async scoped FATQ query as readonly source (4 active states)" \
  || bad "route does not use async scoped FATQ query"

grep -q 't.state === "approval_pending"' "$ROUTE" \
  && grep -Fq '(t.approval?.approvers ?? []).includes(OWNER)' "$ROUTE" \
  && ok "approval todos require OWNER approver" \
  || bad "approval OWNER approver filter missing"

grep -Fq 'ACTIVE_STATES.has(t.state) && (t.assigned === OWNER || t.reviewer === OWNER)' "$ROUTE" \
  && ok "reply todos require active assigned/reviewer OWNER" \
  || bad "reply assigned/reviewer OWNER filter missing"

grep -q 'kind: t.state === "approval_pending" ? "approval" : "reply"' "$ROUTE" \
  && ok "response projects approval/reply kind" \
  || bad "response missing approval/reply kind projection"

grep -q "me?.role!=='admin')return" "$APP" \
  && ok "frontend does not auto-load /api/my-todos for non-admin" \
  || bad "frontend missing non-admin loadMyTodosReply guard"

grep -q 'tbReplyItems' "$APP" \
  && grep -q 'kind.*reply' "$APP" \
  && ok "frontend renders reply todos through todobar" \
  || bad "frontend missing reply todobar wiring"

if grep -A14 'function loadMyTodosReply' "$APP" | grep -q '開對話'; then
  bad "loadMyTodosReply appears to add a fake chat/open-conversation affordance"
else
  ok "reply UI does not add fake open-conversation affordance"
fi

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

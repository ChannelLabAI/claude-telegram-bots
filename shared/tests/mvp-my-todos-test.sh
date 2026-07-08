#!/usr/bin/env bash
# mvp-my-todos-test.sh — B1「我的待辦」/api/my-todos 驗收 fixture（task 20260708-0000-b1e7）
# 鐵律（同 mvp-web-test.sh）：FATQ_ROOT 一律 mktemp fixture，絕不指向真實 tasks/。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-my-todos-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
REAL_FATQ="/home/oldrabbit/.claude-bots/shared/bin/fatq"
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

if ! grep -q '"/api/my-todos"' "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 未實作 /api/my-todos，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-my-todos-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,design_review,approval_pending}
mkdir -p "$FIX/mvp-real"
cp "$SRC/app.html" "$FIX/mvp-real/" 2>/dev/null || true

# --- fixture 任務（涵蓋應收/不應收各案）---
mk(){ # $1=state $2=task_id $3=extra-json-fields(逗號分隔，不含大括號)
  cat > "$FATQ_ROOT/$1/$2.json" <<EOF
{"task_id":"$2","status":"$1","goal":"fixture $2","history":[],$3}
EOF
}
mk pending      td-assigned-laotu     '"assigned":"laotu","reviewer":"bella"'
mk review       td-reviewer-laotu     '"assigned":"anna","reviewer":"laotu"'
mk in_progress  td-other-bot          '"assigned":"anna","reviewer":"bella"'
mk done         td-done-laotu         '"assigned":"laotu","reviewer":"bella"'
mk approval_pending td-approval-laotu '"assigned":"anna","approval":{"domain":"cross-bot-infra","requested_by":"anna","approvers":["laotu"],"expires":"2099-01-01T00:00:00+08:00","return_state":"pending"}'
mk approval_pending td-approval-other '"assigned":"anna","approval":{"domain":"cross-bot-infra","requested_by":"anna","approvers":["anya"],"expires":"2099-01-01T00:00:00+08:00","return_state":"pending"}'

start_server(){ # $1=port $2=mvpdir
  ( export MVP_PORT=$1 FATQ_BIN="$REAL_FATQ" MVP_DIR="$FIX/$2" FATQ_ROOT="$FATQ_ROOT" MVP_DEV_MODE=1
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P=18099
PID=$(start_server $P mvp-real)
trap 'kill $PID 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P || { echo "FATAL: server 起不來"; tail -20 "$FIX/server-$P.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$2" -X POST -d "email=$1" "http://127.0.0.1:$P/auth/dev-login" -o /dev/null; }
API(){ local ck=$1; shift; curl -sm 15 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }

login "wctodos@x.local" todos
sqlite3 "$FIX/mvp-real/users.db" "UPDATE users SET role='admin' WHERE email='wctodos@x.local';"

echo "=== B1 /api/my-todos（admin）：只收 owner=laotu 的 approval_pending + 進行中 assigned/reviewer ==="
r=$(API todos "http://127.0.0.1:$P/api/my-todos")
echo "$r" > "$FIX/my-todos.json"
python3 - "$FIX/my-todos.json" <<'PY' && ok "回傳集合正確（4 收 2 不收，均驗證）" || bad "斷言失敗：$r"
import json,sys
d=json.load(open(sys.argv[1]))
ids=[t["task_id"] for t in d["todos"]]
assert d["me"]=="laotu", d["me"]
assert set(ids)=={"td-assigned-laotu","td-reviewer-laotu","td-approval-laotu"}, ids
assert "td-other-bot" not in ids
assert "td-done-laotu" not in ids, "已 done 的任務不該算待辦"
assert "td-approval-other" not in ids, "approvers 不含 laotu 的審批不該算他的待辦"
kinds = {t["task_id"]: t["kind"] for t in d["todos"]}
assert kinds["td-approval-laotu"] == "approval", kinds
assert kinds["td-assigned-laotu"] == "reply", kinds
assert kinds["td-reviewer-laotu"] == "reply", kinds
assert d["count"] == len(d["todos"]) == 3, d["count"]
PY

echo "=== B1 未登入 → 401，不洩漏資料 ==="
c=$(curl -sm 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/my-todos")
[ "$c" = "401" ] && ok "未登入 401" || bad "未登入 → $c（期望 401）"

echo "=== B1（Bella 09:09 REJECT BLOCKER 回歸測）：非 admin 一般成員打 /api/my-todos → 403，零資料洩漏 ==="
login "randomguy@x.local" randomguy  # dev-login 預設 role=member、identity=NULL，代表任意登入成員
c403=$(curl -sm 15 -o "$FIX/randomguy-resp.json" -w "%{http_code}" -b "$FIX/ck-randomguy" "http://127.0.0.1:$P/api/my-todos")
[ "$c403" = "403" ] && ok "非 admin 成員 → 403" || bad "非 admin 成員 → $c403（期望 403，這就是 09:09 REJECT 抓到的洩漏）"
if grep -q '"task_id"' "$FIX/randomguy-resp.json" 2>/dev/null; then
  bad "403 回應仍夾帶 task 資料：$(cat "$FIX/randomguy-resp.json")"
else
  ok "403 回應零任務資料"
fi

echo "=== B1 前端接線：app.html 消費 /api/my-todos，等你回覆段不做假『開對話』連結，且非 admin 不自動打 API ==="
grep -q "loadMyTodosReply" "$SRC/app.html" && grep -q "'/api/my-todos'" "$SRC/app.html" \
  && ok "已接線 loadMyTodosReply() → /api/my-todos" || bad "app.html 缺 loadMyTodosReply 或未呼叫 /api/my-todos"
awk '/async function loadMyTodosReply/{f=1} f{print} f&&/^}/{exit}' "$SRC/app.html" > "$FIX/reply-fn.txt"
grep -q "開對話" "$FIX/reply-fn.txt" && bad "等你回覆段殘留『開對話』字樣（無對話深連結可實作，屬幽靈行為）" \
  || ok "等你回覆段無幽靈『開對話』連結（只誠實顯示 goal+狀態）"
grep -qE "me(\?\.|\.)role\s*!==\s*'admin'" "$FIX/reply-fn.txt" \
  && ok "loadMyTodosReply() 前端已收進 admin 判斷（09:09 BLOCKER 修復）" \
  || bad "loadMyTodosReply() 缺 admin 判斷，非 admin 使用者頁面仍會自動打 /api/my-todos"
login "wcpage@x.local" page
pc=$(curl -sm 15 -o /dev/null -w "%{http_code}" -b "$FIX/ck-page" "http://127.0.0.1:$P/")
[ "$pc" = "200" ] && ok "/ 頁面（含新 B1 markup）仍正常渲染 200" || bad "/ 頁面 → $pc（期望 200）"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

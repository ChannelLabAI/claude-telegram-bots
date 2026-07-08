#!/usr/bin/env bash
# mvp-requests-test.sh — B3「需求追蹤」/api/requests 驗收 fixture（task 20260708-1301-6cae）
# 鐵律（同 mvp-web-test.sh）：FATQ_ROOT 一律 mktemp fixture，絕不指向真實 tasks/。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-requests-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
REAL_FATQ="/home/oldrabbit/.claude-bots/shared/bin/fatq"
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

if ! grep -q '"/api/requests"' "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 未實作 /api/requests，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-requests-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,design_review,approval_pending}
mkdir -p "$FIX/mvp-real"
cp "$SRC/app.html" "$FIX/mvp-real/" 2>/dev/null || true

# --- fixture 任務：一個 laotu Epic + 三種 related 寫法的子任務 + 三種不該收的案例 ---
mk(){ # $1=state $2=task_id $3=extra-json-fields(逗號分隔，不含大括號)
  cat > "$FATQ_ROOT/$1/$2.json" <<EOF
{"task_id":"$2","status":"$1","goal":"fixture $2","history":[],$3}
EOF
}
mk pending  20260101-0000-ce55-epic-fixture   '"created_by":"laotu"'
mk done     20260101-0001-e8f4-child-path     '"created_by":"anya","related":["tasks/pending/20260101-0000-ce55-epic-fixture.json"]'
mk review   20260101-0002-c9d2-child-bareid   '"created_by":"anna","related":["20260101-0000-ce55"]'
mk in_progress 20260101-0003-d8a6-child-label '"created_by":"anna","related":["Epic ce55","some/other/path.md"]'
mk pending  20260101-0004-x1y1-not-child      '"created_by":"anna","related":["completely unrelated"]'
mk pending  20260101-0005-x2y2-no-related     '"created_by":"anna"'
mk pending  20260101-0006-x3y3-other-owner    '"created_by":"anya"'

start_server(){ # $1=port $2=mvpdir
  ( export MVP_PORT=$1 FATQ_BIN="$REAL_FATQ" MVP_DIR="$FIX/$2" FATQ_ROOT="$FATQ_ROOT" MVP_DEV_MODE=1
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P=18098
PID=$(start_server $P mvp-real)
trap 'kill $PID 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P || { echo "FATAL: server 起不來"; tail -20 "$FIX/server-$P.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$2" -X POST -d "email=$1" "http://127.0.0.1:$P/auth/dev-login" -o /dev/null; }
API(){ local ck=$1; shift; curl -sm 15 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }

login "wcreq@x.local" req
sqlite3 "$FIX/mvp-real/users.db" "UPDATE users SET role='admin' WHERE email='wcreq@x.local';"

echo "=== B3 /api/requests（admin）：ce55 root 收齊三種 related 寫法的子任務，不該收的三案排除 ==="
r=$(API req "http://127.0.0.1:$P/api/requests")
echo "$r" > "$FIX/requests.json"
python3 - "$FIX/requests.json" <<'PY' && ok "root+children 樹狀結構正確（路徑/裸id/純文字三種 related 寫法都認得）" || bad "斷言失敗：$r"
import json,sys
d=json.load(open(sys.argv[1]))
reqs={r["task_id"]:r for r in d["requests"]}
assert "20260101-0000-ce55-epic-fixture" in reqs, reqs.keys()
root=reqs["20260101-0000-ce55-epic-fixture"]
cids={c["task_id"] for c in root["children"]}
assert cids=={"20260101-0001-e8f4-child-path","20260101-0002-c9d2-child-bareid","20260101-0003-d8a6-child-label"}, cids
assert "20260101-0004-x1y1-not-child" not in cids
assert "20260101-0005-x2y2-no-related" not in cids
assert "20260101-0006-x3y3-other-owner" not in [r["task_id"] for r in d["requests"]], "created_by!=laotu 不該被當成 request root"
assert root["progress"]=={"done":1,"total":3}, root["progress"]
PY

echo "=== B3（比照 B1 09:09 教訓）非 admin 成員打 /api/requests → 403，零資料洩漏 ==="
login "randomguy@x.local" randomguy
c403=$(curl -sm 15 -o "$FIX/randomguy-resp.json" -w "%{http_code}" -b "$FIX/ck-randomguy" "http://127.0.0.1:$P/api/requests")
[ "$c403" = "403" ] && ok "非 admin 成員 → 403" || bad "非 admin 成員 → $c403（期望 403）"
grep -q '"task_id"' "$FIX/randomguy-resp.json" 2>/dev/null \
  && bad "403 回應仍夾帶 task 資料：$(cat "$FIX/randomguy-resp.json")" \
  || ok "403 回應零任務資料"

echo "=== B3 未登入 → 401 ==="
c=$(curl -sm 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P/api/requests")
[ "$c" = "401" ] && ok "未登入 401" || bad "未登入 → $c（期望 401）"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

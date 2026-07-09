#!/usr/bin/env bash
# mvp-board-test.sh — B2「任務看板後端」/api/board 驗收 fixture（task 20260708-1301-56cd）
# 鐵律（同 mvp-usage-panel-test.sh）：FATQ_ROOT 一律 mktemp fixture，絕不指向真實 tasks/。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-board-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
REAL_FATQ="/home/oldrabbit/.claude-bots/shared/bin/fatq"
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

if ! grep -q '"/api/board"' "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 未實作 /api/board，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-board-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected,cancelled,wont_do,design_review,approval_pending}
# 刻意不建 done/ 目錄——測 existsSync 缺目錄容錯（不炸、視為空欄）
mkdir -p "$FIX/mvp-real"
cp "$SRC/app.html" "$FIX/mvp-real/" 2>/dev/null || true

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EARLIER=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ)

# pending/：新 schema(goal) 一張 + 舊 schema(title，無 goal) 一張——驗 schema-drift fallback
cat > "$FATQ_ROOT/pending/new-schema.json" <<EOF
{"task_id":"new-schema","goal":"新 schema 任務","priority":"P1","assigned":"sancai","reviewer":"bella","created_at":"$NOW","history":[]}
EOF
cat > "$FATQ_ROOT/pending/old-schema.json" <<EOF
{"title":"舊 schema 任務","priority":"P2","assigned":"anna","created_at":"$EARLIER","history":[]}
EOF

# in_progress/：正常一張
cat > "$FATQ_ROOT/in_progress/wip-1.json" <<EOF
{"task_id":"wip-1","goal":"進行中任務","priority":"P1","assigned":"sancai","created_at":"$NOW","history":[]}
EOF

# review/：正常一張 + 一張壞檔（不可解析 JSON）——驗壞行容錯不炸、有效檔仍被計入
cat > "$FATQ_ROOT/review/rev-1.json" <<EOF
{"task_id":"rev-1","goal":"審查中任務","priority":"P2","assigned":"sancai","reviewer":"bella","created_at":"$NOW","history":[]}
EOF
echo 'NOT-VALID-JSON{{{' > "$FATQ_ROOT/review/broken.json"

# rejected/ + design_review/：不屬於看板 4 態，驗證不會外洩進 board.* 任何欄位
cat > "$FATQ_ROOT/rejected/should-not-leak.json" <<EOF
{"task_id":"should-not-leak","goal":"不該出現在看板","priority":"P1","created_at":"$NOW","history":[]}
EOF
cat > "$FATQ_ROOT/design_review/also-not-leak.json" <<EOF
{"task_id":"also-not-leak","goal":"也不該出現","priority":"P1","created_at":"$NOW","history":[]}
EOF

start_server(){ # $1=port $2=fatq_root
  ( export MVP_PORT=$1 FATQ_BIN="$REAL_FATQ" MVP_DIR="$FIX/mvp-real" FATQ_ROOT="$2" MVP_DEV_MODE=1
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P=18099
PID=$(start_server $P "$FATQ_ROOT")
trap 'kill $PID 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P || { echo "FATAL: server 起不來"; tail -20 "$FIX/server-$P.log"; exit 1; }

curl -sc "$FIX/ck" -X POST -d "email=board-test@x.local" "http://127.0.0.1:$P/auth/dev-login" -o /dev/null
R=$(curl -sm 15 -b "$FIX/ck" "http://127.0.0.1:$P/api/board")

echo "=== B2-1 端點回 200 + 四個分組鍵存在 ==="
CODE=$(curl -sm 15 -o /dev/null -w "%{http_code}" -b "$FIX/ck" "http://127.0.0.1:$P/api/board")
[ "$CODE" = "200" ] && ok "/api/board → 200" || bad "/api/board → $CODE（期望 200）"
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=d['board']
for k in ('pending','in_progress','review','done'):
    assert k in b, f'缺分組 {k}'
" && ok "board 含 pending/in_progress/review/done 四組" || bad "board 分組鍵缺失"

echo "=== B2-2 schema-drift：goal 優先、無 goal 時退回 title ==="
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
p={x['task_id']:x for x in d['board']['pending']}
assert p['new-schema']['goal']=='新 schema 任務', p['new-schema']
old=[x for x in d['board']['pending'] if x['task_id']=='old-schema']
assert old and old[0]['goal']=='舊 schema 任務', old
" && ok "goal/title fallback 正確" || bad "schema-drift fallback 失敗：$(echo "$R"|head -c 300)"

echo "=== B2-3 排序：同欄位按 created_at 新到舊 ==="
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=[x['task_id'] for x in d['board']['pending']]
assert ids[0]=='new-schema' and ids[1]=='old-schema', ids
" && ok "pending 依 created_at 新到舊排序" || bad "排序錯誤：$(echo "$R"|head -c 300)"

echo "=== B2-4 壞檔容錯：review 只計入有效檔，不炸 ==="
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rev=d['board']['review']
assert len(rev)==1 and rev[0]['task_id']=='rev-1', rev
" && ok "review 壞檔跳過、有效檔仍計入" || bad "壞檔容錯失敗：$(echo "$R"|head -c 300)"

echo "=== B2-5 缺目錄容錯：done/ 不存在 → 空陣列不炸 ==="
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['board']['done']==[], d['board']['done']
assert d['truncated']['done']==False
" && ok "done/ 目錄不存在 → 空陣列、非 truncated" || bad "缺目錄處理失敗：$(echo "$R"|head -c 300)"

echo "=== B2-6 非看板狀態不外洩：rejected/design_review 內容不出現在任何 board.* ==="
echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
allids=set()
for k in ('pending','in_progress','review','done'):
    for x in d['board'][k]: allids.add(x['task_id'])
assert 'should-not-leak' not in allids, allids
assert 'also-not-leak' not in allids, allids
" && ok "rejected/design_review 內容未外洩進看板" || bad "狀態外洩：$(echo "$R"|head -c 300)"

echo "=== B2-7 超量截斷：欄位超過 200 筆時 truncated=true 且回傳恰 200 筆 ==="
TFIX=$(mktemp -d /tmp/mvp-board-trunc-XXXXXX)
TROOT="$TFIX/tasks"
mkdir -p "$TROOT"/{pending,in_progress,review,done}
for i in $(seq 1 205); do
  printf '{"task_id":"t-%03d","goal":"批量任務 %03d","created_at":"2026-01-01T00:00:%02dZ","history":[]}' "$i" "$i" "$((i % 60))" > "$TROOT/pending/t-$i.json"
done
PID2=$(start_server 18100 "$TROOT")
waitport 18100 || { echo "FATAL: 截斷測試 server 起不來"; kill $PID2 2>/dev/null; rm -rf "$TFIX"; FAIL=$((FAIL+1)); }
if [ -n "${PID2:-}" ] && kill -0 "$PID2" 2>/dev/null; then
  curl -sc "$TFIX/ck" -X POST -d "email=trunc@x.local" "http://127.0.0.1:18100/auth/dev-login" -o /dev/null
  R2=$(curl -sm 15 -b "$TFIX/ck" "http://127.0.0.1:18100/api/board")
  echo "$R2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert len(d['board']['pending'])==200, len(d['board']['pending'])
assert d['truncated']['pending']==True, d['truncated']
assert d['truncated']['in_progress']==False
" && ok "205 筆截斷為 200、truncated 正確標記" || bad "截斷邏輯失敗：$(echo "$R2"|head -c 300)"
  kill $PID2 2>/dev/null
fi
rm -rf "$TFIX"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

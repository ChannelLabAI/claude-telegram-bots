#!/usr/bin/env bash
# mvp-usage-panel-test.sh — A2「用量面板」/api/usage 驗收 fixture（task 20260707-2358-a2f1）
# 鐵律（同 mvp-web-test.sh）：FATQ_ROOT/MVP_USAGE_JSONL 一律 mktemp fixture，絕不指向真實 tasks/、真實 usage.jsonl。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-usage-panel-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
REAL_FATQ="/home/oldrabbit/.claude-bots/shared/bin/fatq"
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

if ! grep -q '"/api/usage"' "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 未實作 /api/usage，拒跑。"
  exit 1
fi
if ! grep -q "MVP_USAGE_JSONL" "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 不支援 MVP_USAGE_JSONL 注入——fixture 隔離會失效並讀到生產 logs/usage.jsonl，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-usage-panel-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,design_review,approval_pending}
mkdir -p "$FIX/mvp-real" "$FIX/mvp-nofile"
cp "$SRC/app.html" "$FIX/mvp-real/" 2>/dev/null || true

# --- fixture usage.jsonl（相對現在時間造，避開固定日期造成的跨日 flake）---
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%Y-%m-%d)
EARLY_TODAY_TS=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ)
YDAY_TS=$(date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)
YDAY=$(date -u -d "1 day ago" +%Y-%m-%d)
OLD_TS=$(date -u -d "20 days ago" +%Y-%m-%dT%H:%M:%SZ)
OLD_DATE=$(date -u -d "20 days ago" +%Y-%m-%d)

cat > "$FIX/usage.jsonl" <<EOF
{"ts":"$EARLY_TODAY_TS","date":"$TODAY","bot":"alice","model":"claude-sonnet-5","session_id":"s-dedup","input_tokens":100,"output_tokens":1000,"cache_read_tokens":500,"cache_write_tokens":50,"rate_limit_events":3}
NOT-JSON-GARBAGE{{{
{"ts":"$NOW","date":"$TODAY","bot":"alice","model":"claude-sonnet-5","session_id":"s-dedup","input_tokens":150,"output_tokens":1500,"cache_read_tokens":800,"cache_write_tokens":80,"rate_limit_events":5}

{"ts":"$NOW","date":"$TODAY","bot":"bob","model":"claude-fable-5","session_id":"s-bob","input_tokens":200,"output_tokens":2000,"cache_read_tokens":100,"cache_write_tokens":10,"rate_limit_events":0}
{"ts":"$YDAY_TS","date":"$YDAY","bot":"carol","model":"claude-sonnet-5","session_id":"s-crossday","input_tokens":50,"output_tokens":500,"cache_read_tokens":20,"cache_write_tokens":2,"rate_limit_events":1}
{"ts":"$NOW","date":"$TODAY","bot":"carol","model":"claude-sonnet-5","session_id":"s-crossday","input_tokens":70,"output_tokens":700,"cache_read_tokens":30,"cache_write_tokens":3,"rate_limit_events":2}
{"ts":"$OLD_TS","date":"$OLD_DATE","bot":"dave","model":"claude-sonnet-5","session_id":"s-old","input_tokens":999,"output_tokens":9999,"cache_read_tokens":1,"cache_write_tokens":1,"rate_limit_events":9}
EOF

start_server(){ # $1=port $2=mvpdir $3=usage_jsonl_path
  ( export MVP_PORT=$1 FATQ_BIN="$REAL_FATQ" MVP_DIR="$FIX/$2" FATQ_ROOT="$FATQ_ROOT" MVP_DEV_MODE=1 MVP_USAGE_JSONL="$3"
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P=18097; P2=18098
PID=$(start_server $P mvp-real "$FIX/usage.jsonl")
PID2=$(start_server $P2 mvp-nofile "$FIX/no-such-usage.jsonl")
trap 'kill $PID $PID2 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P || { echo "FATAL: server 起不來"; tail -20 "$FIX/server-$P.log"; exit 1; }
waitport $P2 || { echo "FATAL: nofile server 起不來"; tail -20 "$FIX/server-$P2.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$3" -X POST -d "email=$2" "http://127.0.0.1:$1/auth/dev-login" -o /dev/null; }
API(){ local port=$1 ck=$2; shift 2; curl -sm 15 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }
CODE(){ local port=$1 ck=$2; shift 2; curl -sm 15 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }

# 身份：admin 走既有種子 oldrabbit（role admin），另建一個 member 驗證 403
sqlite3 "$FIX/mvp-real/users.db" "INSERT INTO users (email,name,role,created_at) VALUES ('wcmember@x.local','wcmember','member',datetime('now'));"
login $P "wcadmin@x.local" admin
sqlite3 "$FIX/mvp-real/users.db" "UPDATE users SET role='admin' WHERE email='wcadmin@x.local';"
login $P "wcmember@x.local" member

echo "=== A2 未授權：非 admin GET /api/usage → 403 ==="
c=$(CODE $P member "http://127.0.0.1:$P/api/usage")
[ "$c" = "403" ] && ok "member → 403" || bad "member → $c（期望 403）"

echo "=== A2 admin GET /api/usage：per-session 去重聚合正確 ==="
r=$(API $P admin "http://127.0.0.1:$P/api/usage")
echo "$r" > "$FIX/usage-resp.json"
python3 - "$FIX/usage-resp.json" "$TODAY" "$YDAY" <<'PY' && ok "去重/聚合/跨日歸屬/429累計值/過舊排除 全過" || bad "斷言失敗：見 usage-resp.json"
import json,sys
d=json.load(open(sys.argv[1]))
today, yday = sys.argv[2], sys.argv[3]
bots={b["bot"]:b for b in d["bots"]}

# alice：兩行同 session，去重後只算最後一行（1500/150/800/80/rate=5），非 2500 加總
a=bots["alice"]
assert a["out"]==1500, a["out"]
assert a["in"]==150, a["in"]
assert a["cacheRead"]==800, a["cacheRead"]
assert a["cacheWrite"]==80, a["cacheWrite"]
assert a["rateLimitEvents"]==5, a["rateLimitEvents"]  # 累積快照取最終值，非 3+5=8
assert a["sessions"]==1, a["sessions"]  # 去重後只算 1 個 session，非 2 行

b=bots["bob"]
assert b["out"]==2000 and b["sessions"]==1, b

# carol：跨日 session（昨日 500 的快照已被今日 700 的最終快照取代），只算最終值
c=bots["carol"]
assert c["out"]==700, c["out"]
assert c["sessions"]==1, c["sessions"]

# dave：20 天前的 session，超出 14 天視窗，不應出現
assert "dave" not in bots, "過舊 session 不應納入 bots 彙總"

trend={t["date"]:t["output"] for t in d["trend"]}
# 今天 = alice(1500)+bob(2000)+carol(700，只算最終快照)=4200；不含 dave
assert trend.get(today)==4200, trend
# 昨天不應出現在 trend（carol 昨日那行是被取代的舊快照，去重後其 date 不存在於彙總來源）
assert yday not in trend, trend
PY

echo "=== A2 usage.jsonl 含壞行仍不炸 ==="
grep -q "NOT-JSON-GARBAGE" "$FIX/usage.jsonl" && ok "fixture 確實含壞行" || bad "fixture 缺壞行（測試本身有誤）"
[ -n "$r" ] && echo "$r" | python3 -c "import json,sys;json.load(sys.stdin)" 2>/dev/null \
  && ok "壞行存在下 /api/usage 仍回傳合法 JSON（未 500）" || bad "回應非合法 JSON：$r"

echo "=== A2 usage.jsonl 不存在時不炸、回空集合 ==="
login $P2 "wcadmin2@x.local" admin2
sqlite3 "$FIX/mvp-nofile/users.db" "UPDATE users SET role='admin' WHERE email='wcadmin2@x.local';"
r2=$(API $P2 admin2 "http://127.0.0.1:$P2/api/usage")
echo "$r2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['bots']==[], d['bots']
assert d['trend']==[], d['trend']
" && ok "檔案不存在 → bots/trend 皆空陣列，未 500" || bad "檔案不存在時回應異常：$r2"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

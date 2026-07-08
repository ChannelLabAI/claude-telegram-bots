#!/usr/bin/env bash
# mvp-chat-contacts-test.sh — f3a8 對話左側動態最近對話驗收 fixture
# （task 20260709-0154-f3a8-chat-dynamic-conversation-list）
#
# 核心風險（review_focus）：動態清單絕不能讓非 admin 看到已經不在 allowedPods()
# 白名單內的舊對話對象（人員異動/assistant_bot 改派後，歷史訊息還躺在 pod db
# 裡，但清單不該洩漏）——這支測試專門造一個「歷史上聊過、現在已無權限」的反面
# case（C3），不是只測正面路徑。
#
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-chat-contacts-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

grep -q "/api/chat-contacts" "$SRC/mvp-server.ts" 2>/dev/null \
  || { echo "FATAL: $SRC/mvp-server.ts 沒有 /api/chat-contacts 端點，拒跑"; exit 1; }

FIX=$(mktemp -d /tmp/mvp-chat-contacts-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
cp "$SRC/app.html" "$FIX/mvp/"

cat > "$FIX/gb/pods/assist-anya.json" <<EOF
{"podName":"assist-anya","dbPath":"$FIX/gb/anya.db","bots":[{"name":"anya","model":"claude-sonnet-5"}]}
EOF
cat > "$FIX/gb/pods/assist-carrot.json" <<EOF
{"podName":"assist-carrot","dbPath":"$FIX/gb/carrot.db","bots":[{"name":"carrot","model":"claude-sonnet-5"}]}
EOF
cat > "$FIX/gb/pods/builder.json" <<EOF
{"podName":"builder","dbPath":"$FIX/gb/builder.db","bots":[{"name":"anna","model":"claude-sonnet-5"}]}
EOF
# C6：一個 pod json 指向不存在的 dbPath——端點必須靜靜跳過，不能整支炸掉
cat > "$FIX/gb/pods/ghost.json" <<EOF
{"podName":"ghost","dbPath":"$FIX/gb/nonexistent-ghost.db","bots":[{"name":"ghost","model":"claude-sonnet-5"}]}
EOF

for db in anya carrot builder; do
  sqlite3 "$FIX/gb/$db.db" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, bot TEXT, chat_id TEXT, user_id TEXT, user_name TEXT, prompt TEXT, status TEXT, reply_text TEXT, created_at TEXT, finished_at TEXT, channel TEXT);"
done

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_DEV_MODE=1
export MVP_PORT="${2:-18971}"
REAL_GB="/home/oldrabbit/.claude-bots/gateway-builder"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" "$@"; }
API(){ curl -sm 10 "$@"; }

CK_ADMIN="$FIX/ck-admin"
curl -sc "$CK_ADMIN" -X POST -d "email=ccadmin@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
ADMIN_ID=$(sqlite3 "$FIX/mvp/users.db" "SELECT id FROM users WHERE email='ccadmin@x.local';")
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='admin', identity='ccadmin' WHERE id=$ADMIN_ID;"

CK_MEMBER="$FIX/ck-member"
curl -sc "$CK_MEMBER" -X POST -d "email=ccmember@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
MEMBER_ID=$(sqlite3 "$FIX/mvp/users.db" "SELECT id FROM users WHERE email='ccmember@x.local';")
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='member', identity='ccmember', assistant_bot='carrot' WHERE id=$MEMBER_ID;"

# ── 種資料 ──────────────────────────────────────────────────────────────
# admin 跟 carrot 聊過兩則，較晚一則才是 lastAt（驗 MAX 不是取第一筆／隨機一筆）
sqlite3 "$FIX/gb/carrot.db" "INSERT INTO tasks (bot,chat_id,user_id,user_name,prompt,status,created_at,finished_at,channel) VALUES ('carrot','web:$ADMIN_ID','$ADMIN_ID','ccadmin','第一則','done','2026-07-09T01:00:00Z','2026-07-09T01:00:05Z','web');"
sqlite3 "$FIX/gb/carrot.db" "INSERT INTO tasks (bot,chat_id,user_id,user_name,prompt,status,created_at,finished_at,channel) VALUES ('carrot','web:$ADMIN_ID','$ADMIN_ID','ccadmin','第二則(較新)','done','2026-07-09T03:00:00Z','2026-07-09T03:00:05Z','web');"
# member 跟自己的 carrot 聊過（allowedPods 內，應出現）
sqlite3 "$FIX/gb/carrot.db" "INSERT INTO tasks (bot,chat_id,user_id,user_name,prompt,status,created_at,finished_at,channel) VALUES ('carrot','web:$MEMBER_ID','$MEMBER_ID','ccmember','嗨','done','2026-07-09T02:00:00Z','2026-07-09T02:00:05Z','web');"
# member 歷史上（改派前）跟 anna(builder pod) 聊過，但 assistant_bot 現在是 carrot，不再有權
sqlite3 "$FIX/gb/builder.db" "INSERT INTO tasks (bot,chat_id,user_id,user_name,prompt,status,created_at,finished_at,channel) VALUES ('anna','web:$MEMBER_ID','$MEMBER_ID','ccmember','舊訊息(改派前)','done','2026-06-01T01:00:00Z','2026-06-01T01:00:05Z','web');"
# 另一個帳號跟 anna 聊過的紀錄不該混進 admin/member 的清單（chat_id 隔離）
sqlite3 "$FIX/gb/builder.db" "INSERT INTO tasks (bot,chat_id,user_id,user_name,prompt,status,created_at,finished_at,channel) VALUES ('anna','web:999999','999999','other','別人的對話','done','2026-07-09T01:30:00Z','2026-07-09T01:30:05Z','web');"

echo "=== C1 admin 看動態最近對話：跟 carrot 聊過 → 出現在清單，lastAt 取較新那則 ==="
r1=$(API -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/chat-contacts")
echo "$r1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bots=[c['bot'] for c in d['contacts']]
assert 'carrot' in bots, d
c=[c for c in d['contacts'] if c['bot']=='carrot'][0]
assert c['lastAt']=='2026-07-09T03:00:00Z', c
" && ok "admin 動態清單含 carrot，lastAt 取兩則訊息中較新那則（MAX 正確，非取第一筆）" || bad "C1 斷言失敗：$(echo "$r1"|head -c 200)"

echo "=== C2 member 看動態最近對話：跟自己 allowedPods 內的 carrot 聊過 → 出現在清單 ==="
r2=$(API -b "$CK_MEMBER" "http://127.0.0.1:$MVP_PORT/api/chat-contacts")
echo "$r2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bots=[c['bot'] for c in d['contacts']]
assert 'carrot' in bots, d
" && ok "member 動態清單含自己 allowedPods 內的 carrot" || bad "C2 斷言失敗：$(echo "$r2"|head -c 200)"

echo "=== C3（review_focus 核心反面斷言）：member 改派前跟 anna 的舊對話，改派後不再是 allowedPods 內 → 不該出現在動態清單 ==="
echo "$r2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bots=[c['bot'] for c in d['contacts']]
assert 'anna' not in bots, d
" && ok "member 動態清單不含已改派、不再授權的 anna（授權沒有因為『歷史上聊過』就放寬）" || bad "C3 斷言失敗：member 動態清單洩漏了無權限的舊對話對象！$(echo "$r2"|head -c 200)"

echo "=== C4 chat_id 隔離：別人（user_id=999999）跟 anna 的對話不會混進 admin/member 自己的清單 ==="
echo "$r1$r2" | grep -q "999999" && bad "別人的 user_id 洩漏進回應" || ok "回應內容沒有洩漏其他 user_id"
r1_bots=$(echo "$r1" | python3 -c "import json,sys;print([c['bot'] for c in json.load(sys.stdin)['contacts']])")
echo "$r1_bots" | grep -q "'anna'" && bad "admin 清單意外混入別人的 anna 對話（chat_id 隔離失效）" || ok "admin 清單沒有意外混入別人（user_id=999999）跟 anna 的對話（chat_id 隔離正確）"

echo "=== C5 未登入打 /api/chat-contacts → 401 ==="
c5=$(CODE "http://127.0.0.1:$MVP_PORT/api/chat-contacts")
[ "$c5" = "401" ] && ok "未登入 → 401" || bad "未登入 → $c5（期望 401）"

echo "=== C6 一個 pod json 指向不存在的 dbPath（ghost）→ 端點不炸，其餘資料正常回傳 ==="
c6=$(CODE -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/chat-contacts")
[ "$c6" = "200" ] && ok "不存在的 dbPath 沒有讓端點炸掉，仍回 200" || bad "端點對不存在的 dbPath 沒有防禦，回 $c6"

echo "=== C7 前端結構：addContactIfMissing/pickTarget 接線、init 拉 /api/chat-contacts、fixed∪dynamic 合併不改動 c9d2 排序邏輯 ==="
grep -qF "function addContactIfMissing(t,label){" "$FIX/mvp/app.html" && ok "addContactIfMissing() 已接線" || bad "缺 addContactIfMissing()"
grep -qF "addContactIfMissing(t,name)" "$FIX/mvp/app.html" && ok "pickTarget() 有呼叫 addContactIfMissing（新對象立即入清單）" || bad "pickTarget() 沒有接 addContactIfMissing"
grep -qF "api('/api/chat-contacts')" "$FIX/mvp/app.html" && ok "初始化流程有拉 /api/chat-contacts（重載後持久）" || bad "初始化流程缺 /api/chat-contacts 拉取"
grep -qF "sorted=[...podList].sort((a,b)=>(lastActivity[b.t]||0)-(lastActivity[a.t]||0)||a.i-b.i)" "$FIX/mvp/app.html" \
  && ok "c9d2 既有排序邏輯（lastActivity 決定順序）沒有被改動" || bad "c9d2 排序邏輯疑似被改動，regression"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

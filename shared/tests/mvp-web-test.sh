#!/usr/bin/env bash
# mvp-web-test.sh — Pod 2.1 web 段驗收 fixture（W-C1..C13，spec：mvp-web-gateway-spec-20260707.md §W6）
# 鐵律（Anya 2026-07-07 硬檢查）：FATQ_ROOT 一律 mktemp fixture，絕不指向真實 tasks/。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-web-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0; SKIP=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skipc(){ echo "  ⤳ SKIP $1"; SKIP=$((SKIP+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
REAL_FATQ="/home/oldrabbit/.claude-bots/shared/bin/fatq"
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

# 鐵律（Bella 2026-07-07 22:35 事故通報+builder_fix）：受測 mvp-server.ts 若不支援 MVP_GB
# 環境變數注入，GB 會靜默落回生產路徑寫死值——本腳本下面的假 pods/pods-db 隔離全部失效，
# W-C10~14 的 chat fixture 訊息會直接插進真的生產 gateway-*.db，被真 gateway 派工當真任務執行
# （2026-07-07 22:35~36 事故：assist-anya.db 9 筆、reviewer.db 3 筆，1 筆觸發真 bot session）。
# 跟既有 FATQ_ROOT 鐵律同款：受測代碼不支援就直接拒跑，不留污染窗口。
if ! grep -q "MVP_GB" "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 不支援 MVP_GB 環境變數注入——受測代碼太舊，chat fixture 隔離會失效並寫入生產 pod db，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-web-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
mkdir -p "$FIX/mvp-real" "$FIX/mvp-stub" "$FIX/mvp-nodev" "$FIX/mvp-chat"
for d in mvp-real mvp-stub mvp-nodev mvp-chat; do cp "$SRC/app.html" "$FIX/$d/"; done

# c9d2 W-C10~13：chat 行為（IME 誤觸/double-send 去重、切對象歷史載入、SSE pod 隔離、列表排序）
# 走假 GB（gateway-builder）+ 假 pod db，絕不碰生產 pods/pods-db（帶真 bot 收信會誤觸發真任務！）
FIXGB="$FIX/gb"
mkdir -p "$FIXGB/pods" "$FIX/gb-podsdb"
podjson(){ cat > "$FIXGB/pods/$1.json" <<EOF
{"podName":"$1","bots":[{"name":"$2","model":"claude-sonnet-5"}],"dbPath":"$FIX/gb-podsdb/$1.db"}
EOF
}
podjson assist-anya wcanna
podjson builder wcbuilder
podjson reviewer wcreviewer
for p in assist-anya builder reviewer; do
  sqlite3 "$FIX/gb-podsdb/$p.db" "CREATE TABLE tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bot TEXT NOT NULL, chat_id TEXT NOT NULL, user_id TEXT, user_name TEXT,
    prompt TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT, started_at TEXT, finished_at TEXT, error TEXT,
    tg_message_id INTEGER, channel TEXT NOT NULL DEFAULT 'tg', reply_text TEXT);"
done

# stub CLI：query 回固定 envelope；其他子命令依 stub-exit 檔決定 exit；args 全記 log
cat > "$FIX/stub-fatq" <<'EOS'
#!/usr/bin/env bash
D=$(dirname "$0")
echo "$@" >> "$D/stub-args.log"
if [ "${1:-}" = "query" ]; then
  echo '{"ok":true,"count":1,"tasks":[{"task_id":"stub-task","state":"approval_pending","assigned":null,"reviewer":null,"priority":"P2","goal":"stub","not_before":null,"approval":{"domain":"cross-bot-infra","requested_by":"mac-agent","approvers":["mac-agent"],"expires":"2099-01-01T00:00:00+08:00","return_state":"pending"},"created_at":null,"updated_at":null}]}'
  exit 0
fi
ec=$(cat "$D/stub-exit" 2>/dev/null || echo 0)
if [ "$ec" = "0" ]; then echo '{"ok":true,"task_id":"stub-task","from":"approval_pending/","to":"pending/","history_appended":true}'
else echo "{\"ok\":false,\"code\":\"E_STUB\",\"message\":\"stub exit $ec\"}"; fi
exit "$ec"
EOS
chmod +x "$FIX/stub-fatq"; echo 0 > "$FIX/stub-exit"

start_server(){ # $1=port $2=FATQ_BIN $3=dev(1/0) $4=mvpdir $5=MVP_GB(optional)
  ( export MVP_PORT=$1 FATQ_BIN=$2 MVP_DIR="$FIX/$4" FATQ_ROOT="$FATQ_ROOT"
    if [ "$3" = "1" ]; then export MVP_DEV_MODE=1; else unset MVP_DEV_MODE; fi
    if [ -n "${5:-}" ]; then export MVP_GB="$5"; fi
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P_REAL=18090; P_STUB=18091; P_NODEV=18092; P_CHAT=18093
PID1=$(start_server $P_REAL "$REAL_FATQ" 1 mvp-real)
PID2=$(start_server $P_STUB "$FIX/stub-fatq" 1 mvp-stub)
PID3=$(start_server $P_NODEV "$REAL_FATQ" 0 mvp-nodev)
PID4=$(start_server $P_CHAT "$REAL_FATQ" 1 mvp-chat "$FIXGB")
trap 'kill $PID1 $PID2 $PID3 $PID4 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P_REAL || { echo "FATAL: real 實例起不來"; tail -5 "$FIX/server-$P_REAL.log"; exit 1; }
waitport $P_STUB || { echo "FATAL: stub 實例起不來"; exit 1; }
waitport $P_NODEV || { echo "FATAL: nodev 實例起不來"; exit 1; }
waitport $P_CHAT || { echo "FATAL: chat 實例起不來"; tail -5 "$FIX/server-$P_CHAT.log"; exit 1; }

# 測試身份（fixture 專屬 users.db；identity 用 mac-agent＝現行 CLI 已認的身份）
sqlite3 "$FIX/mvp-real/users.db" "INSERT INTO users (email,name,role,identity,created_at) VALUES
  ('wctest@x.local','wctest','member','mac-agent',datetime('now')),
  ('wcadmin@x.local','wcadmin','admin',NULL,datetime('now')),
  ('wc4b@x.local','wc4b','member','laotu',datetime('now'));"
sqlite3 "$FIX/mvp-stub/users.db" "INSERT INTO users (email,name,role,identity,created_at) VALUES
  ('wcstub@x.local','wcstub','admin','mac-agent',datetime('now'));"
sqlite3 "$FIX/mvp-chat/users.db" "INSERT INTO users (email,name,role,identity,created_at) VALUES
  ('wcchat@x.local','wcchat','admin','mac-agent',datetime('now'));"
# W-C14：member 身份，只綁 assist-anya，用來驗證跨 pod 授權擋
# identity 留 NULL（chat route 不查 identity，只查 role/assistant_bot）——用 'mac-agent' 會撞
# idx_users_identity 這組 partial UNIQUE INDEX（跟上面 wcchat 同 identity），INSERT 會靜默失敗。
sqlite3 "$FIX/mvp-chat/users.db" "INSERT INTO users (email,name,role,assistant_bot,created_at) VALUES
  ('wcmember@x.local','wcmember','member','assist-anya',datetime('now'));"

login(){ curl -sc "$FIX/ck-$3" -X POST -d "email=$2" "http://127.0.0.1:$1/auth/dev-login" -o /dev/null; }
API(){ local port=$1 ck=$2; shift 2; curl -sm 15 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }
CODE(){ local port=$1 ck=$2; shift 2; curl -sm 15 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }

# canary（Bella 22:35 事故通報+builder_fix②）：grep 前置檢查只能防「代碼真的沒引用 MVP_GB 這個字串」
# 這種情況，防不了「代碼有引用但邏輯繞過/我們注入的路徑其實沒生效」這種執行期落差。真的送一則
# canary 訊息、斷言它確實落在 fixture 的假 pod db、且生產 pod db 零新增，兩邊都驗證了才算數。
# 任一項不符＝fixture 隔離已破，立刻 kill 全部 server + exit 1，不跑後面任何會寫入的測試。
login $P_CHAT "wccanary@x.local" canary
sqlite3 "$FIX/mvp-chat/users.db" "UPDATE users SET role='admin' WHERE email='wccanary@x.local';"
CANARY_TXT="canary-$$-$RANDOM"
API $P_CHAT canary -X POST -d "{\"text\":\"$CANARY_TXT\"}" "http://127.0.0.1:$P_CHAT/api/chat/assist-anya" > /dev/null
n_fix=$(sqlite3 "$FIX/gb-podsdb/assist-anya.db" "SELECT COUNT(*) FROM tasks WHERE prompt='$CANARY_TXT'" 2>/dev/null || echo "0")
n_prod=$(sqlite3 /home/oldrabbit/.claude-bots/gateway-builder/pods-db/gateway-assist-anya.db "SELECT COUNT(*) FROM tasks WHERE prompt='$CANARY_TXT'" 2>/dev/null || echo "0")
if [ "$n_fix" != "1" ] || [ "$n_prod" != "0" ]; then
  echo "FATAL: canary 隔離檢查失敗（fixture db 命中=$n_fix 期望 1，生產 db 命中=$n_prod 期望 0）——受測代碼未把 chat 派工正確導向假 GB，可能正在寫入生產 pod db。立即中止，不跑任何後續會寫入的測試。"
  kill $PID1 $PID2 $PID3 $PID4 2>/dev/null
  exit 1
fi
ok "canary：chat 派工確實隔離在 fixture pod db，生產 pod db 零命中"

echo "=== W-C1 身份映射：identity NULL 全寫操作 403、tasks/ 零新檔 ==="
login $P_REAL "wcnull@x.local" null
c1=$(CODE $P_REAL null -X POST -d '{"title":"x","description":"y"}' "http://127.0.0.1:$P_REAL/api/tasks")
c2=$(CODE $P_REAL null -X POST -d '{}' "http://127.0.0.1:$P_REAL/api/approvals/fake-task/approve")
n=$(ls "$FATQ_ROOT/pending" | wc -l)
[ "$c1" = "403" ] && ok "建單 403" || bad "建單→$c1（期望 403）"
[ "$c2" = "403" ] && ok "審批 403" || bad "審批→$c2（期望 403）"
[ "$n" = "0" ] && ok "pending/ 零新檔" || bad "pending/ 有 $n 檔（期望 0）"

echo "=== W-C2 建單需求單（真 CLI）：模板補欄、assigned=anya、history via fatq-cli ==="
login $P_REAL "wctest@x.local" test
r=$(API $P_REAL test -X POST -d '{"title":"W-C2 需求單 fixture","description":"驗證 web→CLI 建單","priority":"P3"}' "http://127.0.0.1:$P_REAL/api/tasks")
tid=$(echo "$r" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)
if [ -n "$tid" ]; then
  ok "建單成功 task_id=$tid"
  f=$(ls "$FATQ_ROOT/pending/"*.json 2>/dev/null | head -1)
  [ "$(ls "$FATQ_ROOT/pending" | wc -l)" = "1" ] && ok "pending/ 恰 1 檔" || bad "pending/ 檔數異常"
  python3 - "$f" <<'PY' && ok "欄位斷言全過（assigned=anya/7必填/via/by）" || bad "欄位斷言失敗"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["assigned"]=="anya", d["assigned"]
for k in ("goal","background","context","deliverables","acceptance_criteria","out_of_scope","review_focus"): assert d.get(k), k
h=[x for x in d["history"] if x.get("action")=="create"][-1]
assert h.get("via")=="fatq-cli" and h.get("by")=="mac-agent", h
PY
else bad "建單失敗：$(echo "$r" | head -c 200)"; fi

echo "=== W-C3 exit→HTTP 映射（stub 逐一回 2/3/4/5/6/7）＋ WQ4 節流 ==="
login $P_STUB "wcstub@x.local" stub
declare -A MAP=( [2]=400 [3]=403 [4]=409 [5]=422 [6]=409 [7]=404 )
for ec in 2 3 4 5 6 7; do
  echo "$ec" > "$FIX/stub-exit"
  got=$(CODE $P_STUB stub -X POST -d '{"title":"m","description":"m"}' "http://127.0.0.1:$P_STUB/api/tasks")
  [ "$got" = "${MAP[$ec]}" ] && ok "exit $ec → ${MAP[$ec]}" || bad "exit $ec → $got（期望 ${MAP[$ec]}）"
done
echo 0 > "$FIX/stub-exit"
# 節流：wcstub 已用 6 次，再打到 10 次為止都應非 429，第 11 次 429
thr="?"
for i in 7 8 9 10 11; do
  thr=$(CODE $P_STUB stub -X POST -d '{"title":"thr","description":"t"}' "http://127.0.0.1:$P_STUB/api/tasks")
done
[ "$thr" = "429" ] && ok "第 11 張 429（每小時 10 張）" || bad "第 11 張→$thr（期望 429）"

echo "=== W-C4 審批：stub 驗 server 側（args/evidence/audit），真 CLI 部分自動偵測 ==="
r=$(API $P_STUB stub -X POST -d '{}' "http://127.0.0.1:$P_STUB/api/approvals/stub-task/approve")
okflag=$(echo "$r" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
[ "$okflag" = "True" ] && ok "web approve → 200 ok" || bad "web approve 失敗：$(echo "$r"|head -c 150)"
grep -q "approval approve stub-task --evidence web:" "$FIX/stub-args.log" \
  && ok "CLI args 含 approval approve + web: evidence" || bad "stub-args.log 缺 approve 呼叫"
grep -q '"action":"approval_approve"' "$FIX/mvp-stub/audit.log" 2>/dev/null \
  && ok "audit.log 有 approval_approve 行" || bad "audit.log 缺行"
# W-C4b（Bella 16:05 REJECT 唯一必修）：真 CLI approval e2e，全鏈跑一遍。
# 偵測法改用 grep source 確認能力常駐（cmd_approval_request 函式存在），不再比對 CLI 錯誤訊息字串
# ——訊息措辭會漂移（上次就是被 fatq-cli 改字撞壞，反向誤報「未上線」）。已上線後不再宣告 SKIP：
# 永久 SKIP 等同覆蓋盲區（Bella 本週已抓到同款隱患兩次），能力消失時本段直接判 FAIL。
if grep -q "cmd_approval_request" "$REAL_FATQ"; then
  login $P_REAL "wc4b@x.local" wc4b
  cat > "$FATQ_ROOT/pending/wc4b-real.json" <<'EOF'
{"task_id":"wc4b-real","status":"pending","assigned":"anna","goal":"W-C4b real e2e fixture","history":[]}
EOF
  rq=$("$REAL_FATQ" approval request wc4b-real --as mac-agent --domain cross-bot-infra --expires 48h --reason "W-C4b real e2e" --json 2>&1)
  echo "$rq" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d.get('ok') is True,d" \
    && ok "CLI approval request 成功" || bad "CLI approval request 失敗：$(echo "$rq"|head -c 200)"
  [ -f "$FATQ_ROOT/approval_pending/wc4b-real.json" ] && ok "任務檔落 approval_pending/" || bad "任務檔未落 approval_pending/"

  ra=$(API $P_REAL wc4b -X POST -d '{}' "http://127.0.0.1:$P_REAL/api/approvals/wc4b-real/approve")
  echo "$ra" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d.get('ok') is True,d" \
    && ok "web approve（laotu，真 CLI 路徑）→ ok" || bad "web approve（真 CLI）失敗：$(echo "$ra"|head -c 200)"
  [ -f "$FATQ_ROOT/pending/wc4b-real.json" ] && ok "核准後回 return_state=pending/" || bad "未回 pending/（return_state 斷裂）"
  python3 - "$FATQ_ROOT/pending/wc4b-real.json" <<'PY' && ok "approval.evidence 帶 web: 前綴" || bad "evidence 欄位斷言失敗"
import json,sys
d=json.load(open(sys.argv[1]))
ev=d.get("approval",{}).get("evidence","")
assert isinstance(ev,str) and ev.startswith("web:"), ev
PY
  python3 - "$FIX/mvp-real/audit.log" <<'PY' && ok "audit.log 有 wc4b-real 的 approval_approve 行" || bad "audit.log 缺 wc4b-real 對應行"
import json,sys
found=False
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("action")=="approval_approve" and d.get("target")=="wc4b-real":
        found=True; break
assert found
PY
else
  bad "W-C4b 前置能力消失：cmd_approval_request 不在 fatq-cli 內（嚴重回歸，approval 子命令疑被移除）"
fi

echo "=== W-C5 未授權審批：identity 不在 approvers → 403、檔案零改動 ==="
cat > "$FATQ_ROOT/approval_pending/wc5-appr.json" <<'EOF'
{"task_id":"wc5-appr","status":"approval_pending","assigned":"anya","goal":"wc5 fixture",
 "approval":{"domain":"cross-bot-infra","requested_by":"anya","approvers":["laotu"],
 "expires":"2099-01-01T00:00:00+08:00","return_state":"pending"},"history":[]}
EOF
sum0=$(md5sum "$FATQ_ROOT/approval_pending/wc5-appr.json")
c5=$(CODE $P_REAL test -X POST -d '{}' "http://127.0.0.1:$P_REAL/api/approvals/wc5-appr/approve")
sum1=$(md5sum "$FATQ_ROOT/approval_pending/wc5-appr.json")
[ "$c5" = "403" ] && ok "非 approvers → 403" || bad "非 approvers → $c5（期望 403）"
[ "$sum0" = "$sum1" ] && ok "檔案零改動" || bad "檔案被改動！"

echo "=== W-C6 SSE：approval_pending 新檔 → admin 2s 內收 type:approval ==="
login $P_REAL "wcadmin@x.local" admin
curl -sN --max-time 6 -b "$FIX/ck-admin" "http://127.0.0.1:$P_REAL/api/events" > "$FIX/sse.out" &
SSEPID=$!
sleep 1
echo '{"task_id":"wc6-appr","approval":{"approvers":[]}}' > "$FATQ_ROOT/approval_pending/wc6-appr.json"
sleep 2
grep -q '"type":"approval"' "$FIX/sse.out" && ok "SSE 收到 approval 事件" || bad "SSE 未收到（$(wc -l <"$FIX/sse.out") 行）"
kill $SSEPID 2>/dev/null

echo "=== W-C7 紅線 grep：mvp-server.ts 零 writeFileSync/renameSync ==="
n=$(grep -cE "writeFileSync|renameSync" "$SRC/mvp-server.ts" || true)
[ "$n" = "0" ] && ok "直寫 API 歸零" || bad "殘留 $n 處 writeFileSync/renameSync"

echo "=== W-C8 dev-login 開關：MVP_DEV_MODE 未設 → 404 ==="
c8=$(curl -sm 5 -o /dev/null -w "%{http_code}" -X POST -d "email=x@x" "http://127.0.0.1:$P_NODEV/auth/dev-login")
[ "$c8" = "404" ] && ok "dev-login 404" || bad "dev-login → $c8（期望 404）"

echo "=== W-C9 前端 tokens 對照：app.html/LOGIN_HTML 深淺色 token 值須與 tokens.css 一致（mvp-ux-redesign SPEC §4 機器對照法） ==="
TOKENS_CSS="/home/oldrabbit/.claude-bots/tasks/design-assets/mvp-ux-redesign/tokens.css"
if [ -f "$TOKENS_CSS" ]; then
  seg(){ awk -v p="$2" 'index($0,p){f=1} f{print} f&&/}/{f=0}' "$1" | grep -oE -- '--[a-z0-9-]+:[^;]+;' | sort -u; }
  seg "$TOKENS_CSS" ':root{' > "$FIX/tok-dark.txt"
  seg "$TOKENS_CSS" '[data-theme="light"]{' > "$FIX/tok-light.txt"
  # app.html：完整 token 集合，dark+light 兩段全比
  seg "$SRC/app.html" ':root{' > "$FIX/app-dark.txt"
  seg "$SRC/app.html" '[data-theme="light"]{' > "$FIX/app-light.txt"
  if diff "$FIX/tok-dark.txt" "$FIX/app-dark.txt" >/dev/null && diff "$FIX/tok-light.txt" "$FIX/app-light.txt" >/dev/null; then
    ok "app.html 深/淺色 token 與 tokens.css 一致"
  else bad "app.html token 與 tokens.css 出入（dark 或 light 區塊）"; fi
  # LOGIN_HTML：僅用到子集，驗證其定義的每個 token 值都與 tokens.css 一致（非全量，允許裁減）
  awk '/const LOGIN_HTML/{f=1} f{print} f&&/^<\/style>|<\/style>/{exit}' "$SRC/mvp-server.ts" > "$FIX/login-block.txt"
  seg "$FIX/login-block.txt" ':root{' > "$FIX/login-dark.txt"
  if [ -s "$FIX/login-dark.txt" ] && comm -23 "$FIX/login-dark.txt" "$FIX/tok-dark.txt" | grep -q .; then
    bad "LOGIN_HTML dark token 與 tokens.css 值不符：$(comm -23 "$FIX/login-dark.txt" "$FIX/tok-dark.txt" | tr '\n' ' ')"
  else ok "LOGIN_HTML dark token 子集與 tokens.css 一致"; fi
else
  skipc "W-C9（tokens.css 設計資產不存在，略過）"
fi

echo "=== W-C10 chat 冪等去重（c9d2）：短窗內同對象+同文字重送 → 回傳同 task_id、DB 僅 1 筆 ==="
login $P_CHAT "wcchat@x.local" chat
r1=$(API $P_CHAT chat -X POST -d '{"text":"dedupe-hello"}' "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
r2=$(API $P_CHAT chat -X POST -d '{"text":"dedupe-hello"}' "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
id1=$(echo "$r1" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)
id2=$(echo "$r2" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)
[ -n "$id1" ] && [ "$id1" = "$id2" ] && ok "重送回傳同 task_id ($id1)" || bad "task_id 不同或缺失：$id1 / $id2"
n=$(sqlite3 "$FIX/gb-podsdb/assist-anya.db" "SELECT COUNT(*) FROM tasks WHERE prompt='dedupe-hello'")
[ "$n" = "1" ] && ok "DB 僅 1 筆（未重插）" || bad "DB 有 $n 筆（期望 1）"

echo "=== W-C11 切對象歷史載入（c9d2）：GET /api/chat/:t 含 bot 欄位、對象隔離不串線 ==="
r3=$(API $P_CHAT chat -X POST -d '{"text":"hist-msg-1"}' "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
id3=$(echo "$r3" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)
sqlite3 "$FIX/gb-podsdb/assist-anya.db" "UPDATE tasks SET status='done', reply_text='pong', finished_at=datetime('now') WHERE id=$id3"
h=$(API $P_CHAT chat "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
echo "$h" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[m for m in d.get('messages',[]) if m.get('prompt')=='hist-msg-1']
assert rows, 'hist-msg-1 不在歷史內'
m=rows[0]
assert m.get('bot')=='wcanna', m.get('bot')
assert m.get('status')=='done', m.get('status')
assert m.get('reply_text')=='pong', m.get('reply_text')
" && ok "歷史含 bot/status/reply_text 正確" || bad "歷史欄位斷言失敗：$(echo "$h"|head -c 200)"
h2=$(API $P_CHAT chat "http://127.0.0.1:$P_CHAT/api/chat/builder")
echo "$h2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
prompts=[m.get('prompt') for m in d.get('messages',[])]
assert 'hist-msg-1' not in prompts and 'dedupe-hello' not in prompts, prompts
" && ok "對象隔離：assist-anya 的訊息不會串進 builder 歷史" || bad "對象隔離失敗：$(echo "$h2"|head -c 200)"

echo "=== W-C12 SSE 回覆推播含 pod 欄位（c9d2）：前端靠此判斷是否為目前對象、避免串線 ==="
curl -sN --max-time 6 -b "$FIX/ck-chat" "http://127.0.0.1:$P_CHAT/api/events" > "$FIX/sse-chat.out" &
SSEPID2=$!
sleep 1
r4=$(API $P_CHAT chat -X POST -d '{"text":"sse-msg-1"}' "http://127.0.0.1:$P_CHAT/api/chat/reviewer")
id4=$(echo "$r4" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))" 2>/dev/null)
sqlite3 "$FIX/gb-podsdb/reviewer.db" "UPDATE tasks SET status='done', reply_text='sse-pong', finished_at=datetime('now') WHERE id=$id4"
sleep 3
grep -q '"type":"reply"' "$FIX/sse-chat.out" && grep -q '"pod":"reviewer"' "$FIX/sse-chat.out" \
  && ok "SSE reply 事件含 pod:reviewer" || bad "SSE 未含預期 pod 欄位（$(wc -l <"$FIX/sse-chat.out") 行）"
kill $SSEPID2 2>/dev/null

echo "=== W-C13 前端結構檢查（c9d2）：IME 誤觸防呆 + 列表按活躍度排序都已接線 ==="
grep -q "isComposing" "$SRC/app.html" && grep -q "compositionstart" "$SRC/app.html" \
  && ok "Enter 送出已擋 IME 組字誤觸（isComposing/compositionstart）" || bad "缺 IME 組字防呆"
grep -q "lastActivity" "$SRC/app.html" && grep -q "renderBotList" "$SRC/app.html" \
  && ok "對話列表已接排序（lastActivity + renderBotList）" || bad "缺列表動態排序邏輯"

echo "=== W-C14 chat 對象授權（Bella REJECT BLOCKER）：member 只能收送自己 /api/me 列出的 pods ==="
login $P_CHAT "wcmember@x.local" member
c14a=$(CODE $P_CHAT member -X POST -d '{"text":"越權測試"}' "http://127.0.0.1:$P_CHAT/api/chat/builder")
[ "$c14a" = "403" ] && ok "member POST 非自己 pod(builder) → 403" || bad "member POST builder → $c14a（期望 403）"
n14=$(sqlite3 "$FIX/gb-podsdb/builder.db" "SELECT COUNT(*) FROM tasks WHERE prompt='越權測試'")
[ "$n14" = "0" ] && ok "builder pod db 零新增（未越權派工）" || bad "builder pod db 被越權插入 $n14 筆"
c14b=$(CODE $P_CHAT member "http://127.0.0.1:$P_CHAT/api/chat/reviewer")
[ "$c14b" = "403" ] && ok "member GET 非自己 pod(reviewer) → 403" || bad "member GET reviewer → $c14b（期望 403）"
c14c=$(CODE $P_CHAT member -X POST -d '{"text":"自己 pod 應該可以"}' "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
[ "$c14c" = "200" ] && ok "member POST 自己 pod(assist-anya) → 200 仍正常" || bad "member 對自己 pod → $c14c（期望 200）"
c14d=$(CODE $P_CHAT chat -X POST -d 'NOT-JSON{{{' "http://127.0.0.1:$P_CHAT/api/chat/assist-anya")
[ "$c14d" != "500" ] && ok "畸形 JSON POST /api/chat 不 500（現為 $c14d）" || bad "畸形 JSON POST /api/chat 仍 500"

echo "=== W-C15（cad5）：/ 回應含 Cache-Control: no-store，避免瀏覽器吃舊快取版本 ==="
ch=$(curl -sm 15 -o /dev/null -D - -b "$FIX/ck-chat" "http://127.0.0.1:$P_CHAT/" | tr -d '\r' | grep -i '^cache-control:')
echo "$ch" | grep -qi 'no-store' && ok "/ 回應含 Cache-Control: no-store" || bad "/ 回應缺 no-store（現為：${ch:-<無 header>}）"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" = "0" ] || exit 1

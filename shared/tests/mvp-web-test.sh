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
# c5e8：重現生產實測撞見的 schema drift——gateway-assist-anya.db 這個真實 pod db
# 建立於 reply_text 欄位加入之前，缺這欄；SELECT 這欄會讓整個請求 500。
# 造一個一樣「缺 reply_text」的假 pod，驗證 webChatPoll/SSE 迴圈都容忍得住。
podjson legacyschema wclegacy
sqlite3 "$FIX/gb-podsdb/legacyschema.db" "CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bot TEXT NOT NULL, chat_id TEXT NOT NULL, user_id TEXT, user_name TEXT,
  prompt TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT, started_at TEXT, finished_at TEXT, error TEXT,
  tg_message_id INTEGER, channel TEXT NOT NULL DEFAULT 'tg');"

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

echo "=== W-C7 紅線 grep：mvp-server.ts 對 task JSON 零 writeFileSync/renameSync（唯一寫入路徑仍是 CLI） ==="
# d1c9 明確、有記錄的例外：附件「檔案本體位元組」寫進 tasks/attachments/ 不是
# task JSON——task JSON 的 metadata 變動走 fatq attach（唯一寫入路徑不變）。這條
# 紅線原意是防「繞過 CLI 直接改 task 狀態」，不是禁止 web 層碰任何檔案 I/O；
# 排除 import 行（只是型別引用，非真的呼叫）後應該恰好 1 處（附件落地那行）。
# b8f4 新增第二類有記錄的例外：`projects/*.json`（薄 project 檔）跟它的附件本體
# ——這條紅線標的是「task JSON」，project 檔是完全不同的資料類型（task_ids 這個
# 唯一需要跟 task 對應的欄位，仍 100% 走 fatq-cli create --project_id 單寫，見
# with_project_lock），所以 project 檔自己的 CRUD 走 web 層直寫是合規的，不是繞過
# CLI。每一行都帶 `// b8f4-project-write` 顯式標記（同慣例：例外要留痕、不能靠
# 「數字對得上」矇混，未來如果這個標記數字變了，代表要重新複查是不是真的都還是
# project 檔操作）。
raw=$(grep -E "writeFileSync|renameSync" "$SRC/mvp-server.ts" | grep -v "^import")
n_total=$(echo "$raw" | grep -c . || true)
n_b8f4=$(echo "$raw" | grep -c "b8f4-project-write" || true)
n=$((n_total - n_b8f4))
[ "$n" = "1" ] && ok "直寫 API 僅 1 處，且是 d1c9 有記錄的附件例外（task JSON 本身仍 100% 走 CLI；另有 $n_b8f4 處 b8f4-project-write 標記的 project 檔例外，非 task JSON）" \
  || { [ "$n" = "0" ] && ok "直寫 API 歸零（另有 $n_b8f4 處 b8f4-project-write 標記的 project 檔例外，非 task JSON）" || bad "扣掉 d1c9/b8f4 兩類有記錄的例外後仍殘留 $n 處 writeFileSync/renameSync（非附件/project 例外，需要複查是否繞過 CLI）"; }

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

echo "=== W-C16（c5e8）：pod db 缺 reply_text 欄位（生產實測 gateway-assist-anya.db 的真實 schema drift）不炸 ==="
c16a=$(CODE $P_CHAT chat -X POST -d '{"text":"legacy schema 測試"}' "http://127.0.0.1:$P_CHAT/api/chat/legacyschema")
[ "$c16a" = "200" ] && ok "缺 reply_text 欄位的 pod 仍可 POST（200）" || bad "缺欄 pod POST → $c16a（期望 200）"
id16=$(sqlite3 "$FIX/gb-podsdb/legacyschema.db" "SELECT id FROM tasks ORDER BY id DESC LIMIT 1")
sqlite3 "$FIX/gb-podsdb/legacyschema.db" "UPDATE tasks SET status='done', finished_at=datetime('now') WHERE id=$id16"
h16=$(API $P_CHAT chat "http://127.0.0.1:$P_CHAT/api/chat/legacyschema")
echo "$h16" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=[m for m in d.get('messages',[]) if m.get('prompt')=='legacy schema 測試']
assert rows, 'legacy schema 測試 不在歷史內：'+repr(d)
assert rows[0].get('reply_text') is None, rows[0].get('reply_text')
" && ok "GET 缺欄位 pod 不 500，reply_text 安全退回 null" || bad "GET 缺欄位 pod 斷言失敗：$(echo "$h16"|head -c 200)"
# SSE 隔離：缺欄 pod 混在輪詢清單中的同一輪，不該拖累其他正常 pod 的推播
sleep 3
n16=$(sqlite3 "$FIX/gb-podsdb/legacyschema.db" "SELECT COUNT(*) FROM tasks WHERE id=$id16 AND status='done'")
[ "$n16" = "1" ] && ok "背景輪詢逐 pod 隔離：缺欄 pod 沒讓 server 掛掉（仍可查詢），未影響其他 pod" || bad "背景輪詢期間狀態異常"

echo "=== W-C17（a1d5）：指揮中心單頁結構——B1/A3 頂條+可摺疊面板都在、監控/用量分頁移出主 nav、2 步駁回接線都在 ==="
grep -q 'id="todobar"' "$SRC/app.html" && grep -q 'id="flowbar"' "$SRC/app.html" \
  && ok "B1 待辦頂條 + A3 流量一眼條都在" || bad "缺 todobar/flowbar"
grep -q 'id="panelMonitor"' "$SRC/app.html" && grep -q 'id="panelUsage"' "$SRC/app.html" \
  && ok "監控/用量可摺疊面板都在" || bad "缺 panelMonitor/panelUsage"
grep -q 'data-pane="monitorPane"' "$SRC/app.html" && bad "監控分頁按鈕不該還留在主 nav（SPEC §2.5 明講移除）" \
  || ok "監控分頁按鈕已從主 nav 移除（頁面本身還在，靠面板連結到達）"
grep -q 'data-pane="usagePane"' "$SRC/app.html" && bad "用量分頁按鈕不該還留在主 nav" \
  || ok "用量分頁按鈕已從主 nav 移除"
grep -q '>待辦<' "$SRC/app.html" && ok "審批分頁已改標「待辦」" || bad "找不到「待辦」nav 標籤"
grep -q 'data-reject' "$SRC/app.html" && grep -q 'tbRejectConfirm' "$SRC/app.html" && grep -q "tbRejectConfirm').disabled" "$SRC/app.html" \
  && ok "駁回二步（reason 必填才能送出）已接線" || bad "缺駁回二步接線"
grep -q "role==='admin'&&usageCache" "$SRC/app.html" && ok "hover 浮層用量列 admin-only 判斷已接線" || bad "缺浮層用量 admin 判斷"
grep -q "role!=='admin'.*panelUsage.*display='none'" "$SRC/app.html" && ok "非 admin 用量面板整塊不留內容（不只 CSS 藏）" || bad "缺非 admin 用量面板隱藏邏輯"
grep -q "pop-active" "$SRC/app.html" && ok "hover 浮層跨手足卡片疊層修復已接線" || bad "缺 pop-active 疊層修復"

echo "=== W-C18（f2a7 wave3）：任務看板/需求追蹤/任務流量三模塊接線都在，各自 pane 有 flex-direction:column 佈局規則 ==="
grep -q 'id="kbBoard"' "$SRC/app.html" && grep -q 'function loadBoard' "$SRC/app.html" && grep -q "api('/api/board')" "$SRC/app.html" \
  && ok "B2 看板已接 kbBoard + loadBoard + /api/board" || bad "B2 看板接線缺漏"
grep -q 'id="requestsPane"' "$SRC/app.html" && grep -q 'function loadRequests' "$SRC/app.html" && grep -q "api('/api/requests')" "$SRC/app.html" \
  && ok "B3 需求追蹤已接 requestsPane + loadRequests + /api/requests" || bad "B3 需求追蹤接線缺漏"
grep -q 'id="flowPane"' "$SRC/app.html" && grep -q 'function loadFlow' "$SRC/app.html" && grep -q "api('/api/flow')" "$SRC/app.html" \
  && ok "A3 任務流量已接 flowPane + loadFlow + /api/flow" || bad "A3 任務流量接線缺漏"
grep -q "gotoPane('flowPane')" "$SRC/app.html" && ok "指揮中心「看完整流量→」已指向 flowPane（不再是 a1d5 當時的 taskPane 佔位）" || bad "fbFull 仍指向舊佔位頁"
grep -q "role==='admin'.*rtLink.*display=''" "$SRC/app.html" && ok "需求追蹤入口連結 admin-only（/api/requests 本身也 403 非 admin）" || bad "缺 rtLink admin-only 顯示邏輯"
grep -q '#requestsPane{flex-direction:column' "$SRC/app.html" && grep -q '#flowPane{flex-direction:column' "$SRC/app.html" \
  && ok "requestsPane/flowPane 都有 flex-direction:column 佈局規則（漏這條會讓內容整塊靠右跑版，f2a7 開發中親遇）" || bad "缺 flex-direction:column，內容會跑版"
grep -q "看板為唯讀投影" "$SRC/app.html" && ok "B2 拖拉跨欄回彈+誠實提示已接線（無真實移動端點，不可假裝成功）" || bad "缺拖拉回彈提示，可能有幽靈狀態轉移"

echo "=== W-C19（d1c9）：需求單附件——建單表單有檔案上傳、任務列有預覽/下載接線 ==="
grep -q 'id="taskAttachInput"' "$SRC/app.html" && grep -q 'id="taskAttachPreview"' "$SRC/app.html" \
  && ok "建單表單已接檔案上傳 input + 預覽區塊" || bad "建單表單缺檔案上傳接線"
grep -q "function attachRowHtml" "$SRC/app.html" && grep -q "function attachUrl" "$SRC/app.html" \
  && ok "任務列附件渲染函式已接線" || bad "缺任務列附件渲染函式"
grep -q "/attachments" "$SRC/app.html" && ok "前端有打附件端點" || bad "前端沒有接附件端點"

echo "=== W-C20（b4a2）：手機自適應——header 真的會換行、觸控目標 44px、對話手機切換、優先級按鈕直排 ==="
# ⚠️這幾條是結構性 regression guard（防止之後改動悄悄拿掉這些修復），不是視覺驗證
# 本身——視覺驗證（375px 無橫向捲動/無重疊）靠 gstack browse 親渲截圖，附在任務
# 交付裡，這支腳本沒有真的瀏覽器排版引擎測不出「看起來擠不擠」。
grep -q "header{flex-wrap:wrap" "$SRC/app.html" && ok "header 在手機斷點真的有 flex-wrap:wrap（舊版 .seg{order:3} 沒配合，從沒生效過）" || bad "缺 header flex-wrap，nav 分頁在窄螢幕會橫向溢出"
grep -q "\.tbtn{width:44px;height:44px}" "$SRC/app.html" && ok "主題切換鈕手機斷點 44px 觸控目標" || bad "主題切換鈕未達 44px 觸控目標"
grep -q "\.seg button{flex:1;padding:10px 6px;min-height:44px" "$SRC/app.html" && ok "nav 分頁按鈕手機斷點 44px 觸控目標" || bad "nav 分頁按鈕未達 44px 觸控目標"
grep -q "\.prio{display:flex;flex-direction:column" "$SRC/app.html" && ok "優先級按鈕手機斷點改直排（原本橫排硬擠成兩行）" || bad "優先級按鈕缺直排修復"
grep -q "#chatPane.chat-open .chat-main{display:flex" "$SRC/app.html" && grep -q "#chatPane.chat-open .list{display:none}" "$SRC/app.html" \
  && ok "對話手機切換已接線（原本 chat-main 手機下永遠 display:none，點聯絡人選了也看不到對話）" || bad "缺對話手機切換接線"
grep -q "classList.add('chat-open')" "$SRC/app.html" && ok "pickTarget() 有觸發手機切換 class" || bad "pickTarget() 沒有觸發 chat-open"
grep -q "^\.conv-hd \.back{display:none}" "$SRC/app.html" && ok "返回鍵桌面版預設隱藏（曾經漏了這條，返回鍵在桌面版會一直顯示）" || bad "返回鍵缺桌面版預設隱藏，會誤顯示"
grep -q "chatBack.*onclick" "$SRC/app.html" && ok "返回鍵有接 click handler" || bad "返回鍵缺 click handler"

echo "=== W-C21（d5c1）：viewer 唯讀身分的寫入動作——選對象/建單前就擋，不讓打完字才 forbidden ==="
grep -q "const chatAllowed = me && (me.role==='admin' || (me.assistant_bot && t===me.assistant_bot))" "$SRC/app.html" \
  && ok "pickTarget() 有算 chatAllowed（跟後端 allowedPods()/chat route 同一份規則，非放寬）" || bad "pickTarget() 缺 chatAllowed 判斷，可能又變回打完字才 forbidden"
grep -q "此功能需 admin 登入才能使用" "$SRC/app.html" && ok "對話/建單都有中性措辭提示（不提 viewer/admin 密碼兩層機制）" || bad "缺中性提示文案"
grep -q "id=\"newTaskGateHint\"" "$SRC/app.html" && ok "建單表單已接 gate hint 元素" || bad "建單表單缺 gate hint 元素"
grep -qF "if(!me.identity){" "$SRC/app.html" && grep -qF "newTask').querySelectorAll('input,textarea,button').forEach(el=>el.disabled=true)" "$SRC/app.html" \
  && ok "建單表單依 me.identity（跟後端 requireIdentity 同一顆變數）禁用，非另訂新規則" || bad "建單表單缺 identity 禁用接線"
grep -q "!chatAllowed" "$SRC/app.html" && ok "pickTarget() 對非允許對象提前 return，不打 GET /api/chat（不留 403 往返痕跡）" || bad "缺 !chatAllowed 提前 return"

echo "=== W-C22（a2c5）：技能天賦樹——分頁接線、真實 /api/skills 資料源、XP/等級誠實標示意、裝備/拆除永遠 disabled、token 不污染全域（W-C9） ==="
grep -qF 'data-pane="skillPane"' "$SRC/app.html" && ok "nav 已接技能樹分頁" || bad "缺技能樹 nav 分頁按鈕"
grep -qF "api('/api/skills')" "$SRC/app.html" && ok "前端拉真實 /api/skills 資料源（非硬寫死 mockup 假資料）" || bad "缺 /api/skills 串接，可能還在用 mockup 假資料"
grep -qF "尚無真實信任帳本資料 · 示意" "$SRC/app.html" && grep -qF "練成度（XP/等級）尚無真實資料來源" "$SRC/app.html" \
  && ok "XP/等級明確標示意，不假裝真實數據誤導（feedback_ui_no_phantom_behavior）" || bad "缺 XP/等級示意標示，可能誤導老兔以為是真實信任帳本資料"
grep -qF "act.disabled=true;" "$SRC/app.html" && grep -qF "admin 動手操作 coming" "$SRC/app.html" \
  && ok "裝備/拆除按鈕永遠 disabled + 明確標 admin 動手操作 coming（第一刀唯讀，不假裝已生效）" || bad "裝備/拆除按鈕可能沒有禁用，會誤導使用者以為真的能操作"
grep -qF "#skillPane{--chart-3:" "$SRC/app.html" && ok "技能樹專屬色 token scope 在 #skillPane，沒有污染全域 :root（W-C9 base token 對照不受影響）" || bad "技能樹 token 可能污染了全域 :root，會撞 W-C9 base tokens.css 對照"
grep -qF '"/api/skills" && req.method === "GET"' "$SRC/mvp-server.ts" && ok "後端 /api/skills 端點已接線" || bad "後端缺 /api/skills 端點"

echo "=== W-C23（a3f8，老兔18202 LIVE 實測抓到）：SSE 回覆比對要同時認 pod 名跟短 bot 名，不能只認 d.pod ==="
# 根因：curTarget 有兩種來源——靜態預設清單(/api/me)給 pod 名(如 assist-caijie-
# zhuchu)，但 f3a8 動態最近對話清單(/api/chat-contacts)給的是短 bot 名(直接來自
# pod db 的 bot 欄位，如 caijie-zhuchu)。SSE payload 的 d.pod 永遠是 pod 名，若
# 比對只認 d.pod===curTarget，從動態清單點進去的對話就永遠對不上、回覆送到了
# 也不會自動浮出，要切走再切回（觸發 pickTarget 重新 fetch）才看得到——這正是
# 老兔實測回報的「聊天窗不即時刷新」症狀。真正的修復是瀏覽器行為（EventSource
# 收到 payload 後 DOM 有沒有更新），這支 curl-only 檔測不出 runtime 行為，改用
# 結構檢查釘住比對邏輯本身沒有退回成只認 d.pod（本單開發時已用 gstack browse
# 實際重現：模擬 pod db 寫回 reply_text 後，動態清單進入的對話原本卡在「處理
# 中」不會消失，加上 d.bot 比對後才會自動換成真回覆，過程詳見任務歷史）。
grep -qF 'd.pod===curTarget||d.bot===curTarget' "$SRC/app.html" \
  && ok "SSE reply 比對同時認 d.pod 跟 d.bot（動態清單短名進入的對話不會被吞掉）" \
  || bad "SSE reply 比對可能只認 d.pod，動態最近對話清單(f3a8)進入的對話會漏接即時回覆"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" = "0" ] || exit 1

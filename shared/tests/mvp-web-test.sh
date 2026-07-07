#!/usr/bin/env bash
# mvp-web-test.sh — Pod 2.1 web 段驗收 fixture（W-C1..C8，spec：mvp-web-gateway-spec-20260707.md §W6）
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

FIX=$(mktemp -d /tmp/mvp-web-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
mkdir -p "$FIX/mvp-real" "$FIX/mvp-stub" "$FIX/mvp-nodev"
for d in mvp-real mvp-stub mvp-nodev; do cp "$SRC/app.html" "$FIX/$d/"; done

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

start_server(){ # $1=port $2=FATQ_BIN $3=dev(1/0) $4=mvpdir
  ( export MVP_PORT=$1 FATQ_BIN=$2 MVP_DIR="$FIX/$4" FATQ_ROOT="$FATQ_ROOT"
    if [ "$3" = "1" ]; then export MVP_DEV_MODE=1; else unset MVP_DEV_MODE; fi
    exec "$BUN" "$SRC/mvp-server.ts" ) >> "$FIX/server-$1.log" 2>&1 &
  echo $!
}
waitport(){ for i in $(seq 1 60); do curl -sm 1 -o /dev/null "http://127.0.0.1:$1/" && return 0; sleep 0.25; done; return 1; }

P_REAL=18090; P_STUB=18091; P_NODEV=18092
PID1=$(start_server $P_REAL "$REAL_FATQ" 1 mvp-real)
PID2=$(start_server $P_STUB "$FIX/stub-fatq" 1 mvp-stub)
PID3=$(start_server $P_NODEV "$REAL_FATQ" 0 mvp-nodev)
trap 'kill $PID1 $PID2 $PID3 2>/dev/null; rm -rf "$FIX"' EXIT
waitport $P_REAL || { echo "FATAL: real 實例起不來"; tail -5 "$FIX/server-$P_REAL.log"; exit 1; }
waitport $P_STUB || { echo "FATAL: stub 實例起不來"; exit 1; }
waitport $P_NODEV || { echo "FATAL: nodev 實例起不來"; exit 1; }

# 測試身份（fixture 專屬 users.db；identity 用 mac-agent＝現行 CLI 已認的身份）
sqlite3 "$FIX/mvp-real/users.db" "INSERT INTO users (email,name,role,identity,created_at) VALUES
  ('wctest@x.local','wctest','member','mac-agent',datetime('now')),
  ('wcadmin@x.local','wcadmin','admin',NULL,datetime('now'));"
sqlite3 "$FIX/mvp-stub/users.db" "INSERT INTO users (email,name,role,identity,created_at) VALUES
  ('wcstub@x.local','wcstub','admin','mac-agent',datetime('now'));"

login(){ curl -sc "$FIX/ck-$3" -X POST -d "email=$2" "http://127.0.0.1:$1/auth/dev-login" -o /dev/null; }
API(){ local port=$1 ck=$2; shift 2; curl -sm 15 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }
CODE(){ local port=$1 ck=$2; shift 2; curl -sm 15 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }

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
if "$REAL_FATQ" approval --as mac-agent --json 2>&1 | grep -q "未知子命令"; then
  skipc "W-C4b 真 CLI approval e2e（Part 2 未上線，落地後重跑本腳本自動涵蓋）"
else
  skipc "W-C4b 真 CLI approval 已上線但 e2e 斷言未實作——Part 2 落地時補（防呆：不假綠）"
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

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" = "0" ] || exit 1

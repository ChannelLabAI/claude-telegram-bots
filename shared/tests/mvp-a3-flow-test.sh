#!/usr/bin/env bash
# mvp-a3-flow-test.sh — A3 任務流量後端驗收 fixture（task 20260708-1301-78b4-mvp-A3-backend）
# 鐵律（同 mvp-web-test.sh）：一律 mktemp 自造態 FATQ_ROOT，絕不碰生產 tasks/。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-a3-flow-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"

if ! grep -q "/api/flow" "$SRC/mvp-server.ts" 2>/dev/null; then
  echo "FATAL: $SRC/mvp-server.ts 不支援 /api/flow 端點——受測代碼太舊/回歸，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-a3-flow-test-XXXXXX)
export FATQ_ROOT="$FIX/tasks"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
export MVP_DIR="$FIX/mvp"
export MVP_GB="$FIX/gb"
export MVP_DEV_MODE=1
export MVP_PORT=18198
mkdir -p "$FIX/mvp" "$FIX/gb/pods" \
  "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
cp "$SRC/app.html" "$FIX/mvp/"

# 今日/昨日日期字串（Asia/Taipei，跟受測代碼算法同一時區）
TODAY=$(TZ=Asia/Taipei date +%Y-%m-%d)
YEST=$(TZ=Asia/Taipei date -d 'yesterday' +%Y-%m-%d)

mktask(){ # $1=dir $2=file $3=created_by $4=history_json
  cat > "$FATQ_ROOT/$1/$2.json" <<EOF
{"task_id":"$2","assigned":"x","created_by":"$3","history":$4}
EOF
}

# done/：2 筆今日完成、1 筆昨日完成 → doneToday=2, done7d=3, doneCount=3
mktask done fx-done-1 anya "[{\"ts\":\"${TODAY}T10:00:00+08:00\",\"to\":\"done/\"}]"
mktask done fx-done-2 anya "[{\"ts\":\"${TODAY}T11:00:00+08:00\",\"to\":\"done/\"}]"
mktask done fx-done-3 anya "[{\"ts\":\"${YEST}T09:00:00+08:00\",\"to\":\"done/\"}]"
# rejected/：2 筆 execution_error 退件事件 → rejectRatio = 2/(7d done 3 + 退件 2) = 0.4
# 後端 B3 口徑已改為讀 history verdict_reject，且只計 issue_type=execution_error；
# rejected/ 目錄快照不再直接等於退件 KPI。
mktask rejected fx-rej-1 anya "[{\"ts\":\"${TODAY}T12:00:00+08:00\",\"action\":\"verdict_reject\",\"issue_type\":\"execution_error\"}]"
mktask rejected fx-rej-2 anya "[{\"ts\":\"${YEST}T12:00:00+08:00\",\"action\":\"verdict_reject\",\"issue_type\":\"execution_error\"}]"
# review/：1 筆，created_by=anya（eng）→ inReview=1，也計入 lineLoad
mktask review fx-review-1 anya "[]"
# pending/：anya(eng) + caijie-zhuchu(ops)
mktask pending fx-p-1 anya "[]"
mktask pending fx-p-2 caijie-zhuchu "[]"
# in_progress/：ron-assistant(con) + unknown-owner(other)
mktask in_progress fx-ip-1 ron-assistant "[]"
mktask in_progress fx-ip-2 nobody-unmapped "[]"

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

login(){ curl -sc "$FIX/ck" -X POST -d "email=$1" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null; }
API(){ curl -sm 10 -b "$FIX/ck" -H "content-type: application/json" "$@"; }
CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" -b "$FIX/ck" -H "content-type: application/json" "$@"; }

echo "=== A3-1 未登入 → /api/flow 401 ==="
rm -f "$FIX/ck"; touch "$FIX/ck"
c=$(CODE "http://127.0.0.1:$MVP_PORT/api/flow")
[ "$c" = "401" ] && ok "未登入 401" || bad "未登入→$c（期望 401）"

login "a3test@x.local"
r=$(API "http://127.0.0.1:$MVP_PORT/api/flow")

echo "=== A3-2 doneToday：今日 2 筆、昨日 1 筆不計入 ==="
echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['doneToday']==2, d['doneToday']
" && ok "doneToday=2" || bad "doneToday 斷言失敗：$(echo "$r"|head -c 300)"

echo "=== A3-3 reviewOutcome：inReview=1 rejected=2 done=3 rejectRatio=0.4（7d execution_error 口徑） ==="
echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)['reviewOutcome']
assert d['inReview']==1, d
assert d['rejected']==2, d
assert d['done']==3, d
assert abs(d['rejectRatio']-0.4)<1e-9, d
" && ok "reviewOutcome 斷言全過" || bad "reviewOutcome 斷言失敗：$(echo "$r"|head -c 300)"

echo "=== A3-4 lineLoad：eng=2(pending+review) ops=1 con=1 other=1 ==="
echo "$r" | python3 -c "
import json,sys
d={x['line']:x['active'] for x in json.load(sys.stdin)['lineLoad']}
assert d.get('eng')==2, d
assert d.get('ops')==1, d
assert d.get('con')==1, d
assert d.get('other')==1, d
" && ok "lineLoad 斷言全過" || bad "lineLoad 斷言失敗：$(echo "$r"|head -c 300)"

echo "=== A3-5 隔離：測試期間生產 tasks/ 目錄零新增 ==="
n=$(find "$REAL_TASKS/pending" "$REAL_TASKS/done" -name 'fx-*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "0" ] && ok "生產 tasks/ 零 fixture 殘留" || bad "生產 tasks/ 出現 $n 個 fixture 檔！隔離失效"

kill $SPID 2>/dev/null
echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

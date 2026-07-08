#!/usr/bin/env bash
# mvp-project-team-test.sh — b8f4 專案小組 MVP 驗收 fixture
# （task 20260709-0202-b8f4-project-team-mvp-build）
#
# 涵蓋 Bella 5 硬紅線：①viewer(identity=NULL) 打 POST/PATCH /api/projects → 403
# （requireIdentity，非 role gate，防 c8b4 破口重演）②project_id 走 fatq-cli
# task_create 當下寫入（非 web 直改 task JSON）③project 檔並發鎖（無 lost update）
# ④附件複用 d1c9 驗證（magic bytes/uuid 存，非原始路徑）⑤owner=identity（owner-
# scoping，admin bypass）。另涵蓋 RL1（老兔說 go 前不建 pending）、RL2（既有
# FATQ 零改）、附件下載 registered-only、對話串 project_id chat_id 隔離。
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
CLI_SRC="${FATQ_CLI_SRC:-/home/oldrabbit/.claude-bots/.worktrees/20260709-0202-b8f4-project-team-mvp-build/shared/bin/fatq-cli.sh}"

for v in PROJECTS_ROOT MVP_PROJECT_ATTACHMENTS_DIR; do
  if ! grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null; then
    echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑。"
    exit 1
  fi
done
if ! grep -q -- "--project_id" "$CLI_SRC" 2>/dev/null; then
  echo "FATAL: $CLI_SRC 不支援 --project_id，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/mvp-proj-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,wont_do,design_review,approval_pending}
mkdir -p "$FIX/projects/archived" "$FIX/files"

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export FATQ_BIN="$CLI_SRC"
export PROJECTS_ROOT="$FIX/projects"
export MVP_PROJECT_ATTACHMENTS_DIR="$FIX/projects/attachments"
export MVP_ATTACHMENT_MAX_BYTES=2000000
export MVP_ATTACHMENT_MAX_COUNT=3
export MVP_DEV_MODE=1
export MVP_PORT=18931
REAL_GB="/home/oldrabbit/.claude-bots/gateway-builder"
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }

# 一個假 assist-anya pod（給 /api/chat/assist-anya intake 用）
cat > "$FIX/gb/pods/anya.json" <<EOF
{"podName":"assist-anya","dbPath":"$FIX/gb/anya.db","bots":[{"name":"assist-anya","model":"claude-sonnet"}]}
EOF
sqlite3 "$FIX/gb/anya.db" "CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, bot TEXT, chat_id TEXT, user_id TEXT, user_name TEXT, prompt TEXT, status TEXT DEFAULT 'pending', reply_text TEXT, created_at TEXT, finished_at TEXT, channel TEXT);"

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$2" -X POST -d "email=$1" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null; }
CODE(){ local ck=$1; shift; curl -sm 10 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" "$@"; }
API(){ local ck=$1; shift; curl -sm 10 -b "$FIX/ck-$ck" "$@"; }

login "owner@x.local" owner
# anna 是 team-config.json 真實已知 identity；額外綁 assistant_bot=assist-anya——
# owner-scoping（project）與既有 c9d2 W-C14 一般對話白名單（allowedPods，非
# b8f4 範圍，此測試不動它）是兩套獨立授權來源，owner 要能同時走「自己專案的
# 聊天窗」跟「一般對話分頁」兩條路徑，才測得出 P15 的 thread 隔離斷言。
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET identity='anna', assistant_bot='assist-anya' WHERE email='owner@x.local';"
login "other@x.local" other
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET identity='bella' WHERE email='other@x.local';"  # 另一個真實身份，當非 owner
login "admin@x.local" admin
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='admin' WHERE email='admin@x.local';"       # admin bypass（identity 仍可為 NULL，測 role-only bypass）
login "viewer@x.local" viewer   # dev-login 預設 role=member、identity=NULL，同 c8b4 密碼閘 viewer 處境

# 合法 PNG（真 magic bytes）
python3 -c "
import struct, zlib
sig = b'\x89PNG\r\n\x1a\n'
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag+data))
ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
idat = zlib.compress(b'\x00\xff\x00\x00')
png = sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open('$FIX/files/real.png', 'wb').write(png)
"
printf 'this is not actually a png' > "$FIX/files/fake.png"

echo "=== P1 identity 使用者開專案（含合法附件）→ 200，owner=識別身份，附件走 uuid 存 ==="
r1=$(API owner -X POST \
  -F "title=GEO 報告優化" -F "goal=提升能見度" -F 'member_bots=["twinkle","anna"]' -F "priority=P1" \
  -F "file=@$FIX/files/real.png;type=image/png" \
  "http://127.0.0.1:$MVP_PORT/api/projects")
PID1=$(echo "$r1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
p=d['project']
assert p['owner']=='anna', p            # 紅線⑤：owner=identity，非自由字串
assert p['title']=='GEO 報告優化', p
assert p['member_bots']==['twinkle','anna'], p
assert len(p['attachments'])==1, p
att=p['attachments'][0]
assert att['name']=='real.png', att
import re
assert re.match(r'^[0-9a-f-]+\.png$', att['file']), att   # uuid 存檔名，非原始檔名/路徑
print(p['project_id'])
") || { bad "P1 建專案回應斷言失敗：$(echo "$r1"|head -c 400)"; PID1=""; }
[ -n "$PID1" ] && ok "identity 使用者開專案成功，owner=identity、附件走 uuid 存" || bad "P1 建專案失敗"

echo "=== P1b 附件真的落地在 PROJECTS_ROOT/attachments/<id>/，project JSON 沒有原始路徑字串 ==="
if [ -n "$PID1" ]; then
  proj_file=$(find "$FIX/projects" -maxdepth 1 -name "${PID1}.json")
  grep -q "$FIX/files/real.png" "$proj_file" && bad "project JSON 竟然存了原始上傳路徑！違反紅線④" || ok "project JSON 未存原始檔案路徑"
  [ -d "$FIX/projects/attachments/$PID1" ] && ok "附件目錄以 project_id 分隔落地" || bad "附件目錄未落地"
fi

echo "=== P1c（RL1 核心）：開專案本身不建任何 FATQ pending 任務 ==="
pending_count=$(find "$FIX/tasks/pending" -name "*.json" | wc -l | tr -d ' ')
[ "$pending_count" = "0" ] && ok "開專案後 pending/ 仍是 0 筆（RL1：對話式 gate，不自動開單）" || bad "開專案後 pending/ 出現 $pending_count 筆，RL1 被違反！"

echo "=== P2（紅線①核心）：唯讀 viewer（identity=NULL，role=member）POST /api/projects → 403 ==="
c2=$(CODE viewer -X POST -F "title=x" -F "goal=y" -F 'member_bots=[]' "http://127.0.0.1:$MVP_PORT/api/projects")
[ "$c2" = "403" ] && ok "viewer 開專案 → 403（requireIdentity，非 role==member gate，防 c8b4 破口重演）" || bad "viewer 開專案 → $c2（期望 403）"

echo "=== P3 未登入 POST /api/projects → 401 ==="
c3=$(curl -sm 10 -o /dev/null -w "%{http_code}" -X POST -F "title=x" -F "goal=y" "http://127.0.0.1:$MVP_PORT/api/projects")
[ "$c3" = "401" ] && ok "未登入開專案 → 401" || bad "未登入開專案 → $c3（期望 401）"

echo "=== P4（紅線⑤核心）：GET /api/projects 清單 owner-scoped ==="
listed_owner=$(API owner "http://127.0.0.1:$MVP_PORT/api/projects" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['projects']))")
listed_other=$(API other "http://127.0.0.1:$MVP_PORT/api/projects" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['projects']))")
listed_admin=$(API admin "http://127.0.0.1:$MVP_PORT/api/projects" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['projects']))")
listed_viewer=$(API viewer "http://127.0.0.1:$MVP_PORT/api/projects" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['projects']))")
[ "$listed_owner" = "1" ] && ok "owner 看得到自己的 1 筆專案" || bad "owner 專案清單筆數=$listed_owner（期望 1）"
[ "$listed_other" = "0" ] && ok "非 owner 看不到別人的專案（清單為空）" || bad "非 owner 清單筆數=$listed_other（期望 0）"
[ "$listed_admin" = "1" ] && ok "admin 看得到全部專案" || bad "admin 專案清單筆數=$listed_admin（期望 1）"
[ "$listed_viewer" = "0" ] && ok "viewer（identity=NULL）清單為空（owner 永遠比對不到）" || bad "viewer 清單筆數=$listed_viewer（期望 0）"

echo "=== P5（AC5 核心，紅線⑤）：非 owner 讀他人專案詳情 → 403；owner/admin → 200 ==="
c5a=$(CODE other "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c5a" = "403" ] && ok "非 owner 讀他人專案詳情 → 403" || bad "非 owner 讀詳情 → $c5a（期望 403）"
c5b=$(CODE owner "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c5b" = "200" ] && ok "owner 讀自己專案詳情 → 200" || bad "owner 讀詳情 → $c5b（期望 200）"
c5c=$(CODE admin "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c5c" = "200" ] && ok "admin bypass 讀任意專案詳情 → 200" || bad "admin 讀詳情 → $c5c（期望 200）"
c5d=$(CODE viewer "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c5d" = "403" ] && ok "viewer 讀他人專案詳情 → 403" || bad "viewer 讀詳情 → $c5d（期望 403）"

echo "=== P6（紅線①）：viewer PATCH /api/projects/:id → 403 ==="
c6=$(CODE viewer -X PATCH -H "content-type: application/json" -d '{"archive":true}' "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c6" = "403" ] && ok "viewer PATCH 專案 → 403" || bad "viewer PATCH → $c6（期望 403）"

echo "=== P7 非 owner PATCH 他人專案 → 403；owner PATCH 自己專案（member_bots）→ 200 ==="
c7a=$(CODE other -X PATCH -H "content-type: application/json" -d '{"member_bots":["bella"]}' "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c7a" = "403" ] && ok "非 owner PATCH 他人專案 → 403" || bad "非 owner PATCH → $c7a（期望 403）"
r7b=$(API owner -X PATCH -H "content-type: application/json" -d '{"member_bots":["twinkle","anna","bella"]}' "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
echo "$r7b" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert d['project']['member_bots']==['twinkle','anna','bella'], d
" && ok "owner PATCH member_bots 成功" || bad "owner PATCH member_bots 失敗：$(echo "$r7b"|head -c 300)"

echo "=== P8（紅線②核心）：fatq-cli task_create --project_id 掛回 project.task_ids ==="
before_ids=$(cat "$FIX/projects/${PID1}.json" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('task_ids',[])))")
FATQ_ROOT="$FIX/tasks" PROJECTS_ROOT="$FIX/projects" "$CLI_SRC" create \
  --goal "子任務一" --background b --context c --deliverables '["d"]' \
  --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus rf \
  --assigned anna --as anya --json --project_id "$PID1" > "$FIX/cli-create-1.json"
TID1=$(python3 -c "import json;print(json.load(open('$FIX/cli-create-1.json'))['task_id'])")
after_ids=$(cat "$FIX/projects/${PID1}.json" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('task_ids',[])))")
[ "$after_ids" = "$((before_ids+1))" ] && ok "fatq-cli create --project_id 成功把 task_id 掛回 project.task_ids" || bad "task_ids 掛回失敗：$before_ids -> $after_ids"
grep -q "\"$TID1\"" "$FIX/projects/${PID1}.json" && ok "project 檔的 task_ids 含新建的 task_id" || bad "project 檔沒有找到新 task_id"

echo "=== P8b task JSON 的 project_id 是在 create 當下由 CLI 寫入（非 web 事後改） ==="
grep -q "\"project_id\": \"$PID1\"" "$FIX/tasks/pending/${TID1}.json" && ok "task JSON 的 project_id 由 CLI create 當下寫入" || bad "task JSON 缺 project_id 欄位"

echo "=== P8c project_id 對應到不存在的專案 → CLI 拒絕（E_USAGE），不建立孤兒 task ==="
before_pending=$(find "$FIX/tasks/pending" -name "*.json" | wc -l | tr -d ' ')
FATQ_ROOT="$FIX/tasks" PROJECTS_ROOT="$FIX/projects" "$CLI_SRC" create \
  --goal g --background b --context c --deliverables '["d"]' \
  --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus rf \
  --as anya --json --project_id "does-not-exist" > "$FIX/cli-create-bad.json" 2>/dev/null
cli_exit=$?
after_pending=$(find "$FIX/tasks/pending" -name "*.json" | wc -l | tr -d ' ')
[ "$cli_exit" = "2" ] && ok "不存在的 project_id → CLI exit 2（E_USAGE）" || bad "不存在的 project_id → exit=$cli_exit（期望 2）"
[ "$before_pending" = "$after_pending" ] && ok "拒絕時沒有建立孤兒 task" || bad "竟然建立了孤兒 task！$before_pending -> $after_pending"

echo "=== P9（紅線③核心）：project 檔並發鎖——5 個 fatq-cli create 併發掛同一個 project，無 lost update ==="
race_pids=()
for i in 1 2 3 4 5; do
  ( FATQ_ROOT="$FIX/tasks" PROJECTS_ROOT="$FIX/projects" "$CLI_SRC" create \
    --goal "race-$i" --background b --context c --deliverables '["d"]' \
    --acceptance_criteria '["a"]' --out_of_scope '["o"]' --review_focus rf \
    --as anya --json --project_id "$PID1" > "$FIX/race-$i.json" ) &
  race_pids+=($!)
done
# 只等這 5 個 race 子 process——裸 `wait`(無參數)會連早先背景啟動、常駐不會
# 自己結束的 mvp-server（$SPID）都一起等，直接卡死整支腳本，這是本檔第一版
# 踩到的真坑（跑起來 3+ 分鐘 0% CPU 無任何子行程，wait4 卡住），改成明確列 PID。
wait "${race_pids[@]}"
after_race=$(cat "$FIX/projects/${PID1}.json" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('task_ids',[])))")
[ "$after_race" = "$((after_ids+5))" ] && ok "5 個併發 create 全部掛進 task_ids，無 lost update（$after_ids -> $after_race）" || bad "併發掛回筆數不對：$after_ids -> $after_race（期望 $((after_ids+5))）"

echo "=== P10 GET /api/projects/:id 的 rollup 正確算 task_ids 對應狀態 ==="
r10=$(API owner "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
echo "$r10" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['rollup']['total']>=6, d['rollup']   # 1(P8) + 5(P9)
assert d['rollup']['done']==0, d['rollup']    # 都還在 pending，沒有 done
" && ok "詳情頁 rollup 正確反映子任務數與完成度" || bad "rollup 斷言失敗：$(echo "$r10"|head -c 300)"

echo "=== P11（紅線④）：附件下載 registered-only——owner 下載成功、非 owner 403、偽路徑 404 ==="
att_file=$(API owner "http://127.0.0.1:$MVP_PORT/api/projects/$PID1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['attachments'][0]['file'])
")
hdr11=$(curl -sm 10 -D - -o "$FIX/downloaded.png" -b "$FIX/ck-owner" "http://127.0.0.1:$MVP_PORT/api/projects/$PID1/attachments/$att_file")
echo "$hdr11" | grep -qi "content-disposition: inline" && ok "owner 下載圖檔附件 → inline" || bad "owner 下載附件 disposition 錯誤：$(echo "$hdr11"|grep -i disposition)"
cmp -s "$FIX/files/real.png" "$FIX/downloaded.png" && ok "下載內容與上傳位元組一致" || bad "下載內容不一致！"
c11b=$(CODE other "http://127.0.0.1:$MVP_PORT/api/projects/$PID1/attachments/$att_file")
[ "$c11b" = "403" ] && ok "非 owner 下載他人專案附件 → 403" || bad "非 owner 下載附件 → $c11b（期望 403）"
c11c=$(CODE owner "http://127.0.0.1:$MVP_PORT/api/projects/$PID1/attachments/..%2f..%2f..%2fetc%2fpasswd")
[ "$c11c" = "404" ] && ok "路徑穿越字串 → 404（registered-only，不信任 URL 檔名）" || bad "路徑穿越 → $c11c（期望 404）"

echo "=== P12 附件 magic bytes 驗證同 d1c9：偽造型別 → 400，不落地 ==="
c12=$(CODE owner -X POST -F "title=x2" -F "goal=y2" -F 'member_bots=[]' \
  -F "file=@$FIX/files/fake.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/projects")
[ "$c12" = "400" ] && ok "偽造 PNG（magic bytes 不符）建專案 → 400" || bad "偽造 PNG → $c12（期望 400）"

echo "=== P13（紅線③）：歸檔（PATCH archive:true）—— 檔案搬進 archived/，GET 仍可用 ==="
r13=$(API owner -X PATCH -H "content-type: application/json" -d '{"archive":true}' "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
echo "$r13" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d['project']['status']=='archived',d" \
  && ok "歸檔 PATCH 成功，status=archived" || bad "歸檔失敗：$(echo "$r13"|head -c 300)"
[ -f "$FIX/projects/archived/${PID1}.json" ] && ok "歸檔後檔案已搬進 projects/archived/" || bad "歸檔後檔案沒有搬進 archived/"
[ ! -f "$FIX/projects/${PID1}.json" ] && ok "歸檔後不再留在 projects/ 主目錄" || bad "歸檔後主目錄仍有殘留檔"
c13b=$(CODE owner "http://127.0.0.1:$MVP_PORT/api/projects/$PID1")
[ "$c13b" = "200" ] && ok "歸檔後 owner 仍可讀取詳情（跨目錄查找）" || bad "歸檔後讀取失敗 → $c13b"

echo "=== P14（對話串 project_id 隔離）：intake 訊息確實寫進 pod db 且 chat_id 帶 project_id ==="
proj_chat_rows=$(sqlite3 "$FIX/gb/anya.db" "SELECT COUNT(*) FROM tasks WHERE chat_id LIKE 'web:%:proj:$PID1'")
[ "$proj_chat_rows" -ge "1" ] && ok "intake 訊息 chat_id 帶 project_id（跟一般對話 thread 隔離）" || bad "intake chat_id 未正確 tag project_id，筆數=$proj_chat_rows"

echo "=== P15 /api/chat/assist-anya?project_id=... 只回該專案 thread、不混一般對話 ==="
# 先送一則「一般對話」（不帶 project_id）
API owner -X POST -H "content-type: application/json" -d '{"text":"一般對話，非專案"}' "http://127.0.0.1:$MVP_PORT/api/chat/assist-anya" > /dev/null
proj_msgs=$(API owner "http://127.0.0.1:$MVP_PORT/api/chat/assist-anya?since=0&project_id=$PID1" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['messages']))")
general_msgs=$(API owner "http://127.0.0.1:$MVP_PORT/api/chat/assist-anya?since=0" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['messages']))")
[ "$proj_msgs" = "1" ] && ok "專案對話串只看得到 intake 那 1 則（不含一般對話）" || bad "專案對話串筆數=$proj_msgs（期望 1）"
[ "$general_msgs" = "1" ] && ok "一般對話 thread 只看得到剛送的 1 則（不含專案 intake）" || bad "一般對話串筆數=$general_msgs（期望 1）"

echo "=== P16（chat route 也要 owner-scoping）：非 owner 對別人的 project_id 聊天 → 403 ==="
c16=$(CODE other -X POST -H "content-type: application/json" -d "{\"text\":\"x\",\"project_id\":\"$PID1\"}" "http://127.0.0.1:$MVP_PORT/api/chat/assist-anya")
[ "$c16" = "403" ] && ok "非 owner 對他人 project_id 聊天 → 403" || bad "非 owner 聊天 → $c16（期望 403）"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

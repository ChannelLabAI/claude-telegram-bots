#!/usr/bin/env bash
# mvp-hub-test.sh — e6f4「統一工作中樞」唯讀端點驗收 fixture（/api/team-roster + /api/hub）
# 鐵律：FATQ_ROOT/PROJECTS_ROOT/MVP_TEAM_CONFIG 一律 mktemp fixture，絕不指向生產。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-hub-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in '"/api/team-roster"' '"/api/hub"'; do
  grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null || { echo "FATAL: $SRC/mvp-server.ts 缺 $v，拒跑"; exit 1; }
done

FIX=$(mktemp -d /tmp/mvp-hub-test-XXXXXX)
REAL_TASKS="/home/oldrabbit/.claude-bots/tasks"
export FATQ_ROOT="$FIX/tasks"
export PROJECTS_ROOT="$FIX/projects"
export MVP_TEAM_CONFIG="$FIX/team-config.json"
export MVP_DIR="$FIX/mvp"
export MVP_GB="$FIX/gb"
export MVP_DEV_MODE=1
export MVP_PORT="${MVP_PORT:-18400}"
[ "$FATQ_ROOT" = "$REAL_TASKS" ] && { echo "FATAL: fixture 指向生產 tasks/，拒跑"; exit 1; }
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,design_review,approval_pending}
mkdir -p "$FIX/projects/archived" "$FIX/mvp" "$FIX/gb/pods"

# ── 假 team-config：3 個候選 lead（含被 c3f7 排除的 anya，驗證她不會出現在
#    /api/team-roster 的 leads 清單）+ builder/reviewer/designer 三桶 ──
cat > "$FIX/team-config.json" <<'EOF'
{
  "assistants": [
    {"name":"Anya","state_dir":"anya","role":"特助"},
    {"name":"Panda","state_dir":"ron-assistant","role":"特助"}
  ],
  "shared_pools": {
    "builder": [{"name":"Anna","state_dir":"anna"},{"name":"三菜","state_dir":"sancai"}],
    "reviewer": [{"name":"Bella","state_dir":"Bella"}],
    "designer": [{"name":"星星人","state_dir":"twinkle"}]
  }
}
EOF

# ── 假任務（4 態各放幾張）：一張掛進某專案的 task_ids（不該出現在 loose）、
#    一張 assigned 給 owner-a、一張 assigned 給 owner-b（負面案例用）、一張
#    created_by=owner-a 但未指派（驗 created_by fallback）──
cat > "$FATQ_ROOT/pending/claimed-task.json" <<'EOF'
{"task_id":"claimed-task","goal":"已歸屬某專案的任務","priority":"P2","assigned":"owner-a","created_at":"2026-07-09T01:00:00+08:00","history":[]}
EOF
cat > "$FATQ_ROOT/pending/owner-a-task.json" <<'EOF'
{"task_id":"owner-a-task","goal":"owner-a 自己的散單","priority":"P2","assigned":"owner-a","created_at":"2026-07-09T02:00:00+08:00","history":[]}
EOF
cat > "$FATQ_ROOT/in_progress/owner-b-task.json" <<'EOF'
{"task_id":"owner-b-task","goal":"owner-b 自己的散單(不該被 owner-a 看到)","priority":"P1","assigned":"owner-b","created_at":"2026-07-09T03:00:00+08:00","history":[]}
EOF
cat > "$FATQ_ROOT/review/owner-a-created.json" <<'EOF'
{"task_id":"owner-a-created","goal":"owner-a 建立但未指派","background":"完整背景文字","priority":"P3","created_by":"owner-a","created_at":"2026-07-09T04:00:00+08:00","acceptance_criteria":["AC one","AC two"],"verify_commands":[{"cmd":["echo","ok"],"desc":"fixture verify"}],"history":[{"ts":"2026-07-09T04:10:00+08:00","by":"owner-a","action":"create"},{"ts":"2026-07-09T04:20:00+08:00","by":"bella","action":"submit"}]}
EOF
cat > "$FATQ_ROOT/rejected/owner-a-rejected.json" <<'EOF'
{"task_id":"owner-a-rejected","goal":"owner-a 被退件的散單","priority":"P1","assigned":"owner-a","created_at":"2026-07-09T06:00:00+08:00","history":[{"ts":"2026-07-09T06:30:00+08:00","by":"bella","action":"verdict_reject"}]}
EOF
# 老兔18221：project_id 對得上、但沒同步進 project.task_ids 陣列的孤兒任務——
# 穩健版 roll-up 該把它算進專案進度、也該從 loose 排除，不能兩邊都漏接。
cat > "$FATQ_ROOT/done/orphan-project-task.json" <<'EOF'
{"task_id":"orphan-project-task","goal":"手寫、project_id對但task_ids沒同步的單","priority":"P2","project_id":"proj-a","assigned":"owner-a","created_at":"2026-07-09T05:00:00+08:00","history":[]}
EOF

# ── 假專案：owner-a 自己的一個專案，task_ids 包含 claimed-task（驗證它不進 loose）
cat > "$FIX/projects/proj-a.json" <<'EOF'
{"project_id":"proj-a","title":"Owner-A 的專案","goal":"g","owner":"owner-a","lead_assistant":"ron-assistant",
 "member_bots":[],"status":"active","attachments":[],"task_ids":["claimed-task"],"priority":"P2","created_at":"2026-07-09T00:30:00+08:00","history":[]}
EOF
cat > "$FIX/projects/archived/proj-old.json" <<'EOF'
{"project_id":"proj-old","title":"封存專案","goal":"old","owner":"owner-a","lead_assistant":"ron-assistant",
 "member_bots":[],"status":"archived","attachments":[],"task_ids":[],"priority":"P3","created_at":"2026-07-08T00:30:00+08:00","history":[]}
EOF

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

CK_A="$FIX/ck-a"; CK_B="$FIX/ck-b"; CK_ADMIN="$FIX/ck-admin"
curl -sc "$CK_A" -X POST -d "email=owner-a@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='member', identity='owner-a' WHERE email='owner-a@x.local';"
curl -sc "$CK_B" -X POST -d "email=owner-b@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='member', identity='owner-b' WHERE email='owner-b@x.local';"
curl -sc "$CK_ADMIN" -X POST -d "email=admin@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='admin' WHERE email='admin@x.local';"

API(){ local ck="$1"; shift; curl -sm 10 -b "$ck" "$@"; }

echo "=== H1 /api/team-roster：leads 只含白名單內的 7 選 2（排除 anya，c3f7 定案）==="
R1=$(API "$CK_A" "http://127.0.0.1:$MVP_PORT/api/team-roster")
echo "$R1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=[l['stateDir'] for l in d['leads']]
assert 'anya' not in ids, ids
assert ids==['ron-assistant'], ids
" && ok "leads 排除 anya、只含白名單內的 ron-assistant" || bad "leads 斷言失敗：$(echo "$R1"|head -c 200)"

echo "=== H2 /api/team-roster：builder 只有單一分類(無FE/BE假細分)，pools 三桶都在 ==="
echo "$R1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
keys=[p['key'] for p in d['pools']]
assert set(keys)=={'builder','reviewer','designer'}, keys
builder=[p for p in d['pools'] if p['key']=='builder'][0]
names=[m['name'] for m in builder['members']]
assert set(names)=={'Anna','三菜'}, names
" && ok "pools 三桶正確、builder 無假 FE/BE 細分" || bad "pools 斷言失敗：$(echo "$R1"|head -c 300)"

echo "=== H3 /api/hub：owner-a 看到自己的專案 + 未被專案認領的散單，claimed-task 不出現在 loose ==="
R3=$(API "$CK_A" "http://127.0.0.1:$MVP_PORT/api/hub")
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pids=[p['project_id'] for p in d['projects']]
assert pids==['proj-a'], pids
assert [p['project_id'] for p in d.get('archivedProjects',[])]==['proj-old'], d.get('archivedProjects')
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert 'claimed-task' not in loose_ids, loose_ids
assert 'owner-a-task' in loose_ids, loose_ids
assert 'owner-a-created' in loose_ids, loose_ids
" && ok "owner-a active 專案只列 proj-a、archived 收進 archivedProjects、claimed-task 排除在 loose 外、自己的散單都在" || bad "H3 斷言失敗：$(echo "$R3"|head -c 400)"

echo "=== H3b（老兔18221 穩健 roll-up）孤兒任務(project_id對但不在task_ids)：不進 loose、專案進度算得到它 ==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert 'orphan-project-task' not in loose_ids, loose_ids
proj=d['projects'][0]
assert proj['rollup']['total']==2, proj['rollup']  # claimed-task + orphan-project-task
assert proj['rollup']['done']==1, proj['rollup']   # orphan-project-task 在 done/
" && ok "孤兒任務不進 loose、rollup 正確算入(total=2,done=1)" || bad "H3b 斷言失敗：$(echo "$R3"|head -c 400)"

echo "=== H4（決定性反面案例）owner-a 看不到 owner-b 的散單（feedback_authz_fixture_needs_negative_case）==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert 'owner-b-task' not in loose_ids, loose_ids
" && ok "owner-a 的 /api/hub 看不到 owner-b-task（未越權讀）" || bad "越權讀取！owner-a 看到了 owner-b 的任務"

echo "=== H4b 真 FATQ 狀態：清單 badge/state 直接跟 tasks/ 目錄一致，含 rejected + 最後活動時間 ==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
by_id={t['task_id']:t for t in d['looseTasks']}
assert by_id['owner-a-created']['state']=='review', by_id['owner-a-created']
assert by_id['owner-a-created']['last_activity_at']=='2026-07-09T04:20:00+08:00', by_id['owner-a-created']
assert by_id['owner-a-rejected']['state']=='rejected', by_id['owner-a-rejected']
assert by_id['owner-a-rejected']['priority']=='P1', by_id['owner-a-rejected']
" && ok "loose task state/priority/last_activity 皆讀真 JSON+目錄位置" || bad "H4b 斷言失敗：$(echo "$R3"|head -c 500)"

echo "=== H5 owner-b 打 /api/hub：看不到 owner-a 的專案，只看到自己的散單 ==="
R5=$(API "$CK_B" "http://127.0.0.1:$MVP_PORT/api/hub")
echo "$R5" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['projects']==[], d['projects']
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert loose_ids==['owner-b-task'], loose_ids
" && ok "owner-b 看不到 owner-a 的專案，散單只看到自己那張" || bad "H5 斷言失敗：$(echo "$R5"|head -c 300)"

echo "=== H6 admin 打 /api/hub：全部專案+全部散單都看得到(bypass) ==="
R6=$(API "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/hub")
echo "$R6" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert len(d['projects'])==1, d['projects']
loose_ids=set(t['task_id'] for t in d['looseTasks'])
assert loose_ids=={'owner-a-task','owner-b-task','owner-a-created','owner-a-rejected'}, loose_ids
" && ok "admin bypass：全部專案+全部散單(排除已認領的 claimed-task)都看得到" || bad "H6 斷言失敗：$(echo "$R6"|head -c 300)"

echo "=== H7 /api/hub 含 todos 欄位(=approval_pending，非臆測個人代辦資料源) ==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'todos' in d and isinstance(d['todos'], list), d.get('todos')
" && ok "todos 欄位存在且為陣列（空清單也算，重點是接對資料源不是缺欄位）" || bad "H7 斷言失敗"

echo "=== H7b 任務詳情端點：admin 才能讀完整 goal/background/AC/history/verify；viewer 403 ==="
code_viewer=$(curl -sm 10 -o /dev/null -w "%{http_code}" -b "$CK_A" "http://127.0.0.1:$MVP_PORT/api/task/owner-a-created")
[ "$code_viewer" = "403" ] && ok "viewer/member 打任務詳情端點 403" || bad "viewer detail → $code_viewer（期望 403）"
detail_admin=$(API "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/task/owner-a-created")
echo "$detail_admin" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['_state']=='review', d
assert d['goal']=='owner-a 建立但未指派', d
assert d['background']=='完整背景文字', d
assert d['acceptance_criteria']==['AC one','AC two'], d
assert len(d['history'])==2 and d['history'][0]['action']=='submit', d
assert d['verify_commands'][0]['desc']=='fixture verify', d
" && ok "admin 任務詳情完整欄位可讀" || bad "admin detail 斷言失敗：$(echo "$detail_admin"|head -c 500)"

echo "=== H8 前端 nav 精簡：任務/待辦分頁按鈕拿掉，工作中樞取代（同 f8b2/W-C25 慣例先查 app.html 結構） ==="
grep -q 'data-pane="fleetPane"' "$SRC/app.html" && ! grep -q 'data-pane="taskPane"' "$SRC/app.html" \
  && ok "nav 已拿掉「任務」按鈕" || bad "nav 仍殘留「任務」分頁按鈕"
grep -q 'id="apprTab"' "$SRC/app.html" \
  && bad "nav 仍殘留「待辦」獨立分頁按鈕(#apprTab)" || ok "nav 已拿掉「待辦」獨立分頁按鈕"
grep -q '>工作中樞<' "$SRC/app.html" \
  && ok "nav 已有「工作中樞」入口" || bad "nav 缺「工作中樞」入口"

echo "=== H9 前端結構：#apprList/#looseTaskList 都收攏進 projPane(工作中樞)，不是各自獨立 pane ==="
grep -qE 'id="projPane"[^>]*>|id="projPane">' "$SRC/app.html" && ok "projPane 仍是承載元素" || bad "缺 projPane"
grep -q 'id="apprPane"' "$SRC/app.html" \
  && bad "app.html 仍殘留獨立 #apprPane 區塊(應已移除、內容併入 projPane)" || ok "獨立 #apprPane 區塊已移除"
grep -q 'id="looseTaskList"' "$SRC/app.html" && grep -q 'id="apprList"' "$SRC/app.html" \
  && ok "loose section 的代辦(#apprList)+未歸專案任務(#looseTaskList)都存在" || bad "缺 loose section 的必要容器"

echo "=== H9b 前端結構：任務列可點開詳情，詳情 modal 顯示完整欄位 ==="
grep -q 'openTaskDetail' "$SRC/app.html" && grep -q 'id="taskOverlay"' "$SRC/app.html" \
  && ok "任務詳情 modal + click handler 已接線" || bad "缺任務詳情 modal/click handler"
grep -q 'last_activity_at' "$SRC/app.html" && grep -q 'acceptance_criteria' "$SRC/app.html" && grep -q 'verify_commands / results' "$SRC/app.html" \
  && ok "前端顯示 last activity / AC / verify 區塊" || bad "任務詳情缺必要欄位"

echo "=== H10 前端結構：開專案 modal 改吃 /api/team-roster(skill 分類挑隊員)，不是寫死陣列 ==="
grep -q 'loadTeamRoster' "$SRC/app.html" && grep -q 'renderSkillMemberPicker' "$SRC/app.html" \
  && ok "隊員挑選已改用 skill 分類 render function + 真實 roster fetch" || bad "缺 skill 分類挑選/roster fetch 接線"
# 只抓字串字面值用法(前面帶引號)，不誤判成中文說明註解裡提到這個名字的散文
grep -qE "['\"]nicky-builder['\"]" "$SRC/app.html" \
  && bad "殘留漂移的 nicky-builder 寫死條目(team-config 根本沒有這個 bot)" || ok "已無 nicky-builder 這種寫死漂移條目"

echo "=== H11 前端結構：專案詳情已是 td-V5 拖拉網格(.pd-grid/.pd-trow/.pd-block)，非舊版固定 2 欄 ==="
grep -q 'id="pdGrid"' "$SRC/app.html" && grep -q 'function pdRenderGrid' "$SRC/app.html" \
  && ok "td-V5 網格容器+渲染函式都在" || bad "缺 td-V5 網格接線"
grep -q 'function pdWire' "$SRC/app.html" && grep -qE "dragstart.*pd-editing|pd-editing.*dragstart" "$SRC/app.html" \
  && ok "拖拉重排邏輯已接線(受編輯模式開關保護，非編輯狀態不可拖)" || bad "缺拖拉重排邏輯或未受編輯模式保護"
grep -q "pd-detail-" "$SRC/app.html" \
  && ok "版面持久化 key 已接 localStorage(pd-detail-<project_id>)" || bad "缺版面持久化"

echo "=== H12（同 f8b2/W-C25 已知模式）#projPane 要有 flex-direction:column，不能只靠 .pane.on{display:flex} 預設值 ==="
grep -q '^#projPane{flex-direction:column' "$SRC/app.html" \
  && ok "#projPane 有補 flex-direction:column，不會跑版" || bad "#projPane 缺 flex-direction:column，會跑版"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

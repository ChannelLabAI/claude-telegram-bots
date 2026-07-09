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
export MVP_PORT=18400
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
{"task_id":"owner-a-created","goal":"owner-a 建立但未指派","priority":"P3","created_by":"owner-a","created_at":"2026-07-09T04:00:00+08:00","history":[]}
EOF

# ── 假專案：owner-a 自己的一個專案，task_ids 包含 claimed-task（驗證它不進 loose）
cat > "$FIX/projects/proj-a.json" <<'EOF'
{"project_id":"proj-a","title":"Owner-A 的專案","goal":"g","owner":"owner-a","lead_assistant":"ron-assistant",
 "member_bots":[],"status":"active","attachments":[],"task_ids":["claimed-task"],"priority":"P2","created_at":"2026-07-09T00:30:00+08:00","history":[]}
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
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert 'claimed-task' not in loose_ids, loose_ids
assert 'owner-a-task' in loose_ids, loose_ids
assert 'owner-a-created' in loose_ids, loose_ids
" && ok "owner-a 看到自己專案、claimed-task 排除在 loose 外、自己的散單都在" || bad "H3 斷言失敗：$(echo "$R3"|head -c 400)"

echo "=== H4（決定性反面案例）owner-a 看不到 owner-b 的散單（feedback_authz_fixture_needs_negative_case）==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
loose_ids=[t['task_id'] for t in d['looseTasks']]
assert 'owner-b-task' not in loose_ids, loose_ids
" && ok "owner-a 的 /api/hub 看不到 owner-b-task（未越權讀）" || bad "越權讀取！owner-a 看到了 owner-b 的任務"

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
assert loose_ids=={'owner-a-task','owner-b-task','owner-a-created'}, loose_ids
" && ok "admin bypass：全部專案+全部散單(排除已認領的 claimed-task)都看得到" || bad "H6 斷言失敗：$(echo "$R6"|head -c 300)"

echo "=== H7 /api/hub 含 todos 欄位(=approval_pending，非臆測個人代辦資料源) ==="
echo "$R3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'todos' in d and isinstance(d['todos'], list), d.get('todos')
" && ok "todos 欄位存在且為陣列（空清單也算，重點是接對資料源不是缺欄位）" || bad "H7 斷言失敗"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

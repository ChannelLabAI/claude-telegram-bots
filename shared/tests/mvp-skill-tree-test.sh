#!/usr/bin/env bash
# mvp-skill-tree-test.sh — a2c5 技能天賦樹（唯讀視覺化）驗收 fixture
# （task 20260709-0157-a2c5-skill-tree-live-integration）
#
# 核心關切：①真實技能資料接得對（沿用不發明教訓，state_dir 跟目錄對不上就誠實排除，
# 不硬猜路徑）②讀取視覺化 member 就能看，不因為裝卸是治理操作就連唯讀都鎖 admin
# ③demoMode 誠實旗標存在，前端才能據此標「示意」不誤導。
#
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-skill-tree-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_TEAM_CONFIG MVP_BOTS_DIR; do
  grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null || { echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入，拒跑"; exit 1; }
done

FIX=$(mktemp -d /tmp/mvp-skill-tree-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending} "$FIX/bots"/{bot-a,bot-b,bot-c-nodir-mismatch}
cp "$SRC/app.html" "$FIX/mvp/"

# ── 假 team-config.json：bot-a 有真實 CLAUDE.md、bot-b 有但 skill 區塊空、
# bot-c 的 state_dir 故意跟磁碟上沒有的目錄名對不上（模擬 Eric/ron-builder 那種漂移） ──
cat > "$FIX/team-config.json" <<'EOF'
{
  "assistants": [
    {"name":"Alpha 特助","state_dir":"bot-a","owner":"x"},
    {"name":"Beta 特助","state_dir":"bot-b","owner":"x"}
  ],
  "shared_pools": {
    "builder": [
      {"name":"Ghost Builder","state_dir":"bot-c-ghost-mismatch"}
    ]
  }
}
EOF

# bot-a：真實 gstack skill 清單（含 bold 語法）
cat > "$FIX/bots/bot-a/CLAUDE.md" <<'EOF'
# Alpha

### gstack Skills (use proactively)
- **/design-review** — visual QA
- **/ship** — deploy
- **/qa** — testing
EOF

# bot-b：有標題但底下沒有真的 skill bullet（純文字段落，不該被誤判成技能）
cat > "$FIX/bots/bot-b/CLAUDE.md" <<'EOF'
# Beta

### gstack 技能
目前尚未採用任何 gstack skill，純靠人工流程。

### 下一節
- 這行在別的標題底下，不該被算進 gstack 技能
EOF

# bot-c-ghost-mismatch：team-config 有登記但磁碟目錄根本不存在（不建立對應目錄）

export MVP_TEAM_CONFIG="$FIX/team-config.json"
export MVP_BOTS_DIR="$FIX/bots"
export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_DEV_MODE=1
export MVP_PORT="${2:-18990}"
REAL_TC="/home/oldrabbit/.claude-bots/shared/team-config.json"
[ "$MVP_TEAM_CONFIG" = "$REAL_TC" ] && { echo "FATAL: fixture 指向生產 team-config.json，拒跑"; exit 1; }

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" "$@"; }
API(){ curl -sm 10 "$@"; }

CK_ADMIN="$FIX/ck-admin"
curl -sc "$CK_ADMIN" -X POST -d "email=stadmin@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='admin', identity='stadmin' WHERE email='stadmin@x.local';"

CK_MEMBER="$FIX/ck-member"
curl -sc "$CK_MEMBER" -X POST -d "email=stmember@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='member', identity='stmember' WHERE email='stmember@x.local';"

echo "=== T1 未登入打 /api/skills → 401 ==="
c1=$(CODE "http://127.0.0.1:$MVP_PORT/api/skills")
[ "$c1" = "401" ] && ok "未登入 → 401" || bad "未登入 → $c1（期望 401）"

echo "=== T2（核心）member（非 admin）能讀取 /api/skills → 200，讀取視覺化不鎖 admin ==="
c2=$(CODE -b "$CK_MEMBER" "http://127.0.0.1:$MVP_PORT/api/skills")
[ "$c2" = "200" ] && ok "member 讀取 /api/skills → 200（唯讀視覺化不因裝卸是治理操作被連坐鎖 admin）" || bad "member 讀取 /api/skills → $c2（期望 200）"

echo "=== T3 真實技能資料：bot-a 的 3 個 skill 都被正確解析出來 ==="
r3=$(API -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/skills")
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
eq=set(d['equipped'].get('bot-a',[]))
assert eq=={'design-review','ship','qa'}, eq
" && ok "bot-a 的 gstack skill bullet（含 bold 語法）正確解析成 3 個技能" || bad "T3 斷言失敗：$(echo "$r3"|python3 -c "import json,sys;print(json.load(sys.stdin)['equipped'].get('bot-a'))" 2>&1)"

echo "=== T4 誠實邊界：bot-b 標題底下沒有真 bullet（純文字段落）→ 0 技能，不誤判 ==="
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
eq=d['equipped'].get('bot-b',[])
assert eq==[], eq
" && ok "bot-b（無 skill bullet）正確回傳 0 技能，不把段落文字/下一節誤判成技能" || bad "T4 斷言失敗"

echo "=== T5（核心，沿用不發明教訓）team-config state_dir 跟磁碟目錄對不上（bot-c-ghost-mismatch）→ 誠實排除，不硬猜路徑 ==="
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
dirs=[b['stateDir'] for b in d['bots']]
assert 'bot-c-ghost-mismatch' not in dirs, dirs
assert len(d['bots'])==2, d['bots']
" && ok "state_dir 跟目錄漂移的 bot 誠實排除在清單外（不是生出一個查無資料的假 bot）" || bad "T5 斷言失敗：$(echo "$r3"|python3 -c "import json,sys;print([b['stateDir'] for b in json.load(sys.stdin)['bots']])" 2>&1)"

echo "=== T6 demoMode 旗標存在（前端據此標『示意』，不然容易漏標） ==="
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('demoMode') is True, d.get('demoMode')
" && ok "demoMode:true 明確存在" || bad "T6 斷言失敗：缺 demoMode 旗標"

echo "=== T7 分類/風險對照：design-review→design/lo、ship→delivery/hi（沿用設計稿真實標注，非亂猜） ==="
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
byname={s['name']:(c['key'],s['risk']) for c in d['categories'] for s in c['skills']}
assert byname.get('design-review')==('design','lo'), byname.get('design-review')
assert byname.get('ship')==('delivery','hi'), byname.get('ship')
assert byname.get('qa')==('qa','mid'), byname.get('qa')
" && ok "分類/風險對照正確（design-review=design/lo、ship=delivery/hi、qa=qa/mid）" || bad "T7 斷言失敗"

echo "=== T8 未知技能名不臆測風險：一律歸類'其他'+低風險，不冒充已知分類 ==="
mkdir -p "$FIX/bots/bot-a"
cat >> "$FIX/bots/bot-a/CLAUDE.md" <<'EOF'
- **/totally-unknown-skill-xyz** — 沒人知道這是什麼
EOF
r8=$(API -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/skills")
echo "$r8" | python3 -c "
import json,sys
d=json.load(sys.stdin)
found=None
for c in d['categories']:
    for s in c['skills']:
        if s['name']=='totally-unknown-skill-xyz': found=(c['key'],s['risk'])
assert found==('other','lo'), found
" && ok "未知技能名歸類 other/低風險（保守預設，不臆測分類/風險）" || bad "T8 斷言失敗：$(echo "$r8"|head -c 200)"

echo "=== T9（a7e3）懸空線修復：空分類（如目前的「記憶」0 技能）不進 cats 佈局迴圈，不會畫出無終點節點的中心線 ==="
grep -q "skillData.categories.filter(c=>c.skills.length)" "$SRC/app.html" \
  && ok "renderSkillTree() 已濾掉空分類，不再對 0 技能分類畫懸空中心線" || bad "缺空分類過濾——0 技能分類仍會畫出無 hub node 的懸空線"

echo "=== T10（a7e3）標籤跨分類碰撞修復：葉節點角度依可用扇區動態縮放，不再是不看分類技能數/鄰居距離的固定 19°/節點 ==="
grep -q "maxHalfSpreadDeg" "$SRC/app.html" && grep -q "perLeafDeg" "$SRC/app.html" \
  && ok "已改用扇區可用角度動態算每葉節點間距（防止技能數多的分類展開撞進鄰居分類）" || bad "缺動態扇區分配邏輯——技能數多的分類仍可能用固定角度撞進鄰居"
grep -qE "spread\s*=\s*19\s*\*" "$SRC/app.html" \
  && bad "仍殘留舊的固定 19°/節點寫死邏輯（未真正改用動態扇區）" || ok "舊的固定 19°/節點寫死邏輯已移除"

echo "=== T11（a7e3）同分類內長標籤截斷：max-width+ellipsis+title tooltip，確保任何長度的技能名都不會撐爆相鄰間距 ==="
# 精準抓 .snode .lbl{...} 這個 CSS 規則區塊本身，避免跟 app.html 其他既有規則（如 .conv .nm 等）
# 同樣用了 ellipsis/nowrap 這組常見樣式而誤判通過（那些規則跟本次修復完全無關）。
# e6f4 附帶修正：CSS 對同一 selector 可以寫多條規則（d3e9 JRPG 改版後 .snode .lbl{}
# 拆成兩條——一條管定位、一條管字型/截斷），逐條全掃、只要任一條命中就算數，別只
# 抓「第一個遇到的 .snode .lbl{ 區塊」（那樣改版拆規則後會誤判成「截斷樣式不見了」，
# 其實只是搬到另一條規則去，功能完全還在）。
LBL_RULE=$(awk '/\.snode \.lbl\{/{f=1} f{print} f&&/\}/{f=0}' "$SRC/app.html")
echo "$LBL_RULE" | grep -q "text-overflow:ellipsis" && echo "$LBL_RULE" | grep -q "white-space:nowrap" \
  && ok ".snode .lbl 規則本身已加 ellipsis/nowrap 截斷樣式" || bad "缺 .snode .lbl 截斷樣式——長技能名仍可能撐開撞進鄰居標籤"
grep -q "lblMaxW" "$SRC/app.html" \
  && ok "標籤 max-width 依實際可用弦長動態計算（節點越擠，截斷越多，幾何上保證不重疊）" || bad "缺動態 max-width 計算"
grep -qE 'class="lbl"[^>]*title="\$\{h\(sk\.name\)\}"' "$SRC/app.html" \
  && ok "截斷標籤保留 title 原生 tooltip（滑鼠移上可看完整技能名）" || bad "缺標籤 title tooltip 後備顯示"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

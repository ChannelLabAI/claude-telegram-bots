#!/usr/bin/env bash
# mvp-skill-equip-test.sh — d8c2 技能樹裝備/拆除（admin 治理寫入）驗收 fixture
# （task 20260709-1048-d8c2-skill-tree-equip-action）
#
# 核心關切：①改 bot 能力邊界＝admin 動手，viewer 打端點必 403（LIVE 反面斷言先在
# fixture 驗）②高風險技能裝備必逐次確認（confirm===skill 逐字比對，不可略過）
# ③真的改到 CLAUDE.md（非幽靈成功）④冪等（重複裝備/拆除不報錯不重複寫）
# ⑤沒有 gstack 技能區塊的 bot 預設誠實拒絕；admin 明確 opt-in 時才建立區塊。
#
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-skill-equip-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_TEAM_CONFIG MVP_BOTS_DIR; do
  grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null || { echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入，拒跑"; exit 1; }
done
grep -q "/api/skills/equip" "$SRC/mvp-server.ts" 2>/dev/null || { echo "FATAL: $SRC/mvp-server.ts 沒有 /api/skills/equip 端點，拒跑"; exit 1; }

FIX=$(mktemp -d /tmp/mvp-skill-equip-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending} "$FIX/bots"/{bot-a,bot-d-no-section}
cp "$SRC/app.html" "$FIX/mvp/"

cat > "$FIX/team-config.json" <<'EOF'
{
  "assistants": [
    {"name":"Alpha 特助","state_dir":"bot-a","owner":"x"}
  ],
  "shared_pools": {
    "builder": [
      {"name":"Delta No-Section","state_dir":"bot-d-no-section"}
    ]
  }
}
EOF

# bot-a：design-review 已裝備，ship(高風險)/qa(中風險) 未裝備——用來測裝備/拆除/治理確認
cat > "$FIX/bots/bot-a/CLAUDE.md" <<'EOF'
# Alpha

### gstack Skills
- **/design-review** — visual QA

## 下一節
不該被誤判進技能區塊的內容。
EOF

# bot-d-no-section：完全沒有 gstack 技能標題（誠實拒絕寫入用）——內文刻意不出現
# 「gstack」+「skill」相鄰字樣，避免跟 parseBotSkills()/equipBotSkill() 共用的標題
# 偵測 regex 假陽性命中純文字敘述（這條 regex 是讀寫共用的單一事實來源，寫入端
# 刻意跟讀取端同一份判斷準則，不是這裡的測試該繞過的邊界）。
cat > "$FIX/bots/bot-d-no-section/CLAUDE.md" <<'EOF'
# Delta

這隻 bot 目前純靠人工流程，沒有任何自動化操作清單。
EOF

export MVP_TEAM_CONFIG="$FIX/team-config.json"
export MVP_BOTS_DIR="$FIX/bots"
export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_DEV_MODE=1
export MVP_PORT="${2:-18991}"
REAL_TC="/home/oldrabbit/.claude-bots/shared/team-config.json"
REAL_BOTS="/home/oldrabbit/.claude-bots/bots"
[ "$MVP_TEAM_CONFIG" = "$REAL_TC" ] && { echo "FATAL: fixture 指向生產 team-config.json，拒跑"; exit 1; }
[ "$MVP_BOTS_DIR" = "$REAL_BOTS" ] && { echo "FATAL: fixture 指向生產 bots/ 目錄，拒跑（會真的改到真人 bot 的 CLAUDE.md）"; exit 1; }

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

CLAUDE_A="$FIX/bots/bot-a/CLAUDE.md"

echo "=== T0（canary）確認 fixture CLAUDE.md 真的是隔離的臨時檔，不是生產路徑 ==="
case "$CLAUDE_A" in
  /tmp/*) ok "CLAUDE_A 路徑在 /tmp 下（隔離 fixture，非生產 bots/）" ;;
  *) bad "CLAUDE_A 路徑不在 /tmp 下：$CLAUDE_A（可能誤指生產目錄，拒絕繼續跑寫入類斷言）"; exit 1 ;;
esac

echo "=== T1（核心紅線）viewer 打裝備端點 → 403（LIVE 反面斷言先在 fixture 驗證） ==="
c1=$(CODE -b "$CK_MEMBER" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c1" = "403" ] && ok "viewer 裝備 → 403" || bad "viewer 裝備 → $c1（期望 403）"
grep -q "\*\*/qa\*\*" "$CLAUDE_A" && bad "viewer 403 被擋後 CLAUDE.md 仍被寫入（授權閘失效）" || ok "viewer 403 後 CLAUDE.md 確認未被寫入"

echo "=== T2 admin 裝備中風險技能 qa（無需治理確認）→ 200，真的寫進 CLAUDE.md ==="
r2=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert 'qa' in d.get('equipped',[]), d
assert d.get('noop') is not True, d
" && ok "中風險裝備成功，回傳真實 equipped 清單含 qa" || bad "T2 斷言失敗：$r2"
grep -qE '^\-\s*\*{0,2}/qa\b' "$CLAUDE_A" && ok "CLAUDE.md 真的多了 qa bullet（非幽靈成功）" || bad "CLAUDE.md 沒有真的寫入 qa"

echo "=== T3 冪等：對已裝備的 qa 再裝一次 → ok:true noop:true，不重複插入 bullet ==="
r3=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r3" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True and d.get('noop') is True, d
" && ok "重複裝備回傳 noop:true（冪等，不報錯）" || bad "T3 斷言失敗：$r3"
cnt=$(grep -cE '^\-\s*\*{0,2}/qa\b' "$CLAUDE_A")
[ "$cnt" = "1" ] && ok "CLAUDE.md 裡 qa bullet 仍只有 1 條（沒有重複插入）" || bad "qa bullet 出現 $cnt 次（期望 1，冪等失敗）"

echo "=== T4（核心紅線）高風險技能 ship 裝備、不帶 confirm → 400，不可略過逐次確認 ==="
c4=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"ship","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c4" = "400" ] && ok "高風險裝備缺 confirm → 400" || bad "高風險裝備缺 confirm → $c4（期望 400）"
grep -qE '^\-\s*\*{0,2}/ship\b' "$CLAUDE_A" && bad "400 被擋後 CLAUDE.md 仍寫入 ship（confirm 閘失效）" || ok "400 後 CLAUDE.md 確認未寫入 ship"

echo "=== T5 高風險技能 confirm 打錯字（非逐字等於技能名）→ 400，不放行 ==="
c5=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"ship","action":"equip","confirm":"shpi"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c5" = "400" ] && ok "confirm 打錯字 → 400" || bad "confirm 打錯字 → $c5（期望 400）"

echo "=== T6 高風險技能 confirm 逐字正確 → 200，真的裝備成功 ==="
r6=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"ship","action":"equip","confirm":"ship"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r6" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert 'ship' in d.get('equipped',[]), d
" && ok "高風險技能 confirm 逐字正確 → 裝備成功" || bad "T6 斷言失敗：$r6"

echo "=== T7 GET /api/skills 重讀反映真實新狀態（非另存一份裝備旗標） ==="
r7=$(API -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/skills")
echo "$r7" | python3 -c "
import json,sys
d=json.load(sys.stdin)
eq=set(d['equipped'].get('bot-a',[]))
assert eq=={'design-review','qa','ship'}, eq
" && ok "GET /api/skills 重新解析 CLAUDE.md，equipped 含 design-review+qa+ship（單一資料源，無幽靈狀態）" || bad "T7 斷言失敗"

echo "=== T8 拆除技能：unequip qa → 200，CLAUDE.md 真的移除 bullet ==="
r8=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"unequip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r8" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert 'qa' not in d.get('equipped',[]), d
" && ok "拆除 qa 成功，回傳 equipped 不再含 qa" || bad "T8 斷言失敗：$r8"
grep -qE '^\-\s*\*{0,2}/qa\b' "$CLAUDE_A" && bad "CLAUDE.md 仍殘留 qa bullet（拆除沒真的寫入）" || ok "CLAUDE.md 確認 qa bullet 已移除"
grep -q "design-review" "$CLAUDE_A" && ok "拆除 qa 沒有動到同區塊其他 bullet（design-review 還在）" || bad "拆除 qa 誤傷了其他 bullet"

echo "=== T9 冪等拆除：對本來就沒裝的技能 unequip → ok:true noop:true，不報錯 ==="
r9=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"unequip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r9" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True and d.get('noop') is True, d
" && ok "重複拆除回傳 noop:true（冪等）" || bad "T9 斷言失敗：$r9"

echo "=== T10（誠實拒絕，沿用不發明教訓）bot 沒有 gstack 技能區塊且未 opt-in → 400，不亂猜插入位置 ==="
c10=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-d-no-section","skill":"qa","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c10" = "400" ] && ok "無 gstack 技能區塊的 bot → 400（誠實拒絕）" || bad "無區塊 bot → $c10（期望 400）"
grep -q "qa" "$FIX/bots/bot-d-no-section/CLAUDE.md" && bad "誠實拒絕失敗：CLAUDE.md 被亂插入了東西" || ok "確認沒有亂猜插入任何內容"

echo "=== T10b admin 明確 createBlockIfMissing opt-in → 建立 gstack 區塊並裝備，不是靜默亂插 ==="
r10b=$(API -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-d-no-section","skill":"qa","action":"equip","createBlockIfMissing":true}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
echo "$r10b" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('createdBlock') is True, d
assert 'qa' in d.get('equipped',[]), d
" && ok "opt-in 建立區塊並裝備 qa 成功" || bad "T10b 斷言失敗：$r10b"
grep -q '^### gstack Skills' "$FIX/bots/bot-d-no-section/CLAUDE.md" && grep -qE '^\-\s*\*{0,2}/qa\b' "$FIX/bots/bot-d-no-section/CLAUDE.md" \
  && ok "CLAUDE.md 明確新增 gstack Skills 區塊與 qa bullet" || bad "CLAUDE.md 未正確新增 gstack Skills 區塊/qa bullet"

echo "=== T11 未知 bot stateDir → 404 ==="
c11=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"does-not-exist","skill":"qa","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c11" = "404" ] && ok "未知 bot → 404" || bad "未知 bot → $c11（期望 404）"

echo "=== T12 skill 格式不合法（防注入 CLAUDE.md 的 markdown/路徑字元）→ 400 ==="
c12=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"../../etc/passwd","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c12" = "400" ] && ok "非法 skill 格式（含路徑穿越字元）→ 400" || bad "非法 skill 格式 → $c12（期望 400）"
c12b=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"design-review\n- **/injected**","action":"equip"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c12b" = "400" ] && ok "skill 帶換行注入嘗試 → 400" || bad "skill 帶換行 → $c12b（期望 400）"

echo "=== T13 action 不是 equip/unequip → 400 ==="
c13=$(CODE -b "$CK_ADMIN" -X POST -H 'content-type: application/json' \
  -d '{"bot":"bot-a","skill":"qa","action":"delete-everything"}' "http://127.0.0.1:$MVP_PORT/api/skills/equip")
[ "$c13" = "400" ] && ok "非法 action → 400" || bad "非法 action → $c13（期望 400）"

echo "=== T14 audit log 記錄 skill_equip/skill_unequip 動作（可稽核，非靜默寫入） ==="
r14=$(API -b "$CK_ADMIN" "http://127.0.0.1:$MVP_PORT/api/audit")
echo "$r14" | python3 -c "
import json,sys
d=json.load(sys.stdin)
actions=[a.get('action') for a in d.get('audit',[])]
assert 'skill_equip' in actions, actions
assert 'skill_unequip' in actions, actions
" && ok "audit log 存在 skill_equip/skill_unequip 記錄" || bad "T14 斷言失敗：$(echo "$r14"|head -c 300)"

echo "=== T15（前端不假裝）app.html 裝備鈕真的解鎖給 admin、治理確認 overlay 存在，不是永遠 disabled 的視覺樣板 ==="
grep -q "act.disabled=!admin" "$SRC/app.html" \
  && ok "sp-act 按鈕依 admin 真實解鎖（非永遠 disabled）" || bad "sp-act 仍寫死 disabled，前端仍是唯讀樣板（幽靈行為）"
grep -q "skGovOverlay" "$SRC/app.html" && grep -q "skg-confirm-input" "$SRC/app.html" \
  && ok "治理確認 overlay（含逐字輸入確認欄位）已接線" || bad "缺治理確認 overlay 接線"
grep -q "/api/skills/equip" "$SRC/app.html" \
  && ok "前端真的呼叫 /api/skills/equip（非假裝成功的本地 state 玩具）" || bad "前端沒有呼叫真後端端點"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

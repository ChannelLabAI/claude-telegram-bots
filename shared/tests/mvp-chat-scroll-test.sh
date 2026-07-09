#!/usr/bin/env bash
# mvp-chat-scroll-test.sh — cc3a chat scroll preservation + new-message pill fixture
#
# 用法：MVP_SRC=<待測代碼目錄> bash shared/tests/mvp-chat-scroll-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
APP="$SRC/app.html"

[ -f "$APP" ] || { echo "FATAL: missing $APP"; exit 1; }

echo "=== S1 共用 scroll guard helper：80px 底部閾值 + capture/commit state ==="
grep -qF "const CHAT_BOTTOM_THRESHOLD=80" "$APP" \
  && ok "底部閾值為 80px" || bad "缺 CHAT_BOTTOM_THRESHOLD=80"
grep -qF "function captureChatScroll(key,thread)" "$APP" && grep -qF "function commitChatScroll(key,thread,before)" "$APP" \
  && ok "有共用 capture/commit helper" || bad "缺共用 capture/commit helper"
grep -qF "thread.scrollTop=before.top" "$APP" \
  && ok "離底重繪會還原原 scrollTop" || bad "缺離底 scrollTop 還原"
grep -qF "if(!before.initialized||before.atBottom)" "$APP" && grep -qF "thread.scrollTop=thread.scrollHeight" "$APP" \
  && ok "原本在底部或該 thread 首次 capture 時才自動跟隨到底" || bad "缺 atBottom/initialized 條件式跟隨"

echo "=== S1b Bella cc3a REJECT 三處修復（BLOCKER pill 遮輸入框/capture 死碼/計數虛胖）都已接線 ==="
grep -qF "footer.offsetHeight+12" "$APP" \
  && ok "pill 位置動態依 composer 實際高度墊高（不再是壓輸入框的靜態值）" || bad "缺動態 pill 位置修復"
grep -qF "const isSwitch=t!==curTarget" "$APP" && grep -qF "if(isSwitch)resetChatScroll" "$APP" \
  && ok "只有真的切換對象才 reset scroll state（重整同對象保留位置）" || bad "缺 isSwitch 判斷，reset 仍會誤觸發"
grep -qF ".bot[data-chat-key]" "$APP" \
  && ok "新訊息計數只認 bot 訊息 key（自己送的/處理中泡不計入）" || bad "缺 bot-only key 過濾，計數仍會虛胖"
grep -qF "forceBottom" "$APP" \
  && ok "自己送訊息/處理中泡有 forceBottom（不管原本捲到哪都看得到剛送的）" || bad "缺 forceBottom 機制"

echo "=== S2 新訊息 pill：計數、文案、點擊跳底清除 ==="
grep -qF "className='chat-new-pill'" "$APP" && grep -qF "⬇ \${st.unread} 則新訊息" "$APP" \
  && ok "新訊息 pill DOM 與計數文案存在" || bad "缺新訊息 pill 或文案"
grep -qF "pill.onclick=()=>{" "$APP" && grep -qF "st.unread=0" "$APP" \
  && ok "點 pill 會跳到底並清除 unread" || bad "pill click 行為缺漏"
grep -qF ".chat-new-pill{position:absolute" "$APP" && grep -qF "#projChatBlock .chat-new-pill" "$APP" \
  && ok "一般聊天與專案聊天 pill 都有定位樣式" || bad "pill 樣式/專案定位缺漏"

echo "=== S3 對話分頁接線：pickTarget 初始載入、addMsg/SSE append 都走同一套 helper ==="
grep -qF 'resetChatScroll(mainChatKey,$('"'"'#msgs'"'"'))' "$APP" \
  && ok "切換對話會重置該 thread 的 scroll state" || bad "pickTarget 缺 resetChatScroll"
grep -qF 'const before=captureChatScroll(mainChatKey,$('"'"'#msgs'"'"'))' "$APP" && grep -qF 'commitChatScroll(mainChatKey,$('"'"'#msgs'"'"'),before)' "$APP" \
  && ok "對話分頁整包重繪走 capture/commit" || bad "對話分頁重繪未走 capture/commit"
grep -qF "function addMsg(cls,text,who,opts={})" "$APP" && grep -qF "commitChatScroll(key,thread,before)" "$APP" \
  && ok "SSE/send append 走 addMsg scroll guard" || bad "addMsg 未接 scroll guard"

echo "=== S4 專案迷你聊天窗接線：poll 重繪走同一套 helper，不再無條件拉底 ==="
grep -qF "function projChatKey(projectId)" "$APP" && grep -qF "resetChatScroll(projChatKey(p.project_id),thread)" "$APP" \
  && ok "專案聊天有獨立 thread key 並於 init reset" || bad "專案聊天缺 thread state reset"
grep -qF "const before=captureChatScroll(key,thread)" "$APP" && grep -qF "commitChatScroll(key,thread,before)" "$APP" \
  && ok "專案聊天 poll 重繪走 capture/commit" || bad "專案聊天 poll 未走 capture/commit"

echo "=== S5 反回歸：專案 poll function 內不能保留無條件 thread.scrollTop=thread.scrollHeight ==="
poll_body=$(awk '/async function pollProjChat\(projectId\)/{f=1} f{print} f&&/^}/ {f=0}' "$APP")
echo "$poll_body" | grep -qF "thread.scrollTop=thread.scrollHeight" \
  && bad "pollProjChat 仍有無條件 scrollToBottom" || ok "pollProjChat 已移除無條件 scrollToBottom"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

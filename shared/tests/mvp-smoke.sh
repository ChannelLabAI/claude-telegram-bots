#!/usr/bin/env bash
# mvp-smoke.sh — Pod 2.1 上線 e2e 煙霧測試（傘 spec 完成定義：全綠才叫完成，AI 聲稱不算數）
# 前置：CLI（含 Part 2 approval）過 Bella QA、生產 mvp-server 已切到 Part 3 代碼、laotu 已入 CLI 身份名單。
# 打生產 127.0.0.1:8090 ＋ 真 CLI ＋ 真 tasks/——會留下 SMOKE- 前綴需求單與一筆 approval 決策，
# 結束時列出殘留物請 Anya 分診清理（本腳本不 rm 真實 tasks/ 任何檔案）。
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
FATQ=/home/oldrabbit/.claude-bots/shared/bin/fatq
BASE=http://127.0.0.1:8090
CK=$(mktemp /tmp/smoke-ck-XXXXXX)
STAMP=$(date +%H%M%S)

echo "=== 1. 建立 admin session（優先 a9d3 admin gate，無密碼時退回 dev-login）==="
ADMIN_GATE_PASSWORD="${MVP_SMOKE_ADMIN_PASSWORD:-${MVP_ADMIN_PASSWORD:-}}"
if [ -n "$ADMIN_GATE_PASSWORD" ]; then
  curl -sc "$CK" -X POST --data-urlencode "password=$ADMIN_GATE_PASSWORD" "$BASE/gate" -o /dev/null
else
  curl -sc "$CK" -X POST -d "email=bthare.grant@gmail.com" "$BASE/auth/dev-login" -o /dev/null
fi
me=$(curl -sb "$CK" "$BASE/api/me")
SMOKE_AS=$(echo "$me" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ident=d.get('identity')
assert d.get('role')=='admin', d
assert ident in ('laotu','laotu-gate'), d
print(ident)
" 2>/tmp/mvp-smoke-me.err)
if [ -n "$SMOKE_AS" ]; then
  ok "admin session identity=$SMOKE_AS"
else
  bad "未取得可用 admin session：$(echo "$me"|head -c 160) $(cat /tmp/mvp-smoke-me.err 2>/dev/null)"
  exit 1
fi
APPROVAL_AS="${MVP_SMOKE_APPROVER_AS:-laotu}"

echo "=== 2. web 建需求單 ==="
r=$(curl -sb "$CK" -X POST -H "content-type: application/json" \
  -d "{\"title\":\"SMOKE-${STAMP} 煙霧測試需求單（Anya 可直接 wont_do）\",\"description\":\"mvp-smoke.sh 自動產生\",\"priority\":\"P3\"}" \
  "$BASE/api/tasks")
TID=$(echo "$r" | python3 -c "import json,sys;print(json.load(sys.stdin).get('task_id',''))")
[ -n "$TID" ] && ok "建單 $TID" || { bad "建單失敗：$(echo "$r"|head -c 200)"; exit 1; }

echo "=== 3. fatq query 見單：pending + assigned=anya ==="
"$FATQ" query --task-id "$TID" --as "$SMOKE_AS" --json | python3 -c "
import json,sys; t=json.load(sys.stdin)['tasks'][0]
assert t['state']=='pending' and t['assigned']=='anya', t" \
  && ok "CLI 可查、狀態正確" || bad "query 斷言失敗"

echo "=== 4. 造 approval request（CLI 直呼）==="
"$FATQ" approval request "$TID" --domain cross-bot-infra --expires 48h --as "$SMOKE_AS" --json \
  | python3 -c "import json,sys;assert json.load(sys.stdin)['ok']" \
  && ok "request 進 approval_pending" || { bad "approval request 失敗"; exit 1; }

echo "=== 5. 待批清單出現 ==="
if [ "$SMOKE_AS" = "$APPROVAL_AS" ]; then
  curl -sb "$CK" "$BASE/api/approvals" | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert any(t['task_id']=='$TID' for t in d['approvals']), [t['task_id'] for t in d['approvals']]" \
    && ok "/api/approvals 列出" || bad "待批清單未出現"
else
  "$FATQ" query --state approval_pending --as "$APPROVAL_AS" --json | python3 -c "
import json,sys; d=json.load(sys.stdin)
assert any(t['task_id']=='$TID' for t in d['tasks']), [t['task_id'] for t in d['tasks']]" \
    && ok "CLI approver($APPROVAL_AS) 可查待批單；admin gate session identity=$SMOKE_AS 不冒充 approver" \
    || bad "CLI approver($APPROVAL_AS) 查不到待批單"
fi

echo "=== 6. approval 決策 ==="
if [ "$SMOKE_AS" = "$APPROVAL_AS" ]; then
  r=$(curl -sb "$CK" -X POST -H "content-type: application/json" -d '{}' "$BASE/api/approvals/$TID/approve")
  echo "$r" | python3 -c "import json,sys;assert json.load(sys.stdin)['ok']" \
    && ok "web approve 成功" || bad "web approve 失敗：$(echo "$r"|head -c 200)"
  EXPECT_EVIDENCE_PREFIX="web:"
else
  "$FATQ" approval approve "$TID" --evidence "smoke-cli:$STAMP" --as "$APPROVAL_AS" --json \
    | python3 -c "import json,sys;assert json.load(sys.stdin)['ok']" \
    && ok "CLI approve 成功（a9d3 admin gate identity=$SMOKE_AS，approver 仍為 $APPROVAL_AS）" \
    || { bad "CLI approve 失敗"; exit 1; }
  EXPECT_EVIDENCE_PREFIX="smoke-cli:"
fi

echo "=== 7. 回歸 return_state + 憑據對上 ==="
q=$("$FATQ" query --task-id "$TID" --full --as "$SMOKE_AS" --json)
EV=$(echo "$q" | python3 -c "
import json,sys; t=json.load(sys.stdin)['tasks'][0]
assert t['state']!='approval_pending', t['state']
ap=t['approval']; assert ap['decision'] in ('approve','approved') and ap['evidence'].startswith('$EXPECT_EVIDENCE_PREFIX'), ap
print(ap['evidence'])")
[ -n "$EV" ] && ok "回歸 + evidence=$EV" || bad "回歸/evidence 斷言失敗"
if [ "$EXPECT_EVIDENCE_PREFIX" = "web:" ]; then
  if [ -n "$EV" ] && grep -q "$EV" /home/oldrabbit/.claude-bots/mvp/audit.log; then
    ok "audit.log 與 evidence 對上（稽核鏈閉環）"
  else bad "audit.log 找不到「${EV:-(EV空,前置斷言未產出)}」"; fi
else
  echo "$q" | grep -q "$EV" && ok "task history/approval evidence 已記錄 CLI 決策憑據" || bad "task JSON 找不到 evidence=$EV"
fi

echo "=== 8. 自清：把本輪 SMOKE 需求單移進 wont_do/（Bella 早前建議，別再堆給 Anya 手清；c2d1）==="
# 只認已知的 $TID（本輪 create 回應直接拿到，不用搜尋/比對 STAMP，更不會誤清別的單）；
# 額外用標題必須是 SMOKE- 開頭再把關一次，任何一關不過就跳過自清、不影響 smoke 主結果。
TASKS_ROOT=/home/oldrabbit/.claude-bots/tasks
TF=""
for st in pending in_progress review done rejected cancelled approval_pending; do
  [ -f "$TASKS_ROOT/$st/$TID.json" ] && TF="$TASKS_ROOT/$st/$TID.json" && CURST="$st" && break
done
if [ -z "$TF" ]; then
  bad "自清：找不到本輪任務檔 $TID，跳過（不影響 smoke 主結果）"
else
  TITLE=$(jq -r '.goal // .title // ""' "$TF" 2>/dev/null)
  case "$TITLE" in
    SMOKE-*)
      exec {lockfd}<"$TF"
      flock -x "$lockfd"
      tmp="$(mktemp "$TASKS_ROOT/$CURST/.mvp-smoke-selfclean.XXXXXX")"
      entry=$(jq -n --arg ts "$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S+08:00')" --arg from "${CURST}/" \
        '{ts:$ts, by:"laotu", via:"mvp-smoke.sh", action:"selfclean_wont_do",
          from:$from, to:"wont_do/",
          reason:"smoke fixture 自建需求單，測試完成即自清，不留派工噪音（c2d1）"}' 2>/dev/null)
      if jq --argjson entry "$entry" '.history=((.history // [])+[$entry]) | .status="wont_do"' \
          "$TF" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$TF"
        mkdir -p "$TASKS_ROOT/wont_do"
        mv -f "$TF" "$TASKS_ROOT/wont_do/$TID.json"
        ok "自清：$TID 移進 wont_do/"
      else
        rm -f "$tmp"
        bad "自清：history 寫入失敗（任務仍留在 $CURST/，人工處置）"
      fi
      flock -u "$lockfd"
      exec {lockfd}<&-
      ;;
    *) bad "自清：任務標題非 SMOKE- 開頭（$TITLE），為安全跳過（可能抓錯檔，人工檢查）" ;;
  esac
fi

rm -f "$CK"
echo
echo "===== 煙霧結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

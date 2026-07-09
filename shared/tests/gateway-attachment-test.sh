#!/usr/bin/env bash
# gateway-attachment-test.sh — gateway worker 附件傳送驗收 fixture
# (task 20260708-1425-b8e3-gateway-worker-attachment)
#
# gateway.ts 是長駐 daemon（TG long-poll + sqlite 排程 + 熱 worker），沒有把整支拉起來
# 單元測試的空間，也絕不能打真實 Telegram API。新邏輯抽在 gateway-builder/attachment.ts
# （純函式，無 daemon 副作用）——本測試直接對它跑純邏輯斷言 + 對本地 mock HTTP server
# 驗證 sendFile 的實際 multipart 行為（tgApiBase 參數注入，同 repo 慣例：外部依賴一律可覆寫）。
#
# 用法：ATTACH_SRC=<attachment.ts 路徑> GW_SRC=<gateway.ts 路徑> bash gateway-attachment-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
ATTACH_SRC="${ATTACH_SRC:-/home/oldrabbit/.claude-bots/gateway-builder/attachment.ts}"
GW_SRC="${GW_SRC:-/home/oldrabbit/.claude-bots/gateway-builder/gateway.ts}"

for f in "$ATTACH_SRC" "$GW_SRC"; do
  [ -f "$f" ] || { echo "FATAL: 找不到 $f"; exit 1; }
done
if ! grep -q "sendReplyWithAttachments" "$GW_SRC"; then
  echo "FATAL: $GW_SRC 未接線 sendReplyWithAttachments——受測代碼太舊/回歸，拒跑。"
  exit 1
fi
if ! grep -q "tgApiBase" "$ATTACH_SRC"; then
  echo "FATAL: $ATTACH_SRC 的 sendFile 不支援 tgApiBase 注入——無法安全測試（會打真實 Telegram），拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/gateway-attachment-test-XXXXXX)
mkdir -p "$FIX/bot-workspace" "$FIX/outside-workspace"
echo "report content" > "$FIX/bot-workspace/report.txt"
mkdir -p "$FIX/bot-workspace/sub"
echo "nested" > "$FIX/bot-workspace/sub/nested.txt"
printf '\xff\xd8\xff' > "$FIX/bot-workspace/pic.jpg"  # 假 jpg 檔頭，測 sendPhoto 路徑選擇
echo "secret" > "$FIX/outside-workspace/secret.txt"
ln -sf "$FIX/outside-workspace/secret.txt" "$FIX/bot-workspace/escape-link.txt"  # symlink 越權嘗試

echo "=== 1. extractAttachments：純文字 passthrough 不受影響 ==="
"$BUN" -e "
import { extractAttachments } from '$ATTACH_SRC';
const r = extractAttachments('普通回覆，沒有任何附件標記。');
if (r.cleanText === '普通回覆，沒有任何附件標記。' && r.rawPaths.length === 0) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "無 attach: 標記時 cleanText 與原文等價、rawPaths 為空" || bad "純文字 passthrough 斷言失敗"

echo "=== 2. extractAttachments：單一/多個 attach: 標記都能抽出且從文字移除 ==="
"$BUN" -e "
import { extractAttachments } from '$ATTACH_SRC';
const r = extractAttachments('這是報告：\nattach:$FIX/bot-workspace/report.txt\n順便附一張圖\nattach:$FIX/bot-workspace/pic.jpg\n');
if (r.rawPaths.length === 2 && r.rawPaths[0] === '$FIX/bot-workspace/report.txt' && r.rawPaths[1] === '$FIX/bot-workspace/pic.jpg'
    && !r.cleanText.includes('attach:') && r.cleanText.includes('這是報告') && r.cleanText.includes('順便附一張圖')) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "多個 attach: 標記正確抽出，文字保留其餘內容" || bad "多標記抽取斷言失敗"

echo "=== 3. resolveSafeAttachPath：workspace 內的檔案(絕對路徑/相對路徑/巢狀)都放行 ==="
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const a = resolveSafeAttachPath('$FIX/bot-workspace', '$FIX/bot-workspace/report.txt');
const b = resolveSafeAttachPath('$FIX/bot-workspace', 'report.txt');
const c = resolveSafeAttachPath('$FIX/bot-workspace', 'sub/nested.txt');
if (a.ok && b.ok && c.ok) process.exit(0);
console.error(JSON.stringify({a,b,c})); process.exit(1);
" && ok "絕對路徑/相對路徑/巢狀路徑都正確放行" || bad "合法路徑斷言失敗"

echo "=== 4. resolveSafeAttachPath：目錄字首混淆攻擊（/foo vs /foobar）必須擋 ==="
mkdir -p "$FIX/bot-workspacX/evil"
echo "evil" > "$FIX/bot-workspacX/evil/x.txt"
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const r = resolveSafeAttachPath('$FIX/bot-workspace', '$FIX/bot-workspacX/evil/x.txt');
if (!r.ok) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "字首混淆(bot-workspace vs bot-workspacX)正確擋下，非 naive startsWith" || bad "字首混淆漏洞未擋！"

echo "=== 5. resolveSafeAttachPath：明確越權路徑（workspace 外的絕對路徑）必須擋 ==="
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const r = resolveSafeAttachPath('$FIX/bot-workspace', '$FIX/outside-workspace/secret.txt');
if (!r.ok && r.reason && r.reason.includes('超出')) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "workspace 外絕對路徑被拒絕，且理由清楚" || bad "越權路徑未擋！"

echo "=== 6. resolveSafeAttachPath：symlink 逃逸（連結在 workspace 內，指向 workspace 外）必須擋 ==="
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const r = resolveSafeAttachPath('$FIX/bot-workspace', 'escape-link.txt');
if (!r.ok) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "symlink 指向 workspace 外被 realpath 解析後擋下" || bad "symlink 逃逸未擋！嚴重漏洞"

echo "=== 7. resolveSafeAttachPath：不存在的檔案 → 拒絕且理由清楚 ==="
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const r = resolveSafeAttachPath('$FIX/bot-workspace', 'does-not-exist.txt');
if (!r.ok && r.reason && r.reason.includes('不存在')) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "不存在的檔案正確拒絕" || bad "不存在檔案斷言失敗"

echo "=== 8. resolveSafeAttachPath：超過大小上限 → 拒絕 ==="
truncate -s 46M "$FIX/bot-workspace/huge.bin" 2>/dev/null || dd if=/dev/zero of="$FIX/bot-workspace/huge.bin" bs=1M count=46 2>/dev/null
"$BUN" -e "
import { resolveSafeAttachPath } from '$ATTACH_SRC';
const r = resolveSafeAttachPath('$FIX/bot-workspace', 'huge.bin');
if (!r.ok && r.reason && r.reason.includes('過大')) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "超過 45MB 上限的檔案正確拒絕" || bad "檔案過大斷言失敗"

echo "=== 9. sendFile：對本地 mock server，jpg 走 sendPhoto、其餘走 sendDocument ==="
cat > "$FIX/mock-server.ts" <<'EOF'
const hits: string[] = [];
Bun.serve({
  port: Number(process.argv[2]),
  async fetch(req) {
    const url = new URL(req.url);
    const form = await req.formData();
    const chatId = form.get("chat_id");
    const hasPhoto = form.has("photo");
    const hasDoc = form.has("document");
    hits.push(`${url.pathname}|chat=${chatId}|photo=${hasPhoto}|doc=${hasDoc}`);
    await Bun.write(process.argv[3], hits.join("\n"));
    if (url.pathname.includes("fail-me")) return Response.json({ ok: false, description: "mock failure" });
    return Response.json({ ok: true, result: {} });
  },
});
EOF
"$BUN" "$FIX/mock-server.ts" 18777 "$FIX/hits.log" &
MOCKPID=$!
trap 'kill $MOCKPID 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -sm 1 -o /dev/null -X POST "http://127.0.0.1:18777/ping" -F "chat_id=x" -F "document=@$FIX/bot-workspace/report.txt" && break; sleep 0.2; done

"$BUN" -e "
import { sendFile } from '$ATTACH_SRC';
const r1 = await sendFile('faketoken', '999', '$FIX/bot-workspace/pic.jpg', 'http://127.0.0.1:18777');
const r2 = await sendFile('faketoken', '999', '$FIX/bot-workspace/report.txt', 'http://127.0.0.1:18777');
if (!r1.ok || !r2.ok) { console.error('sendFile 回傳非 ok', JSON.stringify({r1,r2})); process.exit(1); }
process.exit(0);
"
sleep 0.3
hits=$(cat "$FIX/hits.log" 2>/dev/null)
echo "$hits" | grep -q "sendPhoto.*photo=true" && ok "jpg 走 sendPhoto、photo 欄位存在" || bad "jpg 未走 sendPhoto：$hits"
echo "$hits" | grep -q "sendDocument.*doc=true" && ok "txt 走 sendDocument、document 欄位存在" || bad "txt 未走 sendDocument：$hits"
echo "$hits" | grep -q "chat=999" && ok "chat_id 正確帶入 multipart" || bad "chat_id 缺失：$hits"

echo "=== 10. sendFile：mock server 回 ok:false 時，函式回傳 ok:false + error ==="
"$BUN" -e "
import { sendFile } from '$ATTACH_SRC';
const r = await sendFile('faketoken', '999', '$FIX/bot-workspace/report.txt', 'http://127.0.0.1:18777/fail-me');
if (!r.ok && r.error) process.exit(0);
console.error(JSON.stringify(r)); process.exit(1);
" && ok "Telegram 回傳失敗時正確回傳 ok:false+error" || bad "失敗傳遞斷言失敗"

echo "=== 11. gateway.ts 結構檢查：sendReplyWithAttachments 已接在 runTask 的送出點，取代直接 sendText ==="
grep -q "await sendReplyWithAttachments(bot, task.chat_id, r.reply);" "$GW_SRC" \
  && ok "runTask 送出點已改用 sendReplyWithAttachments" || bad "runTask 送出點仍是舊的 sendText 或接線缺漏"
grep -q 'from "\./attachment"' "$GW_SRC" && ok "gateway.ts 已 import attachment 模組" || bad "缺 import"

kill $MOCKPID 2>/dev/null
echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

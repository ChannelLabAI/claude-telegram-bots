#!/usr/bin/env bash
# mvp-task-attachments-test.sh — d1c9 需求單附件驗收 fixture
# （task 20260708-2346-d1c9-task-form-attachments）
#
# 涵蓋：①identity-bound 使用者可上傳②唯讀 viewer(identity=NULL，同 c8b4 密碼閘模型)
# 被擋 403③未登入 401④大小/型別白名單/檔數上限④magic bytes 檢查擋偽造型別
# ⑤下載走白名單查找，防路徑穿越⑥PDF/文件走強制下載、圖檔走 inline。
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_ATTACHMENTS_DIR MVP_ATTACHMENT_MAX_BYTES MVP_ATTACHMENT_MAX_COUNT; do
  if ! grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null; then
    echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑。"
    exit 1
  fi
done

FIX=$(mktemp -d /tmp/mvp-attach-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
mkdir -p "$FIX/files"

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_ATTACHMENTS_DIR="$FIX/tasks/attachments"
export MVP_ATTACHMENT_MAX_BYTES=2000    # 2000 bytes，小到方便測超限
export MVP_ATTACHMENT_MAX_COUNT=3
export MVP_DEV_MODE=1
export MVP_PORT=18930
REAL_GB="/home/oldrabbit/.claude-bots/gateway-builder"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }

# 準備一筆已存在的任務給附件用
cat > "$FIX/tasks/pending/attachtest1.json" <<'EOF'
{"task_id":"attachtest1","slug":"attach-demo","assigned":"anna","created_by":"anya","history":[{"ts":"2026-07-08T00:00:00+08:00","to":"pending/"}]}
EOF

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$2" -X POST -d "email=$1" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null; }
CODE(){ local ck=$1; shift; curl -sm 10 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" "$@"; }
API(){ local ck=$1; shift; curl -sm 10 -b "$FIX/ck-$ck" "$@"; }

login "attacher@x.local" attacher
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET identity='anna' WHERE email='attacher@x.local';"  # anna 是 team-config.json 真實已知 identity，fatq attach 的 resolve_identity 才會放行
login "viewer@x.local" viewer   # dev-login 預設 role=member、identity=NULL，等同 c8b4 密碼閘唯讀 viewer 的處境

# ── 準備測試檔案（真的合法 magic bytes，不是隨便塞副檔名）───────────────────
python3 -c "
import struct, zlib
# 最小合法 1x1 PNG
sig = b'\x89PNG\r\n\x1a\n'
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag+data))
ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
idat = zlib.compress(b'\x00\xff\x00\x00')
png = sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open('$FIX/files/real.png', 'wb').write(png)
" 2>&1
printf '%%PDF-1.4\n%%%%EOF' > "$FIX/files/real.pdf"
printf 'this is not actually a png' > "$FIX/files/fake.png"   # 假裝 png，magic bytes 不符
head -c 3000 /dev/urandom > "$FIX/files/oversized.png" 2>/dev/null || dd if=/dev/urandom of="$FIX/files/oversized.png" bs=3000 count=1 2>/dev/null
echo "just some text content" > "$FIX/files/notes.txt"
printf 'MZ\x90\x00fake-exe-content' > "$FIX/files/malware.exe"

echo "=== U1 identity-bound 使用者上傳合法 PNG → 200，task JSON 記到附件，/api/tasks 帶出來 ==="
r1=$(API attacher -X POST -F "file=@$FIX/files/real.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
echo "$r1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert len(d.get('attachments',[]))==1, d
assert d['attachments'][0]['name']=='real.png', d
" && ok "合法 PNG 上傳成功，回應含正確 metadata" || bad "U1 斷言失敗：$(echo "$r1"|head -c 300)"
listed=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0]
print(len(t.get('attachments',[])))
")
[ "$listed" = "1" ] && ok "/api/tasks 列表帶出附件筆數" || bad "/api/tasks 沒有正確帶出附件，筆數=$listed"

echo "=== U2（review_focus 核心）：唯讀 viewer（identity=NULL，同 c8b4 密碼閘模型）上傳被擋 403 ==="
c2=$(CODE viewer -X POST -F "file=@$FIX/files/real.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
[ "$c2" = "403" ] && ok "唯讀 viewer 上傳 → 403（跟 c8b4 授權模型一致，寫入權限不比建單寬）" || bad "唯讀 viewer 上傳 → $c2（期望 403）"

echo "=== U3 未登入（無 session）上傳被擋 401 ==="
c3=$(curl -sm 10 -o /dev/null -w "%{http_code}" -X POST -F "file=@$FIX/files/real.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
[ "$c3" = "401" ] && ok "未登入上傳 → 401" || bad "未登入上傳 → $c3（期望 401）"

echo "=== U4 超過大小上限 → 400，不落地不登記 ==="
before=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "import json,sys;d=json.load(sys.stdin);t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0];print(len(t.get('attachments',[])))")
c4=$(CODE attacher -X POST -F "file=@$FIX/files/oversized.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
after=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "import json,sys;d=json.load(sys.stdin);t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0];print(len(t.get('attachments',[])))")
[ "$c4" = "400" ] && ok "超過大小上限 → 400" || bad "超過大小上限 → $c4（期望 400）"
[ "$before" = "$after" ] && ok "超限的檔案沒有被登記進 task JSON" || bad "超限檔案竟然登記進去了！$before -> $after"

echo "=== U5 型別不在白名單（.exe）→ 400 ==="
c5=$(CODE attacher -X POST -F "file=@$FIX/files/malware.exe;type=application/x-msdownload" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
[ "$c5" = "400" ] && ok "不在白名單型別 → 400" || bad "不在白名單型別 → $c5（期望 400）"

echo "=== U6（magic bytes 防偽造）：宣稱 image/png 但內容不是真 PNG → 400 ==="
c6=$(CODE attacher -X POST -F "file=@$FIX/files/fake.png;type=image/png" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
[ "$c6" = "400" ] && ok "偽造 PNG（假 Content-Type，真內容不符）→ 400" || bad "偽造 PNG → $c6（期望 400，magic bytes 檢查沒生效）"

echo "=== U7 超過單次檔數上限（cap=3，帶 4 個）→ 400，全部不登記（all-or-nothing） ==="
before7=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "import json,sys;d=json.load(sys.stdin);t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0];print(len(t.get('attachments',[])))")
c7=$(CODE attacher -X POST \
  -F "file=@$FIX/files/notes.txt;type=text/plain" -F "file=@$FIX/files/notes.txt;type=text/plain" \
  -F "file=@$FIX/files/notes.txt;type=text/plain" -F "file=@$FIX/files/notes.txt;type=text/plain" \
  "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
after7=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "import json,sys;d=json.load(sys.stdin);t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0];print(len(t.get('attachments',[])))")
[ "$c7" = "400" ] && ok "超過單次檔數上限 → 400" || bad "超過單次檔數上限 → $c7（期望 400）"
[ "$before7" = "$after7" ] && ok "超額請求沒有留下任何半成品附件" || bad "超額請求留下半成品！$before7 -> $after7"

echo "=== U8 上傳合法 PDF（非圖檔）→ 200 ==="
r8=$(API attacher -X POST -F "file=@$FIX/files/real.pdf;type=application/pdf" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments")
echo "$r8" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
" && ok "合法 PDF 上傳成功" || bad "U8 斷言失敗：$(echo "$r8"|head -c 300)"

echo "=== U9 下載：圖檔走 inline，文件走 attachment，內容正確 ==="
png_file=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0]
png=[a for a in t['attachments'] if a['name']=='real.png'][0]
print(png['file'])
")
hdr9=$(curl -sm 10 -D - -o "$FIX/downloaded.png" -b "$FIX/ck-attacher" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments/$png_file")
echo "$hdr9" | grep -qi "content-disposition: inline" && ok "圖檔下載 → Content-Disposition: inline" || bad "圖檔下載 disposition 錯誤：$(echo "$hdr9"|grep -i disposition)"
cmp -s "$FIX/files/real.png" "$FIX/downloaded.png" && ok "下載內容跟上傳的位元組完全一致" || bad "下載內容跟上傳不一致！"

pdf_file=$(API attacher "http://127.0.0.1:$MVP_PORT/api/tasks" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=[x for x in d['tasks'] if x['file']=='attachtest1.json'][0]
pdf=[a for a in t['attachments'] if a['name']=='real.pdf'][0]
print(pdf['file'])
")
hdr9b=$(curl -sm 10 -D - -o /dev/null -b "$FIX/ck-attacher" "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments/$pdf_file")
echo "$hdr9b" | grep -qi "content-disposition: attachment" && ok "PDF 下載 → Content-Disposition: attachment（強制下載）" || bad "PDF 下載 disposition 錯誤：$(echo "$hdr9b"|grep -i disposition)"

echo "=== U10（防路徑穿越核心）：下載一個沒被 task 登記過的檔名 → 404，不會真的拿去拼路徑查磁碟 ==="
c10a=$(CODE attacher "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments/does-not-exist.png")
[ "$c10a" = "404" ] && ok "未登記過的檔名 → 404" || bad "未登記過的檔名 → $c10a（期望 404）"
c10b=$(CODE attacher "http://127.0.0.1:$MVP_PORT/api/tasks/attachtest1/attachments/..%2f..%2f..%2fetc%2fpasswd")
[ "$c10b" = "404" ] && ok "路徑穿越字串（URL-encoded ../../..)→ 404" || bad "路徑穿越字串 → $c10b（期望 404）"

echo "=== U11 對不存在的 task_id 上傳/下載 → 404 ==="
c11a=$(CODE attacher -X POST -F "file=@$FIX/files/notes.txt;type=text/plain" "http://127.0.0.1:$MVP_PORT/api/tasks/does-not-exist-task/attachments")
[ "$c11a" = "404" ] && ok "對不存在的任務上傳 → 404" || bad "對不存在的任務上傳 → $c11a（期望 404）"
c11b=$(CODE attacher "http://127.0.0.1:$MVP_PORT/api/tasks/does-not-exist-task/attachments/x.png")
[ "$c11b" = "404" ] && ok "對不存在的任務下載 → 404" || bad "對不存在的任務下載 → $c11b（期望 404）"

echo "=== U12 audit.log 記到上傳事件 ==="
grep -q '"action":"attachment_uploaded"' "$FIX/mvp/audit.log" 2>/dev/null && ok "audit.log 記到附件上傳" || bad "audit.log 缺附件上傳紀錄"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

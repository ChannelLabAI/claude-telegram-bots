#!/usr/bin/env bash
# mvp-secure-public-access-test.sh — c8b4 公開暴露前置安全驗收 fixture
# （task 20260708-1905-c8b4-mvp-secure-public-access，v2＝老兔風險偏好校準後的
# 簡化版：共用密碼閘取代嚴格 OAuth 白名單為主要入口；OAuth 白名單邏輯保留作為
# defense-in-depth，Bella REJECT 的兩個 BLOCKER 已回頭補：①白名單每請求複查
# ②session cookie 依 X-Forwarded-Proto 動態上 Secure）。
#
# Google OAuth token/userinfo 端點走假伺服器（stub-google-oauth.ts），絕不真的
# 打 Google——同 MVP_SYSTEMCTL_BIN 慣例，換一個可控的假執行體。
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_ALLOWED_EMAILS MVP_GOOGLE_TOKEN_URL MVP_GOOGLE_USERINFO_URL MVP_RATE_LIMIT_WINDOW_MS MVP_RATE_LIMIT_AUTH_CAP MVP_RATE_LIMIT_GENERAL_CAP MVP_PUBLIC_PASSWORD MVP_PUBLIC_GATE_EMAIL; do
  if ! grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null; then
    echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑。"
    exit 1
  fi
done
STUB_SCRIPT="$SRC/stub-google-oauth.ts"
[ -f "$STUB_SCRIPT" ] || { echo "FATAL: 找不到 $STUB_SCRIPT（假 Google OAuth 端點），拒跑"; exit 1; }

FIX=$(mktemp -d /tmp/mvp-secure-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}

STUB_PORT=18900
STUB_TOKEN_URL="http://127.0.0.1:$STUB_PORT/token"
STUB_USERINFO_URL="http://127.0.0.1:$STUB_PORT/v1/userinfo"
STUB_PORT="$STUB_PORT" "$BUN" "$STUB_SCRIPT" >> "$FIX/stub.log" 2>&1 &
STUB_PID=$!
trap 'kill $SPID $STUB_PID 2>/dev/null; rm -rf "$FIX"' EXIT

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_ALLOWED_EMAILS="bthare.grant@gmail.com"
export MVP_GOOGLE_TOKEN_URL="$STUB_TOKEN_URL"
export MVP_GOOGLE_USERINFO_URL="$STUB_USERINFO_URL"
REAL_GB="/home/oldrabbit/.claude-bots/gateway-builder"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }

CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" "$@"; }
API(){ curl -sm 10 "$@"; }

# ════════════════════════════════════════════════════════════════════════
# 第一段：OAuth 白名單 + dev-login + rate limit（PUBLIC_MODE 關）
# ════════════════════════════════════════════════════════════════════════
export MVP_PORT=18901
export MVP_BASE_URL="http://127.0.0.1:18901"
export MVP_RATE_LIMIT_WINDOW_MS=4000
export MVP_RATE_LIMIT_AUTH_CAP=8
export MVP_RATE_LIMIT_GENERAL_CAP=6
unset MVP_PUBLIC_PASSWORD MVP_PUBLIC_GATE_EMAIL MVP_DEV_MODE

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server1.log" 2>&1 &
SPID=$!
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server1.log"; exit 1; }
curl -sm1 -o /dev/null "http://127.0.0.1:$STUB_PORT/v1/userinfo" || { echo "FATAL: stub google oauth 起不來"; cat "$FIX/stub.log"; exit 1; }

echo "=== S1 dev-login：MVP_DEV_MODE 完全不設 → /auth/dev-login 404（真正關閉，非僅前端藏） ==="
c1=$(CODE -X POST -d "email=x@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login")
[ "$c1" = "404" ] && ok "dev-login 未設 MVP_DEV_MODE → 404" || bad "dev-login → $c1（期望 404）"

echo "=== S2 OAuth 白名單：白名單內 email 走完整流程 → 302 + session cookie + user row 建立 ==="
r2=$(curl -sD - -o /dev/null "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-allowed")
echo "$r2" | grep -q "^HTTP/1.1 302" && ok "白名單 email → 302" || bad "白名單 email 未回 302：$(echo "$r2"|head -1)"
echo "$r2" | grep -qi "set-cookie: mvp_session=" && ok "白名單 email → session cookie 已發" || bad "白名單 email 未拿到 session cookie"
echo "$r2" | grep -qi "set-cookie:.*Secure" && bad "本機明文請求竟然被加了 Secure（會讓後續 curl 明文重放失效）" || ok "本機明文請求（無 X-Forwarded-Proto）cookie 沒有 Secure，本機/curl 測試不受影響"
row=$(sqlite3 "$FIX/mvp/users.db" "SELECT email FROM users WHERE email='bthare.grant@gmail.com';" 2>/dev/null)
[ "$row" = "bthare.grant@gmail.com" ] && ok "白名單 email 的 user row 已建立" || bad "白名單 email 的 user row 未建立"

echo "=== S2b Secure cookie：帶 X-Forwarded-Proto: https（模擬 cloudflared/Caddy 前置）→ set-cookie 帶 Secure ==="
r2b=$(curl -sD - -o /dev/null -H "X-Forwarded-Proto: https" "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-allowed")
echo "$r2b" | grep -qi "set-cookie:.*Secure" && ok "有 X-Forwarded-Proto:https → cookie 帶 Secure" || bad "有 X-Forwarded-Proto:https 卻沒帶 Secure（Bella BLOCKER②回歸）"

echo "=== S3 OAuth 白名單：非白名單 email 一律 403，且不建 user row（不留痕跡讓對方知道系統存在帳號機制） ==="
c3=$(CODE "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-denied")
[ "$c3" = "403" ] && ok "非白名單 email → 403" || bad "非白名單 email → $c3（期望 403）"
row2=$(sqlite3 "$FIX/mvp/users.db" "SELECT COUNT(*) FROM users WHERE email='attacker@evil.com';" 2>/dev/null)
[ "$row2" = "0" ] && ok "非白名單 email 沒有建立 user row" || bad "非白名單 email 竟然建立了 user row！洩漏帳號機制"
grep -q '"action":"oauth_login_denied_not_allowlisted"' "$FIX/mvp/audit.log" 2>/dev/null && ok "audit.log 記到被拒登入" || bad "audit.log 缺被拒登入紀錄"

echo "=== S3b（Bella REJECT BLOCKER①回歸，反面 case）：既有非白名單帳號的舊 session，之後每一請求都要被擋，不能只擋登入那次 ==="
# 手動塞一個「已經走過 OAuth」的非白名單帳號 row（google_sub 有值），模擬白名單上線前
# 就已經登入過、手上還握著有效 30 天 cookie 的舊帳號（正是生產 rung1211 的處境）。
sqlite3 "$FIX/mvp/users.db" "INSERT INTO users (email,name,google_sub,role,created_at) VALUES ('legacy-nonallowlisted@evil.com','legacy','legacy-sub','member','2026-01-01T00:00:00Z');"
legacy_id=$(sqlite3 "$FIX/mvp/users.db" "SELECT id FROM users WHERE email='legacy-nonallowlisted@evil.com';")
secret=$(sqlite3 "$FIX/mvp/users.db" "SELECT v FROM kv WHERE k='session_secret';")
legacy_cookie=$(python3 -c "
import hmac, hashlib, sys
v, secret = sys.argv[1], sys.argv[2]
sig = hmac.new(secret.encode(), v.encode(), hashlib.sha256).hexdigest()[:32]
print(f'{v}.{sig}')
" "$legacy_id" "$secret")
c3b=$(CODE -H "Cookie: mvp_session=$legacy_cookie" "http://127.0.0.1:$MVP_PORT/api/tasks")
[ "$c3b" = "401" ] && ok "既有非白名單 OAuth 帳號的舊 cookie 打 /api 被擋（401，非全權放行）" || bad "既有非白名單帳號的舊 cookie 竟然還能打 /api！(status=$c3b) BLOCKER①回歸"

echo "=== S4 rate limit：/auth/* 窗口較嚴，超過 cap 後 429 且帶 Retry-After ==="
# 前面 S1~S3 已經吃掉 4 個 auth 路由請求額度（同一窗口累計），這裡多跑幾次確保
# 真的超過 cap（不必精算，迴圈夠長、抓到 429 就跳出即可）。
got429=""
for i in $(seq 1 12); do
  c=$(CODE "http://127.0.0.1:$MVP_PORT/auth/callback?code=nonexistent-$i")
  [ "$c" = "429" ] && { got429="$c"; break; }
done
[ "${got429:-}" = "429" ] && ok "auth 路由超過窗口 cap 後回 429" || bad "auth 路由未觸發 429（可能 rate limit 沒接上）"
hdr=$(curl -sD - -o /dev/null "http://127.0.0.1:$MVP_PORT/auth/callback?code=x" | grep -i "retry-after")
[ -n "$hdr" ] && ok "429 回應帶 Retry-After" || bad "429 回應缺 Retry-After"

echo "=== S5 rate limit：一般路由（/api/tasks 未登入）也有獨立窗口，與 auth 路由分開計數 ==="
sleep 3.2  # 跨過上一段測試的窗口，避免殘留計數干擾
got429b=""
for i in $(seq 1 10); do
  c=$(CODE "http://127.0.0.1:$MVP_PORT/api/tasks")
  [ "$c" = "429" ] && { got429b="$c"; break; }
done
[ "$got429b" = "429" ] && ok "一般路由超過窗口 cap 後也回 429" || bad "一般路由未觸發 429"

kill "$SPID" 2>/dev/null
wait "$SPID" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════
# 第二段：共用密碼閘（PUBLIC_MODE 開，老兔風險偏好校準後的主入口）
# ════════════════════════════════════════════════════════════════════════
export MVP_PORT=18902
export MVP_BASE_URL="http://127.0.0.1:18902"
export MVP_PUBLIC_PASSWORD="s3cr3t-gate-pw"
# MVP_PUBLIC_GATE_EMAIL 刻意不覆寫——測真實生產預設值（獨立合成 viewer 帳號），
# 不能讓密碼閘綁到老兔本人的 email（Bella 第二次 REJECT 的根因就是這個）。
unset MVP_PUBLIC_GATE_EMAIL
export MVP_RATE_LIMIT_WINDOW_MS=4000
export MVP_RATE_LIMIT_AUTH_CAP=8
export MVP_RATE_LIMIT_GENERAL_CAP=12

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server2.log" 2>&1 &
SPID=$!
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server(密碼閘) 起不來"; cat "$FIX/server2.log"; exit 1; }

echo "=== S6 密碼閘：未帶 session 打首頁 → 顯示密碼頁而非直接放行 app ==="
body=$(curl -sm 10 "http://127.0.0.1:$MVP_PORT/")
echo "$body" | grep -q 'name="password"' && ok "未登入首頁回密碼輸入頁" || bad "未登入首頁沒有回密碼頁，可能直接洩漏 app"
echo "$body" | grep -q "app.html missing\|艦隊\|fleetPane" && bad "未登入首頁竟然洩漏了 app 本體內容" || ok "未登入首頁沒有洩漏 app 本體內容"

echo "=== S7 密碼閘：密碼錯誤 → 401，不發 session ==="
c7=$(CODE -X POST -d "password=wrong-pw" "http://127.0.0.1:$MVP_PORT/gate")
[ "$c7" = "401" ] && ok "密碼錯誤 → 401" || bad "密碼錯誤 → $c7（期望 401）"

echo "=== S8 密碼閘：密碼正確 → 302 + session cookie，綁定獨立合成帳號（role=member，非老兔本人 admin 帳號） ==="
ck8="$FIX/ck-gate"
r8=$(curl -sc "$ck8" -D - -o /dev/null -X POST -d "password=s3cr3t-gate-pw" "http://127.0.0.1:$MVP_PORT/gate")
echo "$r8" | grep -q "^HTTP/1.1 302" && ok "密碼正確 → 302" || bad "密碼正確卻沒 302：$(echo "$r8"|head -1)"
me8=$(curl -sb "$ck8" "http://127.0.0.1:$MVP_PORT/api/me")
echo "$me8" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('email')=='public-viewer@mvp-gate.local', d
assert d.get('role')=='member', d
" && ok "密碼閘通過後拿到 member(viewer) session，不是老兔本人的 admin 帳號" || bad "S8 斷言失敗：$(echo "$me8"|head -c 200)"

echo "=== S9（Bella 第二次 REJECT BLOCKER 回歸，反面 case）：密碼閘 viewer session 打重啟端點必須 403，leaked 密碼不得重啟 bot ==="
c9=$(CODE -b "$ck8" -X POST -d '{"confirm":"assist-anya"}' "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/restart")
[ "$c9" = "403" ] && ok "密碼閘 viewer session 打重啟端點 → 403（入口鬆不等於能動手）" || bad "密碼閘 viewer session 打重啟端點 → $c9（期望 403，leaked 密碼若能重啟即回歸 Bella BLOCKER）"

echo "=== S9b 對照組：真正的老兔（google_sub 綁定+白名單 OAuth）在同一支密碼閘啟用的伺服器上，admin 權限不受影響 ==="
ck9b="$FIX/ck-oauth-admin"
curl -sc "$ck9b" -o /dev/null "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-allowed"
me9b=$(curl -sb "$ck9b" "http://127.0.0.1:$MVP_PORT/api/me")
echo "$me9b" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('email')=='bthare.grant@gmail.com', d
assert d.get('role')=='admin', d
" && ok "老兔本人 OAuth 登入在密碼閘模式下仍拿到真 admin session（雙路徑並存，密碼閘不影響 OAuth admin）" || bad "S9b 斷言失敗：$(echo "$me9b"|head -c 200)"
c9b=$(CODE -b "$ck9b" -X POST -d '{}' "http://127.0.0.1:$MVP_PORT/api/bot/does-not-exist/restart")
# does-not-exist 不在白名單會先 404；這裡只驗證「真 admin 能過 role 關」，白名單/confirm 是後面兩道獨立護欄。
{ [ "$c9b" = "400" ] || [ "$c9b" = "404" ]; } && ok "真 admin session 能過 role 關，卡在白名單/confirm（b7f3 護欄仍生效，非裸放行）" || bad "真 admin session 打重啟端點 → $c9b（期望 400/404）"

echo "=== S10 rate limit：/gate 本身算 auth 路由，一樣有嚴格窗口 ==="
got429c=""
for i in $(seq 1 12); do
  c=$(CODE -X POST -d "password=wrong-$i" "http://127.0.0.1:$MVP_PORT/gate")
  [ "$c" = "429" ] && { got429c="$c"; break; }
done
[ "${got429c:-}" = "429" ] && ok "/gate 密碼嘗試超過窗口 cap 後回 429（防暴力破解）" || bad "/gate 未觸發 429，密碼閘無暴力破解防護"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

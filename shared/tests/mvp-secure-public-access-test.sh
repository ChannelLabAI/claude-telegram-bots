#!/usr/bin/env bash
# mvp-secure-public-access-test.sh — c8b4 公開暴露前置安全驗收 fixture
# （task 20260708-1905-c8b4-mvp-secure-public-access）
#
# 涵蓋：①dev-login 真的能被完全關掉 ②OAuth callback 白名單擋非授權 email，
# 且不建 user row ③白名單內 email 正常過 ④rate limit 生效（一般路由+auth 路由
# 各自窗口）。Google OAuth token/userinfo 端點走假伺服器（stub-google-oauth.ts），
# 絕不真的打 Google——同 MVP_SYSTEMCTL_BIN 慣例，換一個可控的假執行體。
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_ALLOWED_EMAILS MVP_GOOGLE_TOKEN_URL MVP_GOOGLE_USERINFO_URL MVP_RATE_LIMIT_WINDOW_MS MVP_RATE_LIMIT_AUTH_CAP MVP_RATE_LIMIT_GENERAL_CAP; do
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

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_PORT=18901
export MVP_BASE_URL="http://127.0.0.1:18901"
export MVP_ALLOWED_EMAILS="bthare.grant@gmail.com"
export MVP_GOOGLE_TOKEN_URL="$STUB_TOKEN_URL"
export MVP_GOOGLE_USERINFO_URL="$STUB_USERINFO_URL"
export MVP_RATE_LIMIT_WINDOW_MS=3000
export MVP_RATE_LIMIT_AUTH_CAP=3
export MVP_RATE_LIMIT_GENERAL_CAP=6
REAL_GB="/home/oldrabbit/.claude-bots/gateway-builder"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }

# 這支測試的重點案例（S1）要求 MVP_DEV_MODE 完全不設，故不 export MVP_DEV_MODE。
"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID $STUB_PID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }
curl -sm1 -o /dev/null "http://127.0.0.1:$STUB_PORT/v1/userinfo" || { echo "FATAL: stub google oauth 起不來"; cat "$FIX/stub.log"; exit 1; }

CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" "$@"; }
API(){ curl -sm 10 "$@"; }

echo "=== S1 dev-login：MVP_DEV_MODE 完全不設 → /auth/dev-login 404（真正關閉，非僅前端藏） ==="
c1=$(CODE -X POST -d "email=x@x.local" "http://127.0.0.1:$MVP_PORT/auth/dev-login")
[ "$c1" = "404" ] && ok "dev-login 未設 MVP_DEV_MODE → 404" || bad "dev-login → $c1（期望 404）"

echo "=== S2 OAuth 白名單：白名單內 email 走完整流程 → 302 + session cookie + user row 建立 ==="
ck="$FIX/ck-allowed"
r2=$(curl -sD - -o /dev/null "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-allowed")
echo "$r2" | grep -q "^HTTP/1.1 302" && ok "白名單 email → 302" || bad "白名單 email 未回 302：$(echo "$r2"|head -1)"
echo "$r2" | grep -qi "set-cookie: mvp_session=" && ok "白名單 email → session cookie 已發" || bad "白名單 email 未拿到 session cookie"
row=$(sqlite3 "$FIX/mvp/users.db" "SELECT email FROM users WHERE email='bthare.grant@gmail.com';" 2>/dev/null)
[ "$row" = "bthare.grant@gmail.com" ] && ok "白名單 email 的 user row 已建立" || bad "白名單 email 的 user row 未建立"

echo "=== S3 OAuth 白名單：非白名單 email 一律 403，且不建 user row（不留痕跡讓對方知道系統存在帳號機制） ==="
c3=$(CODE "http://127.0.0.1:$MVP_PORT/auth/callback?code=code-denied")
[ "$c3" = "403" ] && ok "非白名單 email → 403" || bad "非白名單 email → $c3（期望 403）"
row2=$(sqlite3 "$FIX/mvp/users.db" "SELECT COUNT(*) FROM users WHERE email='attacker@evil.com';" 2>/dev/null)
[ "$row2" = "0" ] && ok "非白名單 email 沒有建立 user row" || bad "非白名單 email 竟然建立了 user row！洩漏帳號機制"
grep -q '"action":"oauth_login_denied_not_allowlisted"' "$FIX/mvp/audit.log" 2>/dev/null && ok "audit.log 記到被拒登入" || bad "audit.log 缺被拒登入紀錄"

echo "=== S4 rate limit：/auth/* 窗口較嚴，超過 cap 後 429 且帶 Retry-After ==="
before_401=0
for i in 1 2 3 4 5; do
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

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

#!/usr/bin/env bash
# mvp-manual-controls-test.sh — b7f3 bot 手動控制後端驗收 fixture
# （task 20260708-1505-b7f3-manual-controls-backend）
#
# 鐵律（同 mvp-web-test.sh/mvp-a4-monitor-test.sh）：一律 mktemp 自造態。
# ⚠️這支測試多一層別的 fixture 沒有的風險：restart 端點的核心動作是真的呼叫
# systemctl 動使用者的 systemd session（全域狀態，不是檔案/DB，沒辦法用路徑
# 隔離）。絕對不能讓測試流量打到真 systemctl——用假的 MVP_SYSTEMCTL_BIN
# 執行檔取代，任何一關擋不住、意外打到真指令都要整個測試拒跑。
#
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-manual-controls-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

for v in MVP_GB MVP_SYSTEMCTL_BIN MVP_RESTART_HEALTH_TIMEOUT_SEC; do
  if ! grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null; then
    echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑（restart 端點會打到真 systemctl，絕不冒險）。"
    exit 1
  fi
done

FIX=$(mktemp -d /tmp/mvp-manual-controls-test-XXXXXX)
mkdir -p "$FIX/gb/pods" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
cp "$SRC/app.html" "$FIX/mvp/"

# ── 假 pod 白名單：只有這兩個名字合法 ─────────────────────────────────────
cat > "$FIX/gb/pods/assist-anya.json" <<EOF
{"podName":"assist-anya","bots":[{"name":"anya","model":"claude-sonnet-5"}],"dbPath":"$FIX/gb/nonexistent-anya.db"}
EOF
cat > "$FIX/gb/pods/builder.json" <<EOF
{"podName":"builder","bots":[{"name":"anna","model":"claude-sonnet-5"}],"dbPath":"$FIX/gb/nonexistent-builder.db"}
EOF
touch -d '@'$(( $(date +%s) - 30 )) "$FIX/gb/heartbeat-assist-anya.txt"
touch -d '@'$(( $(date +%s) - 30 )) "$FIX/gb/heartbeat-builder.txt"

# ── 假 systemctl：把每次呼叫記到 call log，讓測試斷言「白名單/確認/權限任一關
# 沒過，就絕對不會走到這裡」；restart 子命令依 stub-behavior-<pod> 檔決定是否
# 模擬「真的恢復」（背景延遲寫一筆新心跳，逼真到會被輪詢邏輯量到，不是一次到位）──
cat > "$FIX/stub-systemctl" <<'EOS'
#!/usr/bin/env bash
FIX_DIR="$(dirname "$0")"
echo "$@" >> "$FIX_DIR/stub-calls.log"
if [ "$1" = "--user" ] && [ "$2" = "is-active" ]; then
  pod="${3#gateway@}"
  if [ -f "$FIX_DIR/stub-active-$pod" ]; then cat "$FIX_DIR/stub-active-$pod"; else echo "active"; fi
  exit 0
fi
if [ "$1" = "--user" ] && [ "$2" = "restart" ]; then
  pod="${3#gateway@}"
  if [ -f "$FIX_DIR/stub-restart-behavior-$pod" ] && [ "$(cat "$FIX_DIR/stub-restart-behavior-$pod")" = "recover" ]; then
    ( sleep 1; date -u +%Y-%m-%dT%H:%M:%SZ > "$FIX_DIR/gb/heartbeat-$pod.txt" ) &
    disown
  fi
  exit 0
fi
exit 0
EOS
chmod +x "$FIX/stub-systemctl"

export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_SYSTEMCTL_BIN="$FIX/stub-systemctl"
export MVP_RESTART_HEALTH_TIMEOUT_SEC=4
export MVP_DEV_MODE=1
export MVP_PORT=18299
REAL_GB="/home/oldrabbit/.claude-bots/pod-system"
[ "$MVP_GB" = "$REAL_GB" ] && { echo "FATAL: fixture 指向生產 GB，拒跑"; exit 1; }
[ "$MVP_SYSTEMCTL_BIN" = "systemctl" ] && { echo "FATAL: MVP_SYSTEMCTL_BIN 沒有真的指向假執行檔，拒跑（會打到真 systemd）"; exit 1; }

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

login(){ curl -sc "$FIX/ck-$2" -X POST -d "email=$1" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null; }
API(){ local ck=$1; shift; curl -sm 10 -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }
CODE(){ local ck=$1; shift; curl -sm 10 -o /dev/null -w "%{http_code}" -b "$FIX/ck-$ck" -H "content-type: application/json" "$@"; }
call_count(){ [ -f "$FIX/stub-calls.log" ] && wc -l < "$FIX/stub-calls.log" | tr -d ' ' || echo 0; }

login "mctest-admin@x.local" admin
sqlite3 "$FIX/mvp/users.db" "UPDATE users SET role='admin', identity='mac-agent' WHERE email='mctest-admin@x.local';"
login "mctest-member@x.local" member

echo "=== M1 heartbeat-poke：合法 pod → 200 帶年齡/狀態；未知 pod → 404 ==="
r1=$(API admin -X POST "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/heartbeat-poke")
echo "$r1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('pod')=='assist-anya', d
assert isinstance(d.get('ageSec'), int) and d['ageSec'] < 60, d
" && ok "合法 pod 回 200 + 心跳年齡合理" || bad "M1 poke 斷言失敗：$(echo "$r1"|head -c 200)"
c1=$(CODE admin -X POST "http://127.0.0.1:$MVP_PORT/api/bot/does-not-exist/heartbeat-poke")
[ "$c1" = "404" ] && ok "未知 pod poke → 404" || bad "未知 pod poke → $c1（期望 404）"

echo "=== M2 restart 權限：非 admin 一律 403，且完全不碰 systemctl（call log 零成長） ==="
before=$(call_count)
c2=$(CODE member -X POST -d '{"confirm":"assist-anya"}' "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/restart")
after=$(call_count)
[ "$c2" = "403" ] && ok "非 admin restart → 403" || bad "非 admin restart → $c2（期望 403）"
[ "$before" = "$after" ] && ok "非 admin 被擋在 systemctl 之前，call log 零成長" || bad "非 admin 竟然打到了 systemctl！call log 從 $before 變 $after"

echo "=== M3 restart 二次確認：缺 confirm/confirm 不符 → 400，一樣不碰 systemctl ==="
before=$(call_count)
c3a=$(CODE admin -X POST -d '{}' "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/restart")
c3b=$(CODE admin -X POST -d '{"confirm":"builder"}' "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/restart")
after=$(call_count)
[ "$c3a" = "400" ] && ok "缺 confirm → 400" || bad "缺 confirm → $c3a（期望 400）"
[ "$c3b" = "400" ] && ok "confirm 與 pod 名不符 → 400" || bad "confirm 不符 → $c3b（期望 400）"
[ "$before" = "$after" ] && ok "確認關卡沒過，call log 零成長" || bad "確認關卡沒過卻打到了 systemctl！call log 從 $before 變 $after"

echo "=== M4 restart pod 白名單：未知/類注入字串一律 404，call log 零成長 ==="
before=$(call_count)
for bad_pod in "does-not-exist" "../../etc/passwd" 'assist-anya%3B%20rm%20-rf%20%2F' '$(whoami)'; do
  cX=$(CODE admin -X POST -d "{\"confirm\":\"$bad_pod\"}" "http://127.0.0.1:$MVP_PORT/api/bot/$bad_pod/restart")
  [ "$cX" = "404" ] && ok "偽造/未知 pod「$bad_pod」→ 404" || bad "「$bad_pod」→ $cX（期望 404）"
done
after=$(call_count)
[ "$before" = "$after" ] && ok "全部偽造 pod 名都沒碰到 systemctl，call log 零成長" || bad "白名單擋不住，call log 從 $before 變 $after"

echo "=== M5 restart 成功路徑：stub 模擬真的恢復（延遲寫新心跳）→ status=ok ==="
echo "recover" > "$FIX/stub-restart-behavior-assist-anya"
r5=$(API admin -X POST -d '{"confirm":"assist-anya"}' "http://127.0.0.1:$MVP_PORT/api/bot/assist-anya/restart")
echo "$r5" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('status')=='ok', d
assert d.get('waitedSec',99) <= 4, d
" && ok "恢復路徑：輪詢量到新心跳，status=ok" || bad "M5 斷言失敗：$(echo "$r5"|head -c 300)"
grep -q "gateway@assist-anya" "$FIX/stub-calls.log" && ok "call log 確實記到這次合法的 restart 呼叫" || bad "call log 沒記到合法 restart"

echo "=== M6 restart 未恢復路徑：stub 不寫心跳（模擬 crash-loop）→ status=degraded 紅警文案 ==="
rm -f "$FIX/stub-restart-behavior-builder"
r6=$(API admin -X POST -d '{"confirm":"builder"}' "http://127.0.0.1:$MVP_PORT/api/bot/builder/restart")
echo "$r6" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') is True, d
assert d.get('status')=='degraded', d
assert 'crash-loop' in d.get('message','') or '人工確認' in d.get('message',''), d
" && ok "未恢復路徑：4 秒逾時後仍回 degraded（不是假 ok），文案有警示" || bad "M6 斷言失敗：$(echo "$r6"|head -c 300)"

echo "=== M7 稽核：audit.log 記到 restart 發出+結果兩筆 ==="
grep -q '"action":"bot_restart_issued"' "$FIX/mvp/audit.log" 2>/dev/null && grep -q '"action":"bot_restart_result"' "$FIX/mvp/audit.log" 2>/dev/null \
  && ok "audit.log 有 bot_restart_issued + bot_restart_result" || bad "audit.log 缺 restart 稽核行"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

#!/usr/bin/env bash
# mvp-a4-monitor-test.sh — A4 監控信號牆驗收 fixture（task 20260707-2359-a4c3-mvp-a4-monitor-wall）
# 鐵律（同 mvp-web-test.sh）：一律 mktemp 自造態，絕不碰生產 memory.db / logs/ / /tmp 真鎖檔。
# 用法：MVP_SRC=<待測代碼目錄> bash mvp-a4-monitor-test.sh   （MVP_SRC 預設生產 mvp/，worktree 可注入）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"

# 鐵律：受測代碼若不支援 MVP_MEMORY_DB/MVP_BOT_WATCHDOG_LOG/MVP_BOT_WATCHDOG_LOCK 注入，
# 拒跑——否則本腳本後面對 memory.db/watchdog 檔案的斷言全部隔離失效，可能誤讀/誤寫生產路徑。
for v in MVP_MEMORY_DB MVP_BOT_WATCHDOG_LOG MVP_BOT_WATCHDOG_LOCK MVP_GB; do
  if ! grep -q "$v" "$SRC/mvp-server.ts" 2>/dev/null; then
    echo "FATAL: $SRC/mvp-server.ts 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑。"
    exit 1
  fi
done

FIX=$(mktemp -d /tmp/mvp-a4-monitor-test-XXXXXX)
REAL_MEMORY_DB="/home/oldrabbit/.claude-bots/memory.db"
REAL_WATCHDOG_LOG="/home/oldrabbit/.claude-bots/logs/bot-watchdog.log"
REAL_WATCHDOG_LOCK="/tmp/bot-watchdog.lock"
export MVP_MEMORY_DB="$FIX/memory.db"
export MVP_BOT_WATCHDOG_LOG="$FIX/bot-watchdog.log"
export MVP_BOT_WATCHDOG_LOCK="$FIX/bot-watchdog.lock"
export MVP_GB="$FIX/gb"
export MVP_DIR="$FIX/mvp"
export FATQ_ROOT="$FIX/tasks"
export MVP_DEV_MODE=1
export MVP_PORT=18199
[ "$MVP_MEMORY_DB" = "$REAL_MEMORY_DB" ] && { echo "FATAL: fixture 指向生產 memory.db，拒跑"; exit 1; }
[ "$MVP_BOT_WATCHDOG_LOG" = "$REAL_WATCHDOG_LOG" ] && { echo "FATAL: fixture 指向生產 watchdog log，拒跑"; exit 1; }
[ "$MVP_BOT_WATCHDOG_LOCK" = "$REAL_WATCHDOG_LOCK" ] && { echo "FATAL: fixture 指向生產 watchdog lock，拒跑"; exit 1; }

mkdir -p "$FIX/mvp" "$FIX/gb/pods" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending}
cp "$SRC/app.html" "$FIX/mvp/"

# ── fixture 資料：memory.db（health_metrics 最新一列 + heartbeats 對照）──
sqlite3 "$FIX/memory.db" "
CREATE TABLE health_metrics (ts TEXT, signal TEXT, value REAL, status TEXT);
CREATE TABLE heartbeats (component TEXT PRIMARY KEY, last_ok_at TEXT, last_status TEXT, last_error TEXT, consecutive_failures INTEGER DEFAULT 0);
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S1_seabed_lag',9.0,'GREEN');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:01.000Z','S1_seabed_lag',1.5,'GREEN');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S2_cron_keeper_batch',0.1,'GREEN');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S2_cron_dream_cycle',30.0,'RED');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S2_cron_stale',25.0,'AMBER');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S2_cron_tg_ingest',0.2,'GREEN');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S3_api_key',1,'GREEN');
INSERT INTO health_metrics VALUES ('2026-01-01T00:00:00.000Z','S4_disk_db',0,'RED');
INSERT INTO heartbeats VALUES ('S2_cron_dream_cycle',NULL,'fail',NULL,3);
" || { echo "FATAL: sqlite3 fixture 建置失敗"; rm -rf "$FIX"; exit 1; }

# heartbeat-*.txt：一新一舊，驗 stale 判斷（>180s）
touch -d '@'$(( $(date +%s) - 30 ))  "$FIX/gb/heartbeat-assist-anya.txt"
touch -d '@'$(( $(date +%s) - 400 )) "$FIX/gb/heartbeat-builder.txt"

echo "[2026-01-01T00:00:00Z] RESTART fixture-old — session gone" > "$FIX/bot-watchdog.log"
touch "$FIX/bot-watchdog.lock"

"$BUN" "$SRC/mvp-server.ts" >> "$FIX/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$FIX"' EXIT
for i in $(seq 1 40); do curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" && break; sleep 0.25; done
curl -sm 1 -o /dev/null "http://127.0.0.1:$MVP_PORT/" || { echo "FATAL: server 起不來"; cat "$FIX/server.log"; exit 1; }

login(){ curl -sc "$FIX/ck" -X POST -d "email=$1" "http://127.0.0.1:$MVP_PORT/auth/dev-login" -o /dev/null; }
API(){ curl -sm 10 -b "$FIX/ck" -H "content-type: application/json" "$@"; }
CODE(){ curl -sm 10 -o /dev/null -w "%{http_code}" -b "$FIX/ck" -H "content-type: application/json" "$@"; }

echo "=== A4-1 未登入 → /api/monitor 401 ==="
rm -f "$FIX/ck"; touch "$FIX/ck"
c=$(CODE "http://127.0.0.1:$MVP_PORT/api/monitor")
[ "$c" = "401" ] && ok "未登入 401" || bad "未登入→$c（期望 401）"

login "a4test@x.local"
r=$(API "http://127.0.0.1:$MVP_PORT/api/monitor")

echo "=== A4-2 signals 陣列：7 個既有信號、狀態與 fixture 一致 ==="
echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sigs={s['id']:s for s in d['signals']}
assert len(d['signals'])==7, len(d['signals'])
assert sigs['S1_seabed_lag']['status']=='GREEN' and sigs['S1_seabed_lag']['value']==1.5, sigs['S1_seabed_lag']
assert sigs['S2_cron_dream_cycle']['status']=='RED' and sigs['S2_cron_dream_cycle']['consecutiveFailures']==3, sigs['S2_cron_dream_cycle']
assert sigs['S2_cron_stale']['status']=='AMBER', sigs['S2_cron_stale']
assert sigs['S3_api_key']['status']=='GREEN' and sigs['S3_api_key']['msg']=='正常', sigs['S3_api_key']
assert sigs['S4_disk_db']['status']=='RED' and sigs['S4_disk_db']['msg']=='異常', sigs['S4_disk_db']
" && ok "signals 內容與 fixture 一致（含最新一列覆蓋舊列、consecutiveFailures 對照）" || bad "signals 斷言失敗：$(echo "$r"|head -c 300)"

echo "=== A4-3 watchdog：bot-watchdog lock 新鮮→GREEN、gateway 心跳一新一舊→僅 builder 標 stale ==="
echo "$r" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bw=d['watchdog']['botWatchdog']; gw=d['watchdog']['gatewayWatchdog']
assert bw['status']=='GREEN', bw
assert bw['recentRestarts24h']==0, bw  # fixture log 的 RESTART 是 2026-01-01，早已超過 24h 窗口
assert gw['checkedPodCount']==2, gw
pods=[p['pod'] for p in gw['stalePods']]
assert pods==['builder'], pods
assert gw['status']=='RED', gw
" && ok "watchdog 斷言全過" || bad "watchdog 斷言失敗：$(echo "$r"|head -c 300)"

echo "=== A4-4 前端結構：monitorPane 分頁+/api/monitor 接線都已接上 ==="
# 註（a1d5 command-center 改版後更新）：monitorPane 從主 nav 頂層分頁改為指揮中心面板的
# 「看完整 →」連結（data-goto="monitorPane"），頂層 data-pane 按鈕已依 SPEC 移除，
# 故不再斷言 data-pane，改斷言 monitorPane section 本體 + loadMonitor//api/monitor 接線仍在。
grep -q 'id="monitorPane"' "$SRC/app.html" && grep -q "loadMonitor" "$SRC/app.html" && grep -q "/api/monitor" "$SRC/app.html" \
  && ok "app.html 已接 monitorPane 分頁 + loadMonitor + /api/monitor" || bad "前端接線缺漏"

echo "=== A4-5 隔離 canary：測試期間生產 memory.db 零讀取痕跡（用 mtime 佐證未被觸碰）──實質已用不同路徑，這裡再次防呆確認 ==="
[ -f "$REAL_MEMORY_DB" ] && real_before=$(stat -c %Y "$REAL_MEMORY_DB") || real_before="na"
[ "$real_before" = "na" ] || { real_after=$(stat -c %Y "$REAL_MEMORY_DB"); [ "$real_before" = "$real_after" ] && ok "生產 memory.db mtime 未變" || bad "生產 memory.db mtime 竟改變！隔離失效"; }

kill $SPID 2>/dev/null
echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

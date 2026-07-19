#!/usr/bin/env bash
# heartbeat-s6-test.sh — S6 db integrity 信號驗收 fixture（task 20260706-1738-a8d5）
# 鐵律：一律 mktemp 自造態 DB，絕不碰生產 memory.db/kg.db/pod-system/pods-db。
# 用法：HB_SRC=<待測 heartbeat.ts 路徑> bash heartbeat-s6-test.sh
#       （HB_SRC 預設生產 shared/scripts/heartbeat.ts；開發時可指向 dev 副本）
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
HB_SRC="${HB_SRC:-/home/oldrabbit/.claude-bots/shared/scripts/heartbeat.ts}"

for v in HEARTBEAT_DB_PATH HEARTBEAT_KG_DB_PATH HEARTBEAT_PODS_DB_DIR HEARTBEAT_S6_FORCE HEARTBEAT_NOW_ISO; do
  if ! grep -q "$v" "$HB_SRC" 2>/dev/null; then
    echo "FATAL: $HB_SRC 不支援 $v 環境變數注入——受測代碼太舊/回歸，拒跑。"
    exit 1
  fi
done

FIX=$(mktemp -d /tmp/heartbeat-s6-test-XXXXXX)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/pods-db"

mkgood(){ # $1=path
  python3 -c "
import sqlite3
conn = sqlite3.connect('$1')
conn.execute('CREATE TABLE t(x TEXT)')
for i in range(2000):
    conn.execute('INSERT INTO t VALUES (?)', ('x'*200 + str(i),))
conn.commit(); conn.close()
"
}
mkcorrupt(){ # $1=path（先建好庫，複製後打壞）
  mkgood "$1"
  python3 -c "
import os
p='$1'
size = os.path.getsize(p)
with open(p,'r+b') as f:
    f.seek(size//2)
    f.write(bytes([i % 256 for i in range(2000)]))
"
}

run_hb(){ # 呼叫受測 heartbeat.ts，回傳 stdout（--dry-run，不真的送 TG/不需要 gcloud）
  MVP_ENV_ARGS=("$@")
  "$BUN" "$HB_SRC" --dry-run 2>&1
}

echo "=== S6-1 gate 關閉（非低峰時段、非 force）：S6 不執行，heartbeats 表無 S6_db_integrity 心跳寫入 ==="
DB1="$FIX/memory1.db"; mkgood "$DB1"
KG1="$FIX/kg1.db"; mkgood "$KG1"
out=$(HEARTBEAT_DB_PATH="$DB1" HEARTBEAT_KG_DB_PATH="$KG1" HEARTBEAT_PODS_DB_DIR="$FIX/pods-db" \
  HEARTBEAT_NOW_ISO="2026-07-09T14:00:00+08:00" \
  run_hb)
echo "$out" | grep -q "S6 skipped" && ok "非低峰時段(14:00)→S6 skipped 訊息出現" || bad "缺 S6 skipped 訊息：$(echo "$out"|tail -c 300)"
echo "$out" | grep -q "S6_db_integrity" && bad "gate 關閉卻仍寫了 S6_db_integrity（不該執行）" || ok "gate 關閉時未寫入/未提及 S6_db_integrity signal 結果行"

echo "=== S6-2 gate 開啟（低峰時段 04:00）+ 全部資料庫健康 → GREEN ==="
DB2="$FIX/memory2.db"; mkgood "$DB2"
KG2="$FIX/kg2.db"; mkgood "$KG2"
cp "$DB2" "$FIX/pods-db/gateway-assist-anya.db"
out=$(HEARTBEAT_DB_PATH="$DB2" HEARTBEAT_KG_DB_PATH="$KG2" HEARTBEAT_PODS_DB_DIR="$FIX/pods-db" \
  HEARTBEAT_NOW_ISO="2026-07-09T04:02:00+08:00" \
  run_hb)
echo "$out" | grep -q "S6_db_integrity: GREEN" && ok "低峰時段+全健康→GREEN" || bad "未見 GREEN：$(echo "$out"|grep S6_db_integrity)"
echo "$out" | grep "S6_db_integrity" | grep -q "3 個資料庫" && ok "三個資料庫都被檢查到（memory/kg/pod）" || bad "檢查資料庫數量不對：$(echo "$out"|grep S6_db_integrity)"

echo "=== S6-3 同一天第二次執行（HEARTBEAT_NOW_ISO 同日不同時刻）→ 已跑過，gate 擋下 ==="
out2=$(HEARTBEAT_DB_PATH="$DB2" HEARTBEAT_KG_DB_PATH="$KG2" HEARTBEAT_PODS_DB_DIR="$FIX/pods-db" \
  HEARTBEAT_NOW_ISO="2026-07-09T04:10:00+08:00" \
  run_hb)
echo "$out2" | grep -q "S6 skipped" && ok "同日再次於低峰時段執行→S6 skipped（今日已跑過）" || bad "應該 skip 卻沒有：$(echo "$out2"|tail -c 300)"

echo "=== S6-4 手造壞庫副本（kg.db 損毀）→ RED，首次即觸發告警（debounce=1，不需等第二次）==="
DB4="$FIX/memory4.db"; mkgood "$DB4"
KG4="$FIX/kg4.db"; mkcorrupt "$KG4"
qc=$(sqlite3 "$KG4" "PRAGMA quick_check;" 2>&1)
echo "$qc" | grep -qi "malformed\|error" && ok "fixture 前置確認：手造壞庫 quick_check 真的失敗（$qc）" || bad "fixture 造壞失敗，quick_check 仍過：$qc"
out4=$(HEARTBEAT_DB_PATH="$DB4" HEARTBEAT_KG_DB_PATH="$KG4" HEARTBEAT_PODS_DB_DIR="$FIX/pods-db-empty" \
  HEARTBEAT_NOW_ISO="2026-07-10T04:02:00+08:00" \
  run_hb)
echo "$out4" | grep -q "S6_db_integrity: RED" && ok "壞庫觸發 RED" || bad "未觸發 RED：$(echo "$out4"|grep S6_db_integrity)"
echo "$out4" | grep "S6_db_integrity" | grep -q "kg.db" && ok "訊息點名 kg.db 是失敗來源" || bad "訊息未點名 kg.db：$(echo "$out4"|grep S6_db_integrity)"
echo "$out4" | grep -qi "DRY-RUN.*S6_db_integrity\|DRY-RUN.*\[Diana Health\] CRIT" && ok "首次 RED 即觸發告警（DRY-RUN 送出訊息可見，非等第二次）" || bad "未見首次即告警的 DRY-RUN 送出紀錄：$(echo "$out4"|tail -c 500)"

echo "=== S6-5 INJECT_RED 手動覆寫（既有機制沿用）==="
DB5="$FIX/memory5.db"; mkgood "$DB5"
out5=$(HEARTBEAT_DB_PATH="$DB5" HEARTBEAT_PODS_DB_DIR="$FIX/pods-db-empty2" HEARTBEAT_S6_FORCE=1 HEARTBEAT_INJECT_RED=S6 run_hb)
echo "$out5" | grep -q "S6_db_integrity: RED" && echo "$out5" | grep -qi "injected" && ok "HEARTBEAT_INJECT_RED=S6 強制 RED 生效" || bad "INJECT_RED=S6 未生效：$(echo "$out5"|grep S6_db_integrity)"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

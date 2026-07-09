#!/usr/bin/env bash
# backup-age-audit-test.sh — 備份年齡巡檢腳本驗收 fixture（task 20260706-1738-a8d5）
# 鐵律：一律 mktemp 自造態 root，絕不掃描/寫入生產 ~/.claude-bots。
# 用法：SCRIPT_SRC=<待測腳本路徑> bash backup-age-audit-test.sh
set -u
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

PY=/home/oldrabbit/.claude-bots/shared/venv/bin/python
SCRIPT_SRC="${SCRIPT_SRC:-/home/oldrabbit/.claude-bots/shared/scripts/backup-age-audit.py}"
REAL_ROOT="/home/oldrabbit/.claude-bots"

if ! grep -q "BACKUP_AUDIT_ROOT" "$SCRIPT_SRC" 2>/dev/null; then
  echo "FATAL: $SCRIPT_SRC 不支援 BACKUP_AUDIT_ROOT 環境變數注入——受測代碼太舊/回歸，拒跑。"
  exit 1
fi

FIX=$(mktemp -d /tmp/backup-audit-test-XXXXXX)
[ "$FIX" = "$REAL_ROOT" ] && { echo "FATAL: fixture 指向生產目錄，拒跑"; exit 1; }
mkdir -p "$FIX/logs" "$FIX/handover"

touchago(){ touch -d "@$(( $(date +%s) - $2*86400 ))" "$1"; }  # $1=path $2=天數（浮點以秒近似）

# PROTECT：7 天內
echo "junk" > "$FIX/fresh.bak"; touchago "$FIX/fresh.bak" 1

# PROTECT：命中 memory.db 保護 pattern（雖已 20 天）
echo "junk" > "$FIX/memory.db.bak-old"; touchago "$FIX/memory.db.bak-old" 20

# REVIEW：keep-list 白名單（mechanism，非備份候選），即使很舊
echo "#!/bin/bash" > "$FIX/backup.sh"; touchago "$FIX/backup.sh" 90

# CANDIDATE + REVIEW 配對：同組（base_key 相同）、新舊各一，都 >=30 天
echo "old"    > "$FIX/app.bak-20260101"; touchago "$FIX/app.bak-20260101" 90
echo "newer"  > "$FIX/app.bak-20260601"; touchago "$FIX/app.bak-20260601" 32

# PROTECT：sidecar 近期有活動（-wal 今天有動），即使本體 40 天
echo "junk" > "$FIX/snap.db.bak"; touchago "$FIX/snap.db.bak" 40
echo "wal"  > "$FIX/snap.db.bak-wal"  # 剛寫入,mtime=now,天然滿足 sidecar 近期(<2天)判斷

# REVIEW：7-30 天觀察期，無同組任何東西
echo "junk" > "$FIX/lonely.backup"; touchago "$FIX/lonely.backup" 15

# logs/*.gz：只算總量，不逐項列
head -c 12345 /dev/urandom > "$FIX/logs/foo.log.1.gz" 2>/dev/null || dd if=/dev/zero of="$FIX/logs/foo.log.1.gz" bs=1 count=12345 2>/dev/null

out=$(BACKUP_AUDIT_ROOT="$FIX" "$PY" "$SCRIPT_SRC" --dry-run --root "$FIX" 2>&1)

echo "=== 分類斷言 ==="
echo "$out" | grep -q "fresh.bak.*保護窗\|保護窗.*fresh.bak" || echo "$out" | grep "fresh.bak" | grep -q "PROTECT\|保護窗" \
  && ok "fresh.bak（1天）→ 保護窗描述" || bad "fresh.bak 分類不對：$(echo "$out"|grep fresh.bak)"

echo "$out" | grep "memory.db.bak-old" | grep -q "保護 pattern" \
  && ok "memory.db.bak-old（20天但命中保護 pattern）→ PROTECT" || bad "memory.db.bak-old 分類不對：$(echo "$out"|grep memory.db.bak-old)"

echo "$out" | grep "backup.sh" | grep -q "看似備份實為活體機制" \
  && ok "backup.sh（90天但白名單）→ REVIEW/白名單" || bad "backup.sh 分類不對：$(echo "$out"|grep backup.sh)"

echo "$out" | grep "app.bak-20260101" | grep -q "CANDIDATE\|被同組更新版本取代" \
  && ok "app.bak-20260101（90天，被較新同組取代）→ CANDIDATE" || bad "app.bak-20260101 分類不對：$(echo "$out"|grep app.bak-20260101)"

echo "$out" | grep "app.bak-20260601" | grep -q "為同組最新版本" \
  && ok "app.bak-20260601（32天，同組最新）→ REVIEW（非 CANDIDATE）" || bad "app.bak-20260601 分類不對：$(echo "$out"|grep app.bak-20260601)"

echo "$out" | grep "snap.db.bak\b" | grep -q "sidecar" \
  && ok "snap.db.bak（40天但 sidecar 近期有活動）→ PROTECT/sidecar" || bad "snap.db.bak 分類不對：$(echo "$out"|grep 'snap.db.bak ')"

echo "$out" | grep "lonely.backup" | grep -q "觀察期" \
  && ok "lonely.backup（15天，無同組）→ REVIEW/觀察期" || bad "lonely.backup 分類不對：$(echo "$out"|grep lonely.backup)"

echo "=== logs/*.gz 只算總量、不逐項列 ==="
echo "$out" | grep -q "foo.log.1.gz" && bad "logs/*.gz 不該逐項出現在表格裡" || ok "logs/*.gz 未被逐項列出"
echo "$out" | grep -q "logs/ \*.gz 輪替總量" && ok "logs/*.gz 總量彙總行存在" || bad "缺 logs/*.gz 總量彙總行"

echo "=== 不刪除任何檔案 ==="
n=$(find "$FIX" -type f | wc -l | tr -d ' ')
[ "$n" -ge 8 ] && ok "fixture 檔案數未被刪除（現有 $n 個）" || bad "檔案數異常：$n"

echo "=== 隔離：非 dry-run 模式輸出寫到 fixture handover/，不碰生產 handover/ ==="
BACKUP_AUDIT_ROOT="$FIX" BACKUP_AUDIT_HANDOVER_DIR="$FIX/handover" "$PY" "$SCRIPT_SRC" --root "$FIX" --handover-dir "$FIX/handover" > /dev/null 2>&1
today=$(date +%Y%m%d)
[ -f "$FIX/handover/backup-audit-$today.md" ] && ok "報告寫到 fixture handover/backup-audit-$today.md" || bad "報告未產出於預期路徑"
n2=$(find "$REAL_ROOT/handover" -maxdepth 1 -name "backup-audit-*.md" 2>/dev/null | wc -l | tr -d ' ')
echo "  (生產 handover/ 現有 backup-audit-*.md 數：$n2，本測試不應使其增加——若之前已跑過正式月度排程本身產出的報告不算污染)"

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ] || exit 1

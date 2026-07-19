#!/usr/bin/env bash
# offsite-backup.sh — 資料層每日異地備份到 GCS（cron 05:10）
# 範圍：memory.db（知識核心）/ users.db / pods-db / tasks/ / kg.db / infra git bundle
# 保留：GCS 上 14 天版本（bucket lifecycle 或檔名日期自然輪替＋清理）
set -euo pipefail
export PATH="/usr/lib/google-cloud-sdk/bin:/usr/local/bin:/usr/bin:/bin"
BUCKET="gs://channellab-pod-backup"
DAY=$(date +%Y%m%d)
TMP=/tmp/pod-backup-$DAY
LOG=/home/oldrabbit/.claude-bots/logs/offsite-backup.log
log(){ echo "[$(date -u '+%FT%TZ')] $*" >> "$LOG"; }

mkdir -p "$TMP"
cd /home/oldrabbit/.claude-bots

# sqlite 一律用 .backup 熱備（不鎖生產、一致性快照）
SQL3=/home/oldrabbit/bin/sqlite3-346
for db in memory.db mvp/users.db kg.db; do
  name=$(basename "$db")
  [ -f "$db" ] && "$SQL3" "$db" ".backup '$TMP/$name'" 2>>"$LOG" || log "skip $db"
done
for db in pod-system/pods-db/*.db; do
  [ -f "$db" ] && "$SQL3" "$db" ".backup '$TMP/pod-$(basename "$db")'" 2>>"$LOG"
done
# 任務狀態機（檔案樹）
tar czf "$TMP/tasks.tgz" tasks/ 2>>"$LOG"
# infra 配置 git bundle
git -C infra bundle create "$TMP/infra.bundle" --all 2>>"$LOG" || log "infra bundle skip"

# 上傳
if gcloud storage cp -r "$TMP" "$BUCKET/$DAY/" >>"$LOG" 2>&1; then
  log "OK: uploaded $(du -sh "$TMP" | cut -f1) → $BUCKET/$DAY/"
else
  log "UPLOAD FAILED"
  ET=$(gcloud secrets versions access latest --secret=tg-token-eric --project=channellab-prod 2>/dev/null)
  [ -n "$ET" ] && curl -sf -X POST "https://api.telegram.org/bot${ET}/sendMessage" \
    -d chat_id=1050312492 --data-urlencode "text=[offsite-backup] 🔴 每日異地備份上傳失敗，請查 logs/offsite-backup.log" >/dev/null
fi
rm -rf "$TMP"

# 清 14 天前的遠端版本
OLD=$(date -d "14 days ago" +%Y%m%d 2>/dev/null || date -v-14d +%Y%m%d)
gcloud storage rm -r "$BUCKET/$OLD/" >/dev/null 2>&1 || true

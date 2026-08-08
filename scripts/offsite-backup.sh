#!/usr/bin/env bash
# offsite-backup.sh — 資料層每日異地備份到 GCS（cron 05:10）
# 範圍：memory.db（知識核心）/ users.db / pods-db / tasks/ / kg.db / infra git bundle
# 保留：GCS 上 14 天版本（bucket lifecycle 或檔名日期自然輪替＋清理）
set -euo pipefail
export PATH="/usr/lib/google-cloud-sdk/bin:/usr/local/bin:/usr/bin:/bin"
ROOT="${BACKUP_ROOT:-/home/oldrabbit/.claude-bots}"
BUCKET="${BACKUP_BUCKET:-gs://channellab-pod-backup}"
DAY="${BACKUP_DAY:-$(date +%Y%m%d)}"
TMP_ROOT="${BACKUP_TMP_ROOT:-/tmp}"
TMP="$TMP_ROOT/pod-backup-$DAY"
LOG="${BACKUP_LOG:-$ROOT/logs/offsite-backup.log}"
SQL3="${SQLITE3_BIN:-/home/oldrabbit/bin/sqlite3-346}"
TAR_BIN="${TAR_BIN:-tar}"
GIT_BIN="${GIT_BIN:-git}"
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
CURL_BIN="${CURL_BIN:-curl}"
ALERT_CHAT_ID="${BACKUP_ALERT_CHAT_ID:-1050312492}"
log(){ echo "[$(date -u '+%FT%TZ')] $*" >> "$LOG"; }

STAGE="startup"
notify_failure() {
  local token
  if ! token=$(timeout 10 "$GCLOUD_BIN" secrets versions access latest --secret=tg-token-eric --project=channellab-prod 2>/dev/null); then
    log "ALERT FAILED: unable to read Telegram token" || true
    return
  fi
  if [[ -z "$token" ]] || ! "$CURL_BIN" -sf --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=$ALERT_CHAT_ID" \
    --data-urlencode "text=[offsite-backup] 🔴 每日異地備份失敗（stage=$STAGE），請查 logs/offsite-backup.log" >/dev/null; then
    log "ALERT FAILED: Telegram delivery failed" || true
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  # The cleanup path must continue even if alert transport itself fails.
  set +e
  if [[ "$status" -ne 0 ]]; then
    log "FAILED: stage=$STAGE exit=$status" || true
    notify_failure
  fi
  case "$TMP" in
    "$TMP_ROOT"/pod-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) rm -rf -- "$TMP" ;;
    *) log "CLEANUP REFUSED: unexpected temporary path $TMP" || true ;;
  esac
  exit "$status"
}
trap on_exit EXIT

mkdir -p "$TMP"
cd "$ROOT"

# sqlite 一律用 .backup 熱備（不鎖生產、一致性快照）
for db in memory.db mvp/users.db kg.db; do
  name=$(basename "$db")
  if [ -f "$db" ]; then
    STAGE="sqlite backup: $db"
    "$SQL3" "$db" ".backup '$TMP/$name'" 2>>"$LOG"
  fi
done
for db in pod-system/pods-db/*.db; do
  if [ -f "$db" ]; then
    STAGE="sqlite backup: $db"
    "$SQL3" "$db" ".backup '$TMP/pod-$(basename "$db")'" 2>>"$LOG"
  fi
done
# 任務狀態機（檔案樹）
STAGE="tar tasks"
if "$TAR_BIN" czf "$TMP/tasks.tgz" tasks/ 2>>"$LOG"; then
  :
else
  tar_status=$?
  if [[ "$tar_status" -eq 1 ]]; then
    log "WARN: tasks changed while tar was reading; archive retained"
  else
    exit "$tar_status"
  fi
fi
# infra 配置 git bundle
STAGE="infra bundle"
"$GIT_BIN" -C infra bundle create "$TMP/infra.bundle" --all 2>>"$LOG"

# 上傳
STAGE="upload"
"$GCLOUD_BIN" storage cp -r "$TMP" "$BUCKET/$DAY/" >>"$LOG" 2>&1
STAGE="upload verification"
if ! uploaded=$("$GCLOUD_BIN" storage ls "$BUCKET/$DAY/**" 2>>"$LOG") || [[ -z "$uploaded" ]]; then
  exit 1
fi
log "OK: uploaded $(du -sh "$TMP" | cut -f1) → $BUCKET/$DAY/"

# 清 14 天前的遠端版本
OLD=$(date -d "14 days ago" +%Y%m%d 2>/dev/null || date -v-14d +%Y%m%d)
"$GCLOUD_BIN" storage rm -r "$BUCKET/$OLD/" >/dev/null 2>&1 || true

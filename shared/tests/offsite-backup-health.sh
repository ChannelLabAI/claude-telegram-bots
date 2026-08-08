#!/usr/bin/env bash
# offsite-backup-health.sh — 14-day GCS backup completeness monitor.
set -euo pipefail

BUCKET="${BACKUP_BUCKET:-gs://channellab-pod-backup}"
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
LOG="${BACKUP_HEALTH_LOG:-/home/oldrabbit/.claude-bots/logs/offsite-backup-health.log}"
ALERT_CHAT_ID="${BACKUP_ALERT_CHAT_ID:-1050312492}"
DAY="${BACKUP_HEALTH_DAY:-$(date +%Y%m%d)}"
CURL_BIN="${CURL_BIN:-curl}"

log(){ echo "[$(date -u '+%FT%TZ')] $*" >> "$LOG"; }
alert() {
  local missing="$1" token
  if ! token=$(timeout 10 "$GCLOUD_BIN" secrets versions access latest --secret=tg-token-eric --project=channellab-prod 2>/dev/null); then
    log "ALERT FAILED: unable to read Telegram token" || true
    return
  fi
  if [[ -z "$token" ]] || ! "$CURL_BIN" -sf --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=$ALERT_CHAT_ID" \
    --data-urlencode "text=[offsite-backup-health] 🔴 GCS 備份缺漏：$missing" >/dev/null; then
    log "ALERT FAILED: Telegram delivery failed" || true
  fi
}

missing=()
for offset in {0..13}; do
  date_for_check=$(date -d "$DAY - $offset days" +%Y%m%d 2>/dev/null || date -j -v-"$offset"d -f %Y%m%d "$DAY" +%Y%m%d)
  if ! objects=$("$GCLOUD_BIN" storage ls "$BUCKET/$date_for_check/**" 2>/dev/null) || [[ -z "$objects" ]]; then
    missing+=("$date_for_check")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  list=$(IFS=,; echo "${missing[*]}")
  log "MISSING: $list"
  alert "$list"
  exit 1
fi

log "OK: 14-day GCS backup coverage complete"

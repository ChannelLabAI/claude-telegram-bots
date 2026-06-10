#!/usr/bin/env bash
set -euo pipefail
BUN_PATH="/home/oldrabbit/.bun/bin"
GCLOUD_PATH="/usr/lib/google-cloud-sdk/bin"
SCRIPT="/home/oldrabbit/.claude-bots/shared/scripts/heartbeat.ts"
LOG="/home/oldrabbit/.claude-bots/logs/heartbeat-p0.log"
CRON_CMD="*/5 * * * * PATH=$BUN_PATH:$GCLOUD_PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bun run $SCRIPT >> $LOG 2>&1"
(crontab -l 2>/dev/null | grep -v "heartbeat.ts"; echo "$CRON_CMD") | crontab -
echo "[install-heartbeat-cron] Installed."

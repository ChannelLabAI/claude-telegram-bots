#!/usr/bin/env bash
# pubsub-bridge-watchdog.sh — Cron watchdog for channellab-pubsub-bridge.
# Restarts the service if heartbeat.txt has not been updated in STALE_SECONDS.
# Add to crontab: */10 * * * * /home/oldrabbit/.claude-bots/shared/bin/pubsub-bridge-watchdog.sh

set -euo pipefail

HEARTBEAT_FILE="${HEARTBEAT_FILE:-/home/oldrabbit/.claude-bots/state/pubsub-bridge-heartbeat.txt}"
STALE_SECONDS="${STALE_SECONDS:-900}"   # 15 minutes; cron runs every 10 min
SERVICE="channellab-pubsub-bridge"
LOG="/home/oldrabbit/.claude-bots/logs/pubsub-bridge-watchdog.log"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG" >&2; }

if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  log "WARN: heartbeat file missing → restarting $SERVICE"
  systemctl restart "$SERVICE"
  exit 0
fi

MTIME=$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || stat -f %m "$HEARTBEAT_FILE" 2>/dev/null)
NOW=$(date +%s)
AGE=$((NOW - MTIME))

if [[ $AGE -gt $STALE_SECONDS ]]; then
  log "WARN: heartbeat stale (${AGE}s > ${STALE_SECONDS}s) → restarting $SERVICE"
  systemctl restart "$SERVICE"
else
  log "OK: heartbeat age ${AGE}s"
fi

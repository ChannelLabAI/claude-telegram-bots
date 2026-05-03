#!/usr/bin/env bash
# install-cron.sh — Install Diana nightly trigger cron (23:00 CST = 15:00 UTC)
set -euo pipefail

KEEPER_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/.claude-bots/logs/diana-trigger.log"
CRON_CMD="0 15 * * * cd $KEEPER_DIR && bun run trigger-batch.ts >> $LOG 2>&1"

# Remove any existing keeper entry, then add the new one
(crontab -l 2>/dev/null | grep -v "trigger-batch\|keeper-batch"; echo "$CRON_CMD") | crontab -
echo "[install-cron] Installed: $CRON_CMD"
echo "[install-cron] Verify with: crontab -l | grep diana"

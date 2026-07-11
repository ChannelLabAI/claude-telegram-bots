#!/usr/bin/env bash
# Install roster consistency patrol as a durable system crontab entry.
set -euo pipefail

ROOT="${ROSTER_PATROL_ROOT:-/home/oldrabbit/.claude-bots}"
SCRIPT="$ROOT/shared/loops/roster-patrol/roster-patrol.sh"
LOG="$ROOT/logs/roster-patrol/cron.log"
CRON_PATH="/home/oldrabbit/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CRON_CMD="10 9 * * * PATH=$CRON_PATH /usr/bin/flock -n /tmp/cron-roster-patrol.lock bash $SCRIPT >> $LOG 2>&1"

if [[ ! -x "$SCRIPT" ]]; then
  echo "[install-cron] missing executable: $SCRIPT" >&2
  exit 1
fi

(crontab -l 2>/dev/null | grep -v 'shared/loops/roster-patrol/roster-patrol.sh'; echo "$CRON_CMD") | crontab -
echo "[install-cron] Installed durable system crontab entry:"
echo "$CRON_CMD"
echo "[install-cron] Survives reboots because it is installed in the user crontab, not a process-local scheduler."

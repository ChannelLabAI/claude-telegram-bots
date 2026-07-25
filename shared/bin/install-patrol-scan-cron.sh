#!/usr/bin/env bash
# Install patrol-scan as a durable user-crontab entry.  Use this or the timer,
# not both.
set -euo pipefail
ROOT="${PATROL_ROOT:-/home/oldrabbit/.claude-bots}"
SCRIPT="$ROOT/shared/bin/patrol-scan.sh"
LOG="$ROOT/logs/patrol-scan-cron.log"
PATH_VALUE="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LINE="*/15 * * * * PATH=$PATH_VALUE /usr/bin/flock -n /tmp/cron-patrol-scan.lock bash $SCRIPT >> $LOG 2>&1 # patrol-scan every 15m"
[[ -x "$SCRIPT" ]] || { echo "[install-cron] missing executable: $SCRIPT" >&2; exit 1; }
(crontab -l 2>/dev/null | grep -v 'shared/bin/patrol-scan.sh'; echo "$LINE") | crontab -
echo "[install-cron] installed: $LINE"

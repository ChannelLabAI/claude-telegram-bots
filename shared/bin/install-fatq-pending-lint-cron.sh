#!/usr/bin/env bash
set -euo pipefail

ROOT="${FATQ_REPO_ROOT:-/home/oldrabbit/.claude-bots}"
SCRIPT="$ROOT/shared/bin/fatq-pending-lint.sh"
LOG="$ROOT/logs/fatq-pending-lint.log"
CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CRON_CMD="*/2 * * * * PATH=$CRON_PATH /usr/bin/flock -n /tmp/cron-fatq-pending-lint.lock bash $SCRIPT >> $LOG 2>&1"

[[ -x "$SCRIPT" ]] || { echo "[install-fatq-pending-lint-cron] missing executable: $SCRIPT" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"
(crontab -l 2>/dev/null | grep -v 'shared/bin/fatq-pending-lint.sh'; echo "$CRON_CMD") | crontab -
echo "[install-fatq-pending-lint-cron] installed: $CRON_CMD"

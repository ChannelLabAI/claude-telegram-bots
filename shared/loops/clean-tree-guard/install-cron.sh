#!/usr/bin/env bash
# Install the durable host-side 30-minute clean-tree guard cron entry.
set -euo pipefail

ROOT="${CLEAN_TREE_GUARD_ROOT:-/home/oldrabbit/.claude-bots}"
SCRIPT="$ROOT/shared/loops/clean-tree-guard/clean-tree-guard.sh"
LOG="$ROOT/logs/clean-tree-guard/cron.log"
CRON_PATH="/home/oldrabbit/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CRON_CMD="*/30 * * * * PATH=$CRON_PATH /usr/bin/flock -n /tmp/cron-clean-tree-guard.lock bash $SCRIPT >> $LOG 2>&1"

[[ -x "$SCRIPT" ]] || { echo "missing executable: $SCRIPT" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"
(crontab -l 2>/dev/null | grep -v 'shared/loops/clean-tree-guard/clean-tree-guard.sh'; echo "$CRON_CMD") | crontab -
echo "Installed: $CRON_CMD"

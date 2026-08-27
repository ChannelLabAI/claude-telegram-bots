#!/usr/bin/env bash
# Install the observable hourly FATQ fallback round. The wrapper owns flock so
# a rejected lock acquisition can be logged instead of disappearing in cron.
set -euo pipefail

CRONTAB_BIN="${CRONTAB_BIN:-/usr/bin/crontab}"
CRON_SCRIPT="${FATQ_DISPATCH_CRON_SCRIPT:-/home/oldrabbit/.claude-bots/shared/bin/fatq-dispatch-cron.sh}"
CRON_LOG="${FATQ_DISPATCH_CRON_LOG:-/home/oldrabbit/.claude-bots/logs/fatq-dispatch.log}"
marker="# managed: fatq-dispatch-hourly-fallback"
entry="7 * * * * /usr/bin/nice -n 15 /usr/bin/ionice -c2 -n7 bash $CRON_SCRIPT >> $CRON_LOG 2>&1 $marker"

current="$($CRONTAB_BIN -l 2>/dev/null || true)"
filtered="$(printf '%s\n' "$current" | sed \
  -e '/cron-fatq-dispatch\.lock.*fatq-dispatch-cron\.sh/d' \
  -e '/fatq-dispatch-cron\.sh.*fatq-dispatch\.log/d' \
  -e '/# managed: fatq-dispatch-hourly-fallback/d')"
{
  printf '%s\n' "$filtered" | sed '/^[[:space:]]*$/d'
  printf '%s\n' "$entry"
} | "$CRONTAB_BIN" -

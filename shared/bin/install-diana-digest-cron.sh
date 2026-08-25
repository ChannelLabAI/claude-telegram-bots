#!/usr/bin/env bash
# Maintainer-only installer. Run after reviewer approval; never from a builder worktree.
set -euo pipefail
ROOT="${DIANA_DIGEST_ROOT:-/home/oldrabbit/.claude-bots}"
SCRIPT="$ROOT/shared/bin/diana-digest.sh"
LOG="$ROOT/logs/diana-digest.log"
CRON_PATH="/usr/local/bin:/usr/bin:/bin"
MAJOR="*/5 * * * * PATH=$CRON_PATH /usr/bin/flock -n /tmp/cron-diana-digest-major.lock $SCRIPT --major-only >> $LOG 2>&1 # diana-digest-major"
DAILY="35 9 * * * PATH=$CRON_PATH /usr/bin/flock -n /tmp/cron-diana-digest-daily.lock $SCRIPT --daily >> $LOG 2>&1 # diana-digest-daily"
[[ -x "$SCRIPT" ]] || { echo "[install-diana-digest-cron] missing executable: $SCRIPT" >&2; exit 1; }
current="$(crontab -l 2>/dev/null || true)"
{ printf '%s\n' "$current" | grep -v 'diana-digest' || true; printf '%s\n%s\n' "$MAJOR" "$DAILY"; } | crontab -
echo "[install-diana-digest-cron] installed major fast lane and daily safety net"

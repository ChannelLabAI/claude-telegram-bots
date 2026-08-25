#!/usr/bin/env bash
set -euo pipefail

[[ "$(id -un)" == "oldrabbit" ]] || { echo "kb-guard cron must be installed by oldrabbit" >&2; exit 1; }
ROOT="/home/oldrabbit/.claude-bots"
RUNTIME_PATH="/home/oldrabbit/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LINE="35 18 * * * PATH=$RUNTIME_PATH $ROOT/shared/bin/kb-guard.sh daily >> $ROOT/logs/kb-guard.log 2>&1 # kb-guard daily K2-K3"
CURRENT="$(crontab -l 2>/dev/null || true)"
FILTERED="$(printf '%s\n' "$CURRENT" | grep -v '# kb-guard daily K2-K3$' || true)"
{ printf '%s\n' "$FILTERED"; printf '%s\n' "$LINE"; } | sed '/^[[:space:]]*$/d' | crontab -
echo "installed: $LINE"

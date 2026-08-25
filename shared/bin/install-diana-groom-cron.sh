#!/usr/bin/env bash
# Maintainer-only, idempotent installer for the independent 09:20 safety net.
set -euo pipefail

crontab_bin="${CRONTAB_BIN:-crontab}"
entry='20 9 * * * /home/oldrabbit/.claude-bots/shared/bin/diana-groom.sh sweep >> /home/oldrabbit/.claude-bots/logs/diana-groom.log 2>&1 # diana-groom'
current="$($crontab_bin -l 2>/dev/null || true)"
filtered="$(printf '%s\n' "$current" | sed '/# diana-groom$/d')"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  printf '%s\n' "$filtered" | sed '/^[[:space:]]*$/d'
  printf '%s\n' "$entry"
} > "$tmp"
$crontab_bin "$tmp"

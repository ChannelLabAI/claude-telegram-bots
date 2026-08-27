#!/usr/bin/env bash
# Maintainer-only, idempotent installer for Anya's durable evening journal cron.
set -euo pipefail

root="${EVENING_JOURNAL_ROOT:-/home/oldrabbit/.claude-bots}"
crontab_bin="${CRONTAB_BIN:-/usr/bin/crontab}"
script="$root/shared/bin/evening-journal-all.sh"
log="$root/logs/evening-journal-all.log"
marker="# evening-journal-all"
cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
entry="3 18 * * * PATH=$cron_path /usr/bin/flock -n /tmp/cron-evening-journal-all.lock /usr/bin/bash $script >> $log 2>&1 $marker"

[[ -x "$script" ]] || { echo "missing executable: $script" >&2; exit 1; }
[[ -x "$crontab_bin" ]] || { echo "missing executable crontab command: $crontab_bin" >&2; exit 1; }
mkdir -p "$root/logs"

current="$(mktemp)"
next="$(mktemp)"
read_error="$(mktemp)"
trap 'rm -f "$current" "$next" "$read_error"' EXIT

if "$crontab_bin" -l > "$current" 2> "$read_error"; then
  :
elif grep -Eqi '^no crontab for ' "$read_error"; then
  : > "$current"
else
  echo "unable to read existing crontab; refusing to replace it" >&2
  sed -n '1,10p' "$read_error" >&2
  exit 1
fi

grep -Fv "evening-journal-all" "$current" > "$next" || true
printf '%s\n' "$entry" >> "$next"
"$crontab_bin" "$next"

count="$("$crontab_bin" -l 2>/dev/null | grep -Fc "$marker" || true)"
[[ "$count" == "1" ]] || { echo "cron install verification failed: marker count=$count" >&2; exit 1; }
echo "Installed: $entry"
echo "Activation is complete only after $log contains a scheduler-written run."

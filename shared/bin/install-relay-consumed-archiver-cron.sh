#!/usr/bin/env bash
# Maintainer-only, idempotent installer for the relay consumed archiver cron.
set -euo pipefail

root="${RELAY_ARCHIVER_ROOT:-/home/oldrabbit/.claude-bots}"
crontab_bin="${CRONTAB_BIN:-crontab}"
script="$root/shared/bin/relay-consumed-archiver.sh"
log="$root/logs/relay-consumed-archiver.log"
marker="# relay-consumed-archiver"
cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
entry="*/10 * * * * PATH=$cron_path /usr/bin/flock -n /tmp/cron-relay-consumed-archiver.lock bash $script >> $log 2>&1 $marker"

[[ -x "$script" ]] || { echo "missing executable: $script" >&2; exit 1; }
command -v "$crontab_bin" >/dev/null 2>&1 || { echo "missing crontab command: $crontab_bin" >&2; exit 1; }
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
grep -Fv "$marker" "$current" > "$next" || true
printf '%s\n' "$entry" >> "$next"
"$crontab_bin" "$next"

count="$("$crontab_bin" -l 2>/dev/null | grep -Fc "$marker" || true)"
[[ "$count" == "1" ]] || { echo "cron install verification failed: marker count=$count" >&2; exit 1; }
echo "Installed: $entry"
echo "Activation is complete only after $log contains a scheduler-written run."

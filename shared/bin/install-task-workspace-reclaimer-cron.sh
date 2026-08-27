#!/usr/bin/env bash
# Maintainer-only, idempotent installer for the durable workspace-reclaimer cron.
set -euo pipefail

root="${TASK_WORKSPACE_RECLAIMER_ROOT:-/home/oldrabbit/.claude-bots}"
crontab_bin="${CRONTAB_BIN:-crontab}"
script="$root/shared/bin/task-workspace-reclaimer.py"
json_log="$root/logs/task-workspace-reclaimer.jsonl"
cron_log="$root/logs/task-workspace-reclaimer-cron.log"
marker="# task-workspace-reclaimer"
cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
entry="55 4 * * * PATH=$cron_path /usr/bin/flock -n /tmp/cron-task-workspace-reclaimer.lock /usr/bin/nice -n 15 /usr/bin/ionice -c2 -n7 /usr/bin/python3 $script --root $root --apply --log-file $json_log >> $cron_log 2>&1 $marker"

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
echo "Retention: no time-based TTL; only terminal tasks whose content is confirmed safe are reclaimed."
echo "Activation is complete only after $cron_log contains a scheduler-written run."

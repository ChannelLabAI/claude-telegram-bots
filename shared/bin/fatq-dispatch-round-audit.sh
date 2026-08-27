#!/usr/bin/env bash
# Audit :07-to-:07 fallback windows. A full cron scan or a full event-driven
# scan covers the window; only the absence of both is a gap.
set -euo pipefail

HOURS=24
NOW=""
CRON_LOG="${FATQ_DISPATCH_CRON_LOG:-/home/oldrabbit/.claude-bots/logs/fatq-dispatch.log}"
WATCH_LOG="${FATQ_WATCH_DISPATCH_LOG:-/home/oldrabbit/.claude-bots/logs/fatq-watch-dispatch.log}"

usage() {
  echo "usage: $0 [--hours N] [--now ISO] [--cron-log PATH] [--watch-log PATH]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="${2:-}"; shift 2 ;;
    --now) NOW="${2:-}"; shift 2 ;;
    --cron-log) CRON_LOG="${2:-}"; shift 2 ;;
    --watch-log) WATCH_LOG="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$HOURS" =~ ^[1-9][0-9]*$ ]] || usage

now_epoch="$(date -d "${NOW:-now}" +%s)" || usage
hour_start="$(TZ=Asia/Taipei date -d "@$now_epoch" '+%Y-%m-%d %H:07:00 +08:00')"
latest_epoch="$(date -d "$hour_start" +%s)"
if (( now_epoch < latest_epoch )); then latest_epoch=$((latest_epoch - 3600)); fi

read_logs() {
  local base="$1" f
  [[ -f "$base" ]] && grep -E 'scan start \(dry_run=|scan done:|dispatch-round source=cron-fallback outcome=dispatcher-exit-zero' "$base" || true
  for f in "$base".[1-9].gz; do
    [[ -f "$f" ]] && gzip -cd -- "$f" | grep -E 'scan start \(dry_run=|scan done:|dispatch-round source=cron-fallback outcome=dispatcher-exit-zero' || true
  done
}

first_epoch=$((latest_epoch - (HOURS - 1) * 3600))
{
  read_logs "$CRON_LOG" | sed 's/^/cron|/'
  read_logs "$WATCH_LOG" | sed 's/^/watch|/'
} | TZ=Asia/Taipei awk -v first="$first_epoch" -v hours="$HOURS" '
  function event_window(line, stamp, parts, minute, second, epoch) {
    stamp = substr(line, 2, 19)
    if (length(stamp) != 19) return -1
    if (split(stamp, parts, /[-T:]/) != 6) return -1
    epoch = mktime(parts[1] " " parts[2] " " parts[3] " " parts[4] " " parts[5] " " parts[6])
    minute = parts[5] + 0
    second = parts[6] + 0
    if (minute >= 7) return epoch - (minute * 60 + second - 420)
    return epoch - (minute * 60 + second + 3180)
  }
  {
    separator = index($0, "|")
    source = substr($0, 1, separator - 1)
    line = substr($0, separator + 1)
    anchor = event_window(line)
    if (anchor < first || anchor >= first + hours * 3600) next
    slot = int((anchor - first) / 3600)
    if (source == "cron") {
      if (index(line, "outcome=dispatcher-exit-zero")) cron_heartbeat[slot] = 1
      if (index(line, "scan start (dry_run=")) cron_start[slot] = 1
      if (index(line, "scan done:")) cron_done[slot] = 1
    } else {
      if (index(line, "scan start (dry_run=")) watch_start[slot] = 1
      if (index(line, "scan done:")) watch_done[slot] = 1
    }
  }
  END {
    gaps = 0
    for (i = 0; i < hours; i++) {
      window = strftime("%Y-%m-%dT%H:07:00+08:00", first + i * 3600)
      if (cron_heartbeat[i] || (cron_start[i] && cron_done[i]))
        print "COVERED window=" window " source=cron-fallback"
      else if (watch_start[i] && watch_done[i])
        print "COVERED window=" window " source=event-watch"
      else {
        print "GAP window=" window " cron=absent event=absent"
        gaps++
      }
    }
    print "SUMMARY hours=" hours " gaps=" gaps
    exit(gaps > 0)
  }
'

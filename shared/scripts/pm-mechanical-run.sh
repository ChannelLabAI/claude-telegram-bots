#!/usr/bin/env bash
# Run one pm-hub cron command and atomically publish its exit/freshness status.
set -uo pipefail

job="${1:-}"
[[ "$job" =~ ^(pipeline|render|reconcile)$ ]] || {
  echo "usage: $0 pipeline|render|reconcile -- command [args...]" >&2
  exit 2
}
shift
[[ "${1:-}" == "--" ]] || {
  echo "usage: $0 pipeline|render|reconcile -- command [args...]" >&2
  exit 2
}
shift
[[ $# -gt 0 ]] || {
  echo "pm-mechanical-run: command is required" >&2
  exit 2
}

state_dir="${PM_MECHANICAL_STATE_DIR:-/home/oldrabbit/.claude-bots/state/pm-mechanical}"
mkdir -p "$state_dir"
started_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

set +e
"$@"
rc=$?
set -e

finished_epoch="$(date +%s)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp "$state_dir/.${job}.status.XXXXXX")"
printf '{"schema":"pm-mechanical-status-v1","job":"%s","started_at":"%s","started_epoch":%s,"finished_at":"%s","finished_epoch":%s,"exit_code":%s}\n' \
  "$job" "$started_at" "$started_epoch" "$finished_at" "$finished_epoch" "$rc" > "$tmp"
mv -f "$tmp" "$state_dir/$job.json"
exit "$rc"

#!/usr/bin/env bash
# Report dispatch/nudge events that occurred after a task entered cancelled/.

set -uo pipefail

usage() {
  echo "usage: $0 [--hours N] [positive-hours] [tasks-root]" >&2
  exit 2
}

hours=""
root=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)
      [[ $# -ge 2 ]] || usage
      hours="$2"
      shift 2
      ;;
    --hours=*)
      hours="${1#--hours=}"
      shift
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    --*) usage ;;
    *) positional+=("$1"); shift ;;
  esac
done

(( ${#positional[@]} <= 2 )) || usage
[[ -z "$hours" || ${#positional[@]} -le 1 ]] || usage
if [[ -z "$hours" && ${#positional[@]} -gt 0 ]]; then
  hours="${positional[0]}"
  positional=("${positional[@]:1}")
fi
hours="${hours:-24}"
root="${positional[0]:-${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}}"
now_epoch="${VOID_AUDIT_NOW_EPOCH:-$(date +%s)}"

[[ "$hours" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$now_epoch" =~ ^[0-9]+$ ]] || { echo "VOID_AUDIT_NOW_EPOCH must be an epoch" >&2; exit 2; }
[[ -d "$root/cancelled" ]] || { echo "cancelled directory not found: $root/cancelled" >&2; exit 2; }

cutoff=$((now_epoch - hours * 3600))
dispatch_total=0
nudge_total=0
task_total=0

printf 'window_hours=%s now_epoch=%s cutoff_epoch=%s root=%s\n' "$hours" "$now_epoch" "$cutoff" "$root"
printf 'task_id\taction\tts\trelay_file\n'

while IFS= read -r task_file; do
  task_id="$(jq -r '.task_id // .id // "<unknown>"' "$task_file" 2>/dev/null)" || continue
  void_ts="$(jq -r '[.history[]? | select((.action == "cancel" or .action == "force_mv") and .to == "cancelled/") | .ts] | last // empty' "$task_file" 2>/dev/null)"
  [[ -n "$void_ts" ]] || continue
  void_epoch="$(date -d "$void_ts" +%s 2>/dev/null)" || continue
  task_hits=0
  while IFS=$'\t' read -r action event_ts relay_file; do
    [[ -n "$action" && -n "$event_ts" ]] || continue
    event_epoch="$(date -d "$event_ts" +%s 2>/dev/null)" || continue
    (( event_epoch >= cutoff && event_epoch >= void_epoch )) || continue
    printf '%s\t%s\t%s\t%s\n' "$task_id" "$action" "$event_ts" "$relay_file"
    task_hits=$((task_hits + 1))
    case "$action" in
      dispatch) dispatch_total=$((dispatch_total + 1)) ;;
      nudge) nudge_total=$((nudge_total + 1)) ;;
    esac
  done < <(jq -r '.history[]? | select(.action == "dispatch" or .action == "nudge") | [.action, .ts, (.relay_file // "-")] | @tsv' "$task_file" 2>/dev/null)
  (( task_hits > 0 )) && task_total=$((task_total + 1))
done < <(find "$root/cancelled" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | sort)

printf 'TOTAL affected_tasks=%s dispatch=%s nudge=%s events=%s\n' \
  "$task_total" "$dispatch_total" "$nudge_total" "$((dispatch_total + nudge_total))"

(( dispatch_total == 0 && nudge_total == 0 ))

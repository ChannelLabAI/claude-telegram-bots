#!/usr/bin/env bash
# Read-only disk-reclaim inventory for FATQ 20260806-1908-02cc.
# Prints Markdown to stdout; it never writes, deletes, moves, or changes metadata.
set -euo pipefail

ROOT="${DISK_INVENTORY_ROOT:-/home/oldrabbit/.claude-bots}"
TMP_ROOT="${DISK_INVENTORY_TMP_ROOT:-/tmp}"
MIN_MIB="${DISK_INVENTORY_MIN_MIB:-16}"
TASKS_ROOT="$ROOT/tasks"

[[ "$MIN_MIB" =~ ^[0-9]+$ ]] || { echo "DISK_INVENTORY_MIN_MIB must be an integer" >&2; exit 2; }
command -v du >/dev/null; command -v find >/dev/null; command -v jq >/dev/null; command -v stat >/dev/null

declare -A TASK_STATE=()
declare -A TASK_DONE_AT=()
declare -A TASK_SHORT=()
# A single jq process keeps a full inventory fast enough to be routinely rerun.
while IFS=$'\t' read -r task_id task_state task_done_at; do
  [[ -n "$task_id" ]] || continue
  TASK_STATE["$task_id"]="$task_state"
  TASK_DONE_AT["$task_id"]="$task_done_at"
  if [[ "$task_id" =~ ^[0-9]{8}-[0-9]{4,6}-([0-9a-f]{4})- ]]; then
    short="${BASH_REMATCH[1]}"
    if [[ -z "${TASK_SHORT[$short]:-}" ]]; then TASK_SHORT["$short"]="$task_id"; else TASK_SHORT["$short"]="AMBIGUOUS"; fi
  fi
done < <(find "$TASKS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.json' -print0 2>/dev/null | xargs -0 -r jq -r '[.task_id // "", .status // "", .completed_at // .review.completed_at // .updated_at // ([.history[]? | select(type == "object") | select(.to == "done/") | .ts] | last) // ""] | @tsv')

task_for_path() {
  local path="$1" id short
  for id in "${!TASK_STATE[@]}"; do [[ "$path" == *"$id"* ]] && { printf '%s' "$id"; return; }; done
  if [[ "$(basename "$path")" =~ (^|[-_.])([0-9a-f]{4})([-_.]|$) ]]; then
    short="${BASH_REMATCH[2]}"
    [[ "${TASK_SHORT[$short]:-}" != "" && "${TASK_SHORT[$short]}" != AMBIGUOUS ]] && { printf '%s' "${TASK_SHORT[$short]}"; return; }
  fi
  printf 'unknown'
}

classify() {
  local path="$1" task="$2" mtime_epoch="$3" mtime="$4" state="${TASK_STATE[$task]:-unknown}" done_at="${TASK_DONE_AT[$task]:-}" done_epoch
  if [[ "$path" == "$TMP_ROOT/pod-backup-20260803" ]]; then
    printf '不確定|最大項目；需先確認是否唯一備份及是否有異地/其他副本，未核實前不得回收'; return
  fi
  if [[ "$state" == pending || "$state" == in_progress || "$state" == review ]]; then
    printf '需保留|對應 FATQ 任務仍為 %s，避免誤殺工作區' "$state"; return
  fi
  if [[ "$state" == done && -n "$done_at" ]]; then
    done_epoch="$(date -d "$done_at" +%s 2>/dev/null || printf 0)"
    if (( done_epoch > 0 && mtime_epoch <= done_epoch )) && [[ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" == "$path" ]]; then
      printf '可回收|對應任務已 done；工作區 mtime (%s) 不晚於完成時間 (%s)，且為 Git 工作樹；仍需 anya 核可後另案移除' "$mtime" "$done_at"; return
    fi
    printf '不確定|任務已 done，但無法同時證實 Git 工作樹及 mtime (%s) 不晚於完成時間 (%s)' "$mtime" "$done_at"; return
  fi
  printf '不確定|無法以路徑唯一對應已完成任務；不得以名稱或年齡單獨判定可回收'
}

emit_header() {
  printf '# Disk reclaim inventory (read-only)\n\n'
  printf 'Generated (UTC): %s  \\n' "$(date -u +%FT%TZ)"
  printf 'Threshold: directories >= %s MiB; targets: /tmp, tasks/work, tasks/worktrees, tasks/assets.  \\n\n' "$MIN_MIB"
  printf '|Category|Path|Size MiB|Last modified (UTC)|FATQ task / state|Decision|Basis|\n|---|---|---:|---|---|---|---|\n'
}

emit_root() {
  local category="$1" root="$2" path kib mib epoch mtime task state decision basis encoded
  [[ -d "$root" ]] || return 0
  # One recursive scan per root, rather than one full scan for every child.
  # Read `du` output only; the inventory does not create a cache or log.
  while IFS=$'\t' read -r kib path; do
    [[ "$path" != "$root" && -d "$path" && "$kib" =~ ^[0-9]+$ ]] || continue
    mib=$(( (kib + 1023) / 1024 )); (( mib >= MIN_MIB )) || continue
    epoch="$(stat -c %Y -- "$path")"; mtime="$(date -u -d "@$epoch" +%FT%TZ)"
    task="$(task_for_path "$path")"; state="${TASK_STATE[$task]:-unknown}"
    encoded="$(classify "$path" "$task" "$epoch" "$mtime")"; decision="${encoded%%|*}"; basis="${encoded#*|}"
    printf '|%s|`%s`|%s|%s|%s / %s|%s|%s|\n' "$category" "$path" "$mib" "$mtime" "$task" "$state" "$decision" "$basis"
  done < <(du -k --max-depth=1 -- "$root" 2>/dev/null)
}

emit_header
emit_root '/tmp' "$TMP_ROOT"
emit_root 'tasks/work' "$TASKS_ROOT/work"
emit_root 'tasks/worktrees' "$TASKS_ROOT/worktrees"
emit_root 'tasks/assets' "$TASKS_ROOT/assets"

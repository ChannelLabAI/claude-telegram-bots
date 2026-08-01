#!/usr/bin/env bash
# Conservative /tmp clone reaper. Defaults to reporting only; --apply is explicit.
set -euo pipefail

TMP_ROOT="${CLONE_TTL_ROOT:-/tmp}"
TTL_HOURS="${CLONE_TTL_HOURS:-24}"
LOG_FILE="${CLONE_TTL_LOG_FILE:-/home/oldrabbit/.claude-bots/logs/clone-ttl-cleaner.jsonl}"
NAME_REGEX="${CLONE_TTL_NAME_REGEX:-(^|[-_.])(clone|freshclone|review|verify|repro|build)([-_.]|$)}"
TASKS_ROOT="${CLONE_TTL_TASKS_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
SAFETY_HELPER="${CLONE_TTL_SAFETY_HELPER:-$(cd "$(dirname "$0")" && pwd)/clone-reclaim-safety.py}"
APPLY=0
FORCE_DIRTY=0

# Exact protected paths and an entry-local marker are defense in depth. The
# /tmp-only root gate below remains the primary boundary and is not bypassed.
NEVER_TOUCH=(
  "/home/oldrabbit/.claude-bots"
  "/home/oldrabbit/.claude-bots/pod-system"
  "/home/oldrabbit/.claude-bots/mvp"
)

usage() { echo "Usage: $0 [--dry-run|--apply] [--force-dirty] [--root DIR] [--ttl-hours N] [--log-file PATH]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --dry-run) APPLY=0 ;;
    --apply) APPLY=1 ;;
    # Kept for invocation compatibility. It no longer bypasses content safety.
    --force-dirty) FORCE_DIRTY=1 ;;
    --root) TMP_ROOT="${2:-}"; shift ;;
    --ttl-hours) TTL_HOURS="${2:-}"; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift ;;
    *) usage ;;
  esac
  shift
done
TMP_ROOT="$(readlink -f "$TMP_ROOT" 2>/dev/null || true)"
[[ "$TMP_ROOT" == /tmp || "$TMP_ROOT" == /tmp/* || "${CLONE_TTL_ALLOW_NON_TMP:-}" == 1 ]] || { echo "refusing root outside /tmp: $TMP_ROOT" >&2; exit 2; }
[[ "$TTL_HOURS" =~ ^[0-9]+$ ]] || { echo "TTL must be non-negative hours" >&2; exit 2; }
command -v jq >/dev/null; command -v readlink >/dev/null; command -v python3 >/dev/null
[[ -x "$SAFETY_HELPER" ]] || { echo "missing safety helper: $SAFETY_HELPER" >&2; exit 2; }
mkdir -p "$(dirname "$LOG_FILE")"
now="$(date +%s)"; cutoff=$((now - TTL_HOURS * 3600)); candidates=0; eligible=0; removed=0; skipped_active=0; needs_review=0; estimated_kb=0

held_by_process() {
  local target="$1" pid ref resolved proc
  for proc in /proc/[0-9]*; do
    [[ -d "$proc" ]] || continue; pid="${proc##*/}"
    for ref in "$proc/cwd" "$proc/fd"/*; do
      [[ -e "$ref" || -L "$ref" ]] || continue
      resolved="$(readlink -f "$ref" 2>/dev/null || true)"
      [[ -n "$resolved" ]] || continue
      if [[ "$resolved" == "$target" || "$resolved" == "$target"/* ]]; then
        printf '%s' "$pid"; return 0
      fi
    done
  done
  return 1
}

emit() {
  local action="$1" path="$2" reason="$3" size_kb="$4" pid="${5:-}" evidence="${6:-null}"
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg action "$action" --arg path "$path" --arg reason "$reason" \
    --argjson size_kb "$size_kb" --arg pid "$pid" --argjson evidence "$evidence" \
    '{ts:$ts,action:$action,path:$path,reason:$reason,size_kb:$size_kb,pid:(if $pid=="" then null else $pid end),evidence:$evidence}' | tee -a "$LOG_FILE"
}

never_touch() {
  local entry="$1" protected
  [[ -e "$entry/.clone-ttl-never-touch" ]] && return 0
  for protected in "${NEVER_TOUCH[@]}"; do
    [[ "$entry" == "$(readlink -f "$protected" 2>/dev/null || true)" ]] && return 0
  done
  return 1
}

discover_repos() {
  local entry="$1" marker
  if git -C "$entry" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\0' "$entry"
  fi
  while IFS= read -r -d '' marker; do
    printf '%s\0' "${marker%/.git}"
  done < <(find "$entry" -mindepth 2 -maxdepth 6 \( -type f -o -type d \) -name .git -print0 2>/dev/null)
}

has_external_files() {
  local entry="$1" file repo covered
  shift; local -a repos=("$@")
  for repo in "${repos[@]}"; do
    [[ "$repo" == "$entry" ]] && return 1
  done
  while IFS= read -r -d '' file; do
    covered=0
    for repo in "${repos[@]}"; do
      if [[ "$file" == "$repo" || "$file" == "$repo"/* ]]; then covered=1; break; fi
    done
    ((covered)) || return 0
  done < <(find "$entry" \( -type f -o -type l \) -print0 2>/dev/null)
  return 1
}

active_task_for() {
  local entry="$1" task_file task_id short slug haystack repo branch
  shift; local -a repos=("$@")
  [[ -d "$TASKS_ROOT" ]] || { printf '%s' task_state_root_missing; return 0; }
  haystack="$entry"
  for repo in "${repos[@]}"; do
    branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    haystack+=" $repo $branch"
  done
  while IFS= read -r -d '' task_file; do
    task_id="$(jq -r '.task_id // empty' "$task_file")"
    slug="$(jq -r '.slug // empty' "$task_file")"
    [[ -n "$task_id" ]] || continue
    short="$(sed -E 's/^[0-9]{8}-[0-9]{4,6}-([0-9a-f]{4})-.*/\1/' <<<"$task_id")"
    if [[ "$haystack" == *"$task_id"* ]] || [[ -n "$slug" && ${#slug} -ge 8 && "$haystack" == *"$slug"* ]] ||
       [[ "$short" =~ ^[0-9a-f]{4}$ && "$haystack" =~ (^|[-_./[:space:]])$short([-_./[:space:]]|$) ]]; then
      printf '%s' "$task_id"; return 0
    fi
  done < <(find "$TASKS_ROOT/pending" "$TASKS_ROOT/in_progress" "$TASKS_ROOT/review" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
  return 1
}

classify_repos() {
  local repo evidence reason all='[]'
  shift; local -a repos=("$@")
  for repo in "${repos[@]}"; do
    if ! evidence="$($SAFETY_HELPER "$repo")"; then
      reason="$(jq -r '.reason // "inspection_error"' <<<"$evidence" 2>/dev/null || echo inspection_error)"
      jq -cn --arg reason "$reason" --argjson repos "$all" --argjson last "${evidence:-null}" \
        '{eligible:false,reason:$reason,repos:($repos+[$last])}'
      return 1
    fi
    all="$(jq -cn --argjson repos "$all" --argjson item "$evidence" '$repos+[$item]')"
  done
  jq -cn --argjson repos "$all" --argjson force_dirty "$FORCE_DIRTY" \
    '{eligible:true,reason:"content_confirmed",force_dirty_ignored:($force_dirty==1),repos:$repos}'
}

remove_repo() {
  local repo="$1" git_dir common_dir
  git_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-dir)"
  common_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
  if [[ "$git_dir" != "$common_dir" ]]; then
    git --git-dir="$common_dir" worktree remove --force "$repo"
    printf '%s' git_worktree_remove
  else
    rm -rf -- "$repo"
    printf '%s' standalone_clone_remove
  fi
}

while IFS= read -r -d '' entry; do
  candidates=$((candidates + 1)); base="$(basename "$entry")"
  [[ "$base" =~ $NAME_REGEX ]] || continue
  mtime="$(stat -c %Y "$entry")"; ((mtime <= cutoff)) || continue
  size_kb="$(du -sk "$entry" 2>/dev/null | awk '{print $1}' || echo 0)"
  if never_touch "$entry"; then
    needs_review=$((needs_review + 1)); emit needs_review "$entry" never_touch "$size_kb"; continue
  fi
  mapfile -d '' -t repos < <(discover_repos "$entry")
  ((${#repos[@]})) || continue
  if pid="$(held_by_process "$entry")"; then
    skipped_active=$((skipped_active + 1)); emit skipped_active "$entry" cwd_or_fd_held "$size_kb" "$pid"; continue
  fi
  if task_id="$(active_task_for "$entry" "${repos[@]}")"; then
    skipped_active=$((skipped_active + 1))
    emit skipped_active "$entry" "active_fatq_task:$task_id" "$size_kb"; continue
  fi
  if has_external_files "$entry" "${repos[@]}"; then
    needs_review=$((needs_review + 1)); emit needs_review "$entry" non_git_files_outside_clone "$size_kb"; continue
  fi
  if ! evidence="$(classify_repos _ "${repos[@]}")"; then
    needs_review=$((needs_review + 1))
    reason="$(jq -r '.reason // "inspection_error"' <<<"$evidence")"
    emit needs_review "$entry" "$reason" "$size_kb" "" "$evidence"; continue
  fi
  eligible=$((eligible + 1)); estimated_kb=$((estimated_kb + size_kb))
  if ((APPLY)); then
    methods=()
    # Removing an outer repo removes nested repos too, so only act on roots
    # that are not descendants of another discovered repo.
    for repo in "${repos[@]}"; do
      nested=0
      for parent in "${repos[@]}"; do
        [[ "$repo" != "$parent" && "$repo" == "$parent"/* ]] && { nested=1; break; }
      done
      ((nested)) && continue
      methods+=("$(remove_repo "$repo")")
    done
    [[ ! -d "$entry" ]] || rmdir "$entry" 2>/dev/null || true
    if [[ -e "$entry" ]]; then
      needs_review=$((needs_review + 1)); emit needs_review "$entry" post_remove_container_not_empty "$size_kb" "" "$evidence"; continue
    fi
    removed=$((removed + 1)); emit removed "$entry" "$(IFS=,; echo "${methods[*]}")" "$size_kb" "" "$evidence"
  else
    emit would_remove "$entry" content_confirmed "$size_kb" "" "$evidence"
  fi
done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)

jq -cn --arg ts "$(date -u +%FT%TZ)" --arg mode "$([[ $APPLY == 1 ]] && echo apply || echo dry_run)" \
  --argjson candidates "$candidates" --argjson eligible "$eligible" --argjson removed "$removed" --argjson skipped_active "$skipped_active" --argjson needs_review "$needs_review" --argjson estimated_kb "$estimated_kb" \
  '{ts:$ts,mode:$mode,candidates:$candidates,eligible:$eligible,removed:$removed,skipped_active:$skipped_active,needs_review:$needs_review,estimated_reclaim_kb:$estimated_kb}' | tee -a "$LOG_FILE"

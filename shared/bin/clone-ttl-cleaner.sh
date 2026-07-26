#!/usr/bin/env bash
# Conservative /tmp clone reaper.  Defaults to reporting only; --apply is explicit.
set -euo pipefail

TMP_ROOT="${CLONE_TTL_ROOT:-/tmp}"
TTL_HOURS="${CLONE_TTL_HOURS:-24}"
LOG_FILE="${CLONE_TTL_LOG_FILE:-/home/oldrabbit/.claude-bots/logs/clone-ttl-cleaner.jsonl}"
NAME_REGEX="${CLONE_TTL_NAME_REGEX:-(^|[-_.])(clone|freshclone|review|verify|repro|build)([-_.]|$)}"
APPLY=0
FORCE_DIRTY=0

usage() { echo "Usage: $0 [--dry-run|--apply] [--force-dirty] [--root DIR] [--ttl-hours N] [--log-file PATH]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --dry-run) APPLY=0 ;;
    --apply) APPLY=1 ;;
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
command -v jq >/dev/null; command -v readlink >/dev/null
mkdir -p "$(dirname "$LOG_FILE")"
now="$(date +%s)"; cutoff=$((now - TTL_HOURS * 3600)); candidates=0; eligible=0; removed=0; skipped_active=0; needs_review=0; estimated_kb=0

# A process protects a path if its cwd or any open fd is that directory or below it.
held_by_process() {
  local target="$1" pid ref resolved
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
  local action="$1" path="$2" reason="$3" size_kb="$4" pid="${5:-}"
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg action "$action" --arg path "$path" --arg reason "$reason" --argjson size_kb "$size_kb" --arg pid "$pid" \
    '{ts:$ts,action:$action,path:$path,reason:$reason,size_kb:$size_kb,pid:(if $pid=="" then null else $pid end)}' | tee -a "$LOG_FILE"
}

while IFS= read -r -d '' entry; do
  candidates=$((candidates + 1)); base="$(basename "$entry")"
  [[ "$base" =~ $NAME_REGEX ]] || continue
  # A name alone is never enough: the direct /tmp entry must be a Git worktree.
  git -C "$entry" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  mtime="$(stat -c %Y "$entry")"; ((mtime <= cutoff)) || continue
  size_kb="$(du -sk "$entry" 2>/dev/null | awk '{print $1}' || echo 0)"
  if pid="$(held_by_process "$entry")"; then
    skipped_active=$((skipped_active + 1)); emit skipped_active "$entry" "cwd_or_fd_held" "$size_kb" "$pid"; continue
  fi
  # A terminated task can still contain its only uncommitted work.  TTL alone
  # is never authority to discard it; require a human's explicit override.
  if [[ -n "$(git -C "$entry" status --porcelain)" ]] && (( ! FORCE_DIRTY )); then
    needs_review=$((needs_review + 1)); emit needs_review "$entry" "git_dirty" "$size_kb"; continue
  fi
  eligible=$((eligible + 1)); estimated_kb=$((estimated_kb + size_kb))
  if ((APPLY)); then
    rm -rf -- "$entry"; removed=$((removed + 1)); emit removed "$entry" "$([[ $FORCE_DIRTY == 1 ]] && echo ttl_expired_force_dirty || echo ttl_expired)" "$size_kb"
  else
    emit would_remove "$entry" "ttl_expired" "$size_kb"
  fi
done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)

jq -cn --arg ts "$(date -u +%FT%TZ)" --arg mode "$([[ $APPLY == 1 ]] && echo apply || echo dry_run)" \
  --argjson candidates "$candidates" --argjson eligible "$eligible" --argjson removed "$removed" --argjson skipped_active "$skipped_active" --argjson needs_review "$needs_review" --argjson estimated_kb "$estimated_kb" \
  '{ts:$ts,mode:$mode,candidates:$candidates,eligible:$eligible,removed:$removed,skipped_active:$skipped_active,needs_review:$needs_review,estimated_reclaim_kb:$estimated_kb}' | tee -a "$LOG_FILE"

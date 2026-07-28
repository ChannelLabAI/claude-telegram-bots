#!/usr/bin/env bash
# Shared FATQ machine-blocking semantics.
#
# A future not_before written by `fatq-cli.sh hold` is the only machine-readable
# task hold. Free-form comments such as [BLOCKED] remain diagnostic/advisory.

fatq_task_block_until() {
  local task_file="$1"
  jq -r '(.not_before // empty)' "$task_file" 2>/dev/null
}

# Return 0 only when a valid not_before is strictly later than the supplied
# epoch. Missing or malformed values remain fail-open, preserving the existing
# dispatch behavior.
fatq_task_is_blocked() {
  local task_file="$1" now_epoch="$2" not_before not_before_epoch
  not_before="$(fatq_task_block_until "$task_file")"
  [[ -n "$not_before" && "$not_before" != "null" ]] || return 1
  not_before_epoch="$(date -d "$not_before" +%s 2>/dev/null)" || return 1
  [[ "$not_before_epoch" -gt "$now_epoch" ]]
}

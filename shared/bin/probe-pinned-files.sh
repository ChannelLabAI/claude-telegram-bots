#!/usr/bin/env bash
# Report repository files referenced by FATQ verification/proof fields.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASKS_ROOT="${PROBE_PINNED_TASKS_ROOT:-$ROOT_DIR/tasks}"

usage() {
  echo "Usage: probe-pinned-files.sh [shared/path/or-filename]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

if [[ ! -d "$TASKS_ROOT" ]]; then
  echo "probe-pinned-files: tasks root not found: $TASKS_ROOT" >&2
  exit 2
fi

tmp_rows="$(mktemp)"
trap 'rm -f "$tmp_rows"' EXIT

# FATQ state directories are the immediate children of tasks/.  Limiting the
# depth still covers every state (including non-core archived/cancelled dirs)
# without crawling task worktrees, attachments, or scratch repositories that
# happen to contain unrelated JSON files.
find "$TASKS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.json' \
  -exec jq -r '
    def task_id:
      .task_id // .id // (input_filename | split("/")[-1] | sub("[.]json$"; ""));
    def paths:
      .. | strings
      | scan("(?:^|[[:space:]\\\"'"'"'=])(?:/home/oldrabbit/[.]claude-bots/|[.]/)?(shared/(?:bin|tests)/[A-Za-z0-9._/@%+=:,~-]+)")
      | .[0];
    def rows($field; $value):
      task_id as $task_id
      | $value | paths
      | [., $task_id, $field] | @tsv;
    rows("verify_commands"; (.verify_commands // [])),
    rows("live_verify_commands"; (.live_verify_commands // [])),
    rows("closeout.host_effect_proof.commands"; (.closeout.host_effect_proof.commands // []))
  ' {} + >> "$tmp_rows"

sort -u -o "$tmp_rows" "$tmp_rows"

if [[ $# -eq 0 ]]; then
  if [[ ! -s "$tmp_rows" ]]; then
    echo "NO_PINNED_FILES"
    exit 0
  fi
  while IFS=$'\t' read -r path task_id field; do
    printf 'PINNED\t%s\t%s\t%s\n' "$path" "$task_id" "$field"
  done < "$tmp_rows"
  exit 0
fi

query="$1"
query="${query#/home/oldrabbit/.claude-bots/}"
query="${query#./}"
found=0
while IFS=$'\t' read -r path task_id field; do
  if [[ "$path" == "$query" || "${path##*/}" == "$query" ]]; then
    printf 'PINNED\t%s\t%s\t%s\n' "$path" "$task_id" "$field"
    found=1
  fi
done < "$tmp_rows"

if [[ $found -eq 0 ]]; then
  printf 'NOT_PINNED\t%s\n' "$1"
fi

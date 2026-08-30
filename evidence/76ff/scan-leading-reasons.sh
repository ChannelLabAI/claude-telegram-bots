#!/usr/bin/env bash
set -euo pipefail

tasks_root="${1:-/home/oldrabbit/.claude-bots/tasks}"
mapfile -d '' task_files < <(
  find "$tasks_root" -mindepth 2 -maxdepth 2 -type f -name '*.json' -print0
)

total_tasks="$(jq -s '[.[] | select((.task_id // "") != "")] | length' "${task_files[@]}")"
total_closeout="$(jq -s '[.[] | select((.task_id // "") != "" and (.closeout | type) == "object")] | length' "${task_files[@]}")"
match_output="$(jq -r '
  select((.task_id // "") != "" and (.closeout | type) == "object")
  | .task_id as $task_id
  | [
      ["no_host_effect", (.closeout.no_host_effect.reason // null)],
      ["unverified", (.closeout.unverified.reason // null)],
      ["live_verify_opt_out", (.closeout.live_verify_opt_out.reason // null)]
    ][]
  | select((.[1] | type) == "string" and (.[1] | startswith("--")))
  | "MATCH\ttask_id=\($task_id)\tfield=\(.[0])\treason=\(.[1])\tfile=\(input_filename)"
' "${task_files[@]}")"

if [[ -n "$match_output" ]]; then
  printf '%s\n' "$match_output"
  matches="$(printf '%s\n' "$match_output" | wc -l | tr -d ' ')"
else
  matches=0
fi

printf 'TOTAL_JSON_FILES=%s\n' "${#task_files[@]}"
printf 'TOTAL_TASK_JSON=%s\n' "$total_tasks"
printf 'TOTAL_WITH_CLOSEOUT=%s\n' "$total_closeout"
printf 'LEADING_REASON_MATCHES=%s\n' "$matches"

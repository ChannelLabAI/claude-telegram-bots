#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ROOT="${FATQ_TASK_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
CASES="${1:-$HERE/cases.jsonl}"
CUTOFF="2026-08-23T17:13:51+08:00"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-corpus-selection.XXXXXX")"
trap 'rm -r -- "$tmp"' EXIT

# Stratum A: the 28 newest real execution_error rejects available at the
# task-creation cutoff, after excluding cases whose task record is not in a
# core state directory.  This is the non-judgmental bulk sample.
find "$TASK_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do} \
  -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
  | xargs -0 jq -c --arg cutoff "$CUTOFF" '
      select((.created_at // "") <= $cutoff)
      | select(any((.history // [])[]?;
          type == "object" and .action == "verdict_reject" and .issue_type == "execution_error"))
      | [.created_at, .task_id]' \
  | jq -s -r 'sort_by(.[0], .[1]) | reverse | .[:28][][1]' >"$tmp/selected-caught"

jq -r 'select(.id | startswith("C")) | .source.ref' "$CASES" >"$tmp/corpus-caught"
if ! diff -u "$tmp/selected-caught" "$tmp/corpus-caught"; then
  echo "selection mismatch: caught stratum differs from deterministic top 28" >&2
  exit 1
fi

# Strata B/C are mandatory named incidents from the task specification plus
# documented false-block exemplars.  Confirm every referenced FATQ source is a
# real task record; classification remains a reviewer source-content check.
jq -r '.source.ref' "$CASES" | sort -u >"$tmp/refs"
while IFS= read -r ref; do
  matches="$(find "$TASK_ROOT" -mindepth 2 -maxdepth 2 -type f -name "$ref.json" | wc -l | tr -d ' ')"
  if [[ "$matches" -ne 1 ]]; then
    echo "source lookup failed: $ref matched $matches task files" >&2
    exit 1
  fi
done <"$tmp/refs"

echo "selection OK: 28 deterministic caught + 4 mandatory missed + 4 false_block"

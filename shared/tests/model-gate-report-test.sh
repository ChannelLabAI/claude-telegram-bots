#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT="$REPO_ROOT/shared/bin/model-gate-report.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/tasks/done" "$TMP/tasks/rejected" "$TMP/logs"

TASK_SOURCE_ROOT="${MODEL_GATE_FIXTURE_SOURCE_ROOT:-/home/oldrabbit/.claude-bots}"
SOURCE_TASKS=(
  "$TASK_SOURCE_ROOT/tasks/done/20260404-114900-f1a3-task-queue-system.json"
  "$TASK_SOURCE_ROOT/tasks/done/20260408-164230-09bf-clsc-mcp-slug-normalize-bug.json"
  "$TASK_SOURCE_ROOT/tasks/done/20260713-002401-64f4-tiered-review-opus-escalation.json"
  "$TASK_SOURCE_ROOT/tasks/done/20260711-160500-d6f3-replica-final-math-grid.json"
)
for source_task in "${SOURCE_TASKS[@]}"; do
  test -f "$source_task"
done
CLONE_INDEX=0

make_task() {
  local path="$1" status="$2" bot="$3" created="$4" claim="$5" terminal="$6" rejects="$7" issue="${8:-execution_error}"
  local source="${SOURCE_TASKS[$((CLONE_INDEX % ${#SOURCE_TASKS[@]}))]}"
  CLONE_INDEX=$((CLONE_INDEX + 1))
  jq \
    --arg status "$status" \
    --arg bot "$bot" \
    --arg created "$created" \
    --arg claim "$claim" \
    --arg terminal "$terminal" \
    --arg issue "$issue" \
    --argjson rejects "$rejects" \
    '
    def reject_item:
      {
        ts: $claim,
        by: "bella",
        action: "verdict_reject",
        from: "review/",
        to: "rejected/"
      }
      + (if $issue == "MISSING" then {} else {issue_type: $issue} end);
    .status = $status
    | .assigned = $bot
    | .created_at = $created
    | .history = (
        [{ts: $claim, by: $bot, action: "claim", from: "pending/", to: "in_progress/"}]
        + ([range(0; $rejects)] | map(reject_item))
        + [{ts: $terminal, by: "bella", action: "verdict_approve", from: "review/", to: "done/"}]
      )
    ' "$source" > "$path"
}

for i in $(seq -w 1 25); do
  make_task "$TMP/tasks/done/base-$i.json" "wrong-status-rejected" "bella" "2026-06-29T00:00:00+08:00" "2026-06-29T01:00:00+08:00" "2026-06-29T02:00:00+08:00" 0
done

for i in $(seq -w 1 13); do
  make_task "$TMP/tasks/done/treat-warn-a-$i.json" "done" "bella" "2026-07-13T00:00:00+08:00" "2026-07-13T01:00:00+08:00" "2026-07-13T04:00:00+08:00" 1 MISSING
done
for i in $(seq -w 1 12); do
  make_task "$TMP/tasks/done/treat-warn-b-$i.json" "done" "bella" "2026-07-20T00:00:00+08:00" "2026-07-20T01:00:00+08:00" "2026-07-20T02:00:00+08:00" 0
done

jq '.history = "not an array"' "${SOURCE_TASKS[0]}" > "$TMP/tasks/done/legacy-bad.json"
jq '.assigned = "bella" | .created_at = "2026-07-13T00:00:00+08:00" | .status = "done" | .history = ["claimed", "done"]' \
  "${SOURCE_TASKS[1]}" > "$TMP/tasks/done/legacy-string-history.json"

cat > "$TMP/logs/usage.jsonl" <<'JSONL'
{"ts":"2026-06-29T01:30:00+08:00","bot":"bella","session_id":"s1","input_tokens":100,"output_tokens":20,"rate_limit_events":0}
{"ts":"2026-07-13T01:30:00+08:00","bot":"bella","session_id":"s2","input_tokens":300,"output_tokens":80,"rate_limit_events":1}
JSONL

out="$TMP/report-warning.txt"
err="$TMP/report-warning.err"
MODEL_GATE_ROOT="$TMP" bash "$REPORT" --bot bella --baseline-from 2026-06-29 --baseline-to 2026-07-12 --treatment-from 2026-07-13 >"$out" 2>"$err"
grep -q "WARNING(1/2)" "$out"
grep -q "wrong-status-rejected" "$TMP/tasks/done/base-01.json"
! grep -q "WARN" "$err"

small="$TMP/small"
mkdir -p "$small/tasks/done" "$small/tasks/rejected" "$small/logs"
for i in $(seq -w 1 5); do
  make_task "$small/tasks/done/base-$i.json" "done" "bella" "2026-06-29T00:00:00+08:00" "2026-06-29T01:00:00+08:00" "2026-06-29T02:00:00+08:00" 0
  make_task "$small/tasks/done/treat-$i.json" "done" "bella" "2026-07-13T00:00:00+08:00" "2026-07-13T01:00:00+08:00" "2026-07-13T02:00:00+08:00" 0
done
touch "$small/logs/usage.jsonl"
MODEL_GATE_ROOT="$small" bash "$REPORT" --bot bella --baseline-from 2026-06-29 --baseline-to 2026-07-12 --treatment-from 2026-07-13 >"$TMP/report-insufficient.txt"
grep -q "Overall conclusion: INSUFFICIENT_DATA" "$TMP/report-insufficient.txt"

fail="$TMP/fail"
mkdir -p "$fail/tasks/done" "$fail/tasks/rejected" "$fail/logs"
for i in $(seq -w 1 25); do
  make_task "$fail/tasks/done/base-$i.json" "done" "bella" "2026-06-29T00:00:00+08:00" "2026-06-29T01:00:00+08:00" "2026-06-29T02:00:00+08:00" 0
  make_task "$fail/tasks/done/treat-$i.json" "done" "bella" "2026-07-13T00:00:00+08:00" "2026-07-13T01:00:00+08:00" "2026-07-13T04:00:00+08:00" 1 execution_error
done
touch "$fail/logs/usage.jsonl"
MODEL_GATE_ROOT="$fail" bash "$REPORT" --bot bella --baseline-from 2026-06-29 --baseline-to 2026-07-12 --treatment-from 2026-07-13 >"$TMP/report-fail.txt"
grep -q "| R1 | FAIL | TRIGGER | TRIGGER |" "$TMP/report-fail.txt"

echo "model-gate-report tests passed"

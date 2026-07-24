#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/../fatq-pending-lint.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_PENDING_LINT_STATE="$TMPROOT/state.json"
export FATQ_NOW_ISO="2026-07-22T23:00:00+08:00"
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,rejected} "$FATQ_RELAY_DIR"

valid_task() {
  jq -n '{task_id:"valid",slug:"valid",status:"pending",assigned:"anna",reviewer:"bella",
    created_by:"anya",goal:"g",background:"b",context:"c",review_focus:"r",
    deliverables:["d"],acceptance_criteria:["a"],out_of_scope:["o"],
    history:[{ts:"2026-07-22T22:00:00+08:00",by:"anya",via:"fatq-cli",action:"create"}]}'
}

valid_task > "$FATQ_ROOT/pending/valid.json"
valid_task | jq '.task_id="handwritten" | .reviewer="" | .history[0] |= del(.via)' > "$FATQ_ROOT/in_progress/handwritten.json"
bash "$LINT" >/dev/null
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" == "1" ]]
relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | head -1)"
[[ "$(jq -r '.recipient' "$relay")" == "anya" ]]
jq -e '.tasks | length == 1 and .[0].task_id == "handwritten" and (.[] .defects | index("missing_reviewer")) and (.[] .defects | index("missing_fatq_cli_create"))' "$relay" >/dev/null

# Same fingerprint is suppressed.
bash "$LINT" >/dev/null
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" == "1" ]]

# Repair removes active fingerprint; regression rearms it.
valid_task | jq '.task_id="handwritten" | .status="in_progress"' > "$FATQ_ROOT/in_progress/handwritten.json"
bash "$LINT" >/dev/null
[[ "$(jq '.active | length' "$FATQ_PENDING_LINT_STATE")" == "0" ]]
valid_task | jq '.task_id="handwritten" | .status="in_progress" | .history[0] |= del(.via)' > "$FATQ_ROOT/in_progress/handwritten.json"
bash "$LINT" >/dev/null
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" == "2" ]]

# A task whose create/claim provenance is valid but whose submit bypassed the
# CLI must be caught in review, where the old active lint did not scan.
valid_task | jq '
  .task_id="non-cli-submit"
  | .status="review"
  | .history += [
      {ts:"2026-07-22T22:10:00+08:00",by:"anna",via:"fatq-cli",action:"claim"},
      {ts:"2026-07-22T22:20:00+08:00",by:"anna",action:"submit"}
    ]
' > "$FATQ_ROOT/review/non-cli-submit.json"
bash "$LINT" >/dev/null
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" == "3" ]]
submit_relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
jq -e '.tasks | length == 1
  and .[0].task_id == "non-cli-submit"
  and .[0].state == "review"
  and (.[] .defects | index("unsafe_non_cli_submit"))' "$submit_relay" >/dev/null

# The dispatch text is the preventive half of the guard: workers are told to
# enter the stable-lock CLI instead of reproducing the old jq/tmp/mv recipe.
DISPATCH="$SCRIPT_DIR/../fatq-dispatch.sh"
DISCIPLINE="$SCRIPT_DIR/../../blocks/block-codex-builder-delivery-discipline.md"
INSTALLER="$SCRIPT_DIR/../install-fatq-pending-lint-cron.sh"
grep -Fq 'fatq-cli.sh claim ${task_id} --as ${raw_name}' "$DISPATCH"
grep -Fq 'fatq-cli.sh submit ${task_id} --as ${raw_name}' "$DISPATCH"
! grep -Fq '自行 mv pending→in_progress' "$DISPATCH"
! grep -Fq '自行 mv rejected→in_progress' "$DISPATCH"
grep -Fq 'Never hand-write a claim/submit history entry or directly move a task JSON' "$DISCIPLINE"
grep -Fq 'CRON_CMD="*/2 * * * * ' "$INSTALLER"

echo "[fatq-pending-lint-test] PASS"

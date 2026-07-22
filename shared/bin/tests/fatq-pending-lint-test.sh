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
mkdir -p "$FATQ_ROOT"/{pending,in_progress} "$FATQ_RELAY_DIR"

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

echo "[fatq-pending-lint-test] PASS"

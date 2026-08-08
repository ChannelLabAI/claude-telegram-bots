#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH="$ROOT/shared/bin/fatq-dispatch.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_STATE_DIR="$TMPROOT/state"
export FATQ_TEAM_CONFIG="$ROOT/shared/team-config.json"
export FATQ_DISPATCH_AFFINITY="$ROOT/shared/lib/dispatch-affinity.json"
export FATQ_BLOCKING_LIB="$ROOT/shared/lib/fatq-blocking.sh"
export FATQ_NOW_EPOCH="1786190400"
export FATQ_MATTERMOST_DISABLE=1

mkdir -p "$FATQ_ROOT/in_progress" "$FATQ_RELAY_DIR" "$FATQ_STATE_DIR"

make_authority_task() {
  local task_id="$1" created_by_json="$2"
  jq -n \
    --arg task_id "$task_id" \
    --argjson created_by "$created_by_json" \
    '{
      task_id: $task_id,
      slug: $task_id,
      status: "in_progress",
      assigned: "anna",
      reviewer: "bella",
      created_by: $created_by,
      history: [{
        ts: "2026-08-08T19:30:00+08:00",
        by: "anna",
        action: "comment",
        text: "[BLOCKED-AUTH] isolated patch needs an authorized host apply"
      }]
    }' >"$FATQ_ROOT/in_progress/$task_id.json"
}

make_authority_task "20260808-1930-a111-owner-panda" '"panda"'
make_authority_task "20260808-1930-b222-owner-missing" 'null'

bash "$DISPATCH" >"$TMPROOT/dispatch.log"

panda_relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*a111*-blocked-auth.json' -print -quit)"
fallback_relay="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*b222*-blocked-auth.json' -print -quit)"
[[ -n "$panda_relay" && -n "$fallback_relay" ]]

echo "fixture created_by=panda relay:"
jq -c '{recipient,text,fatq_task_id}' "$panda_relay"
echo "fixture missing created_by relay:"
jq -c '{recipient,text,fatq_task_id}' "$fallback_relay"

jq -e '.recipient == "panda"' "$panda_relay" >/dev/null
jq -e '
  .recipient == "anya"
  and (.text | contains("路由 fallback"))
  and (.text | contains("deliver_to"))
  and (.text | contains("created_by"))
  and (.text | contains("皆缺失"))
' "$fallback_relay" >/dev/null

# AC4: the fixture must not write outside its isolated FATQ_ROOT/relay roots.
test "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f | wc -l)" -eq 2

echo "fatq escalation routing fixture: PASS"

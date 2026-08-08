#!/usr/bin/env bash
# Read-only inventory of done tasks whose recorded deployment commits prove
# code landed while closeout is still pending. Unregistered deployments are
# intentionally not inferred from prose; they require the separate git audit.
set -euo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
done_dir="$FATQ_ROOT/done"
[[ -d "$done_dir" ]] || { echo "[fatq-closeout-pending-inventory] missing done dir: $done_dir" >&2; exit 2; }

find "$done_dir" -maxdepth 1 -type f -name '*.json' -print0 \
  | xargs -0 -r jq -c '
      select((.closeout.state // "") == "pending")
      | ((.closeout.deploy_evidence.commits // []) + (.commits // []) | unique) as $commits
      | select(($commits | length) > 0)
      | {
          task_id:(.task_id // .id),
          reviewer:(.reviewer // null),
          effective_reviewer:(.effective_reviewer // null),
          verdict_by:([(.history // [])[] | select((.action // "") | test("^verdict_(approve|reject)$"))] | last | .by // null),
          commits:$commits,
          closeout_state:.closeout.state,
          evidence_source:"recorded commit fields"
        }
    ' \
  | jq -s 'sort_by(.task_id)'

#!/usr/bin/env bash
set -euo pipefail

: "${REENTER_CLI_SH:?missing REENTER_CLI_SH}"
: "${REENTER_TASK_ID:?missing REENTER_TASK_ID}"
: "${REENTER_MODE:=comment}"
: "${REENTER_AS:=anna}"

case "$REENTER_MODE" in
  comment)
    bash "$REENTER_CLI_SH" comment "$REENTER_TASK_ID" --as "$REENTER_AS" \
      --text "verify re-entered the task lock" >/dev/null
    ;;
  mutate)
    bash "$REENTER_CLI_SH" update-field "$REENTER_TASK_ID" graduated_invariant \
      --as "$REENTER_AS" --value '["changed-during-verify"]' >/dev/null
    ;;
  *)
    echo "unknown REENTER_MODE=$REENTER_MODE" >&2
    exit 2
    ;;
esac

echo "reentrant verify completed"

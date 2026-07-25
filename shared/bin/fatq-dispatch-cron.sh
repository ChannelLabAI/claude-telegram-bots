#!/usr/bin/env bash
# fatq-dispatch-cron.sh — cron entrypoint with a per-run worker snapshot.
# Keep fatq-dispatch.sh usable by tests/manual callers; this wrapper provides
# the liveness signal required for orphan-claim alerts in unattended cron.
# Sourcing a cron entrypoint must never allocate a snapshot or invoke the
# dispatcher.  It intentionally exports no helpers.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# cron has no inherited interactive shell environment.  This is the other
# authorized production entrypoint, so declare and export the destinations
# before starting the dispatcher child.  Direct/manual dispatcher calls still
# fail closed when these variables are absent.
export FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
export FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
snapshot="$(mktemp "${TMPDIR:-/tmp}/fatq-worker-ps.XXXXXX")"
cleanup() { rm -f "$snapshot"; }
trap cleanup EXIT

# The dispatcher consumes exact gateway-builder-<bot> tokens.  If ps fails,
# pipefail stops here: an unknown signal must never become an orphan alert.
ps -eo args= | sed -nE 's|.*(gateway-builder-[[:alnum:]_-]+).*|\1|p' | sort -u > "$snapshot"
FATQ_WORKER_PS_FILE="$snapshot" "$SCRIPT_DIR/fatq-dispatch.sh" "$@"

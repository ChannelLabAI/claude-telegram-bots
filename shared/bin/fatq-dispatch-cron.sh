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

round_log() {
  printf '[%s] dispatch-round source=cron-fallback outcome=%s%s\n' \
    "$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S+08:00')" "$1" "${2:+ $2}"
}
round_log started "stage=triggered"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# cron has no inherited interactive shell environment.  This is the other
# authorized production entrypoint, so declare and export the destinations
# before starting the dispatcher child.  Direct/manual dispatcher calls still
# fail closed when these variables are absent.
export FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
export FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
FATQ_DISPATCH_LOCK="${FATQ_DISPATCH_LOCK:-/tmp/cron-fatq-dispatch.lock}"

# The lock must be acquired inside this observable wrapper. Keeping flock in
# crontab made lock contention indistinguishable from cron never firing.
if ! exec 9>"$FATQ_DISPATCH_LOCK"; then
  round_log lock-open-failed "lock=$FATQ_DISPATCH_LOCK"
  exit 1
fi
if ! /usr/bin/flock -n 9; then
  round_log skipped-lock-held "lock=$FATQ_DISPATCH_LOCK"
  exit 1
fi

snapshot=""
if ! snapshot="$(mktemp "${TMPDIR:-/tmp}/fatq-worker-ps.XXXXXX")"; then
  round_log snapshot-failed "stage=mktemp exit=1"
  exit 1
fi
cleanup() { rm -f "$snapshot" 2>/dev/null || true; }
trap cleanup EXIT

# The dispatcher consumes exact gateway-builder-<bot> tokens.  If ps fails,
# the non-zero status is recorded and still stops dispatch: an unknown signal
# must never become an orphan alert.
if ps -eo args= | sed -nE 's|.*(gateway-builder-[[:alnum:]_-]+).*|\1|p' | sort -u > "$snapshot"; then
  :
else
  snapshot_rc=$?
  round_log snapshot-failed "stage=ps-pipeline exit=$snapshot_rc"
  exit "$snapshot_rc"
fi

if FATQ_WORKER_PS_FILE="$snapshot" "$SCRIPT_DIR/fatq-dispatch.sh" "$@"; then
  round_log dispatcher-exit-zero "exit=0"
  exit 0
else
  dispatcher_rc=$?
  round_log dispatcher-exit-nonzero "exit=$dispatcher_rc"
  exit "$dispatcher_rc"
fi

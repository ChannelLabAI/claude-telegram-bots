#!/usr/bin/env bash
# fatq-dispatch-cron.sh — cron entrypoint with a per-run worker snapshot.
# Keep fatq-dispatch.sh usable by tests/manual callers; this wrapper provides
# the liveness signal required for orphan-claim alerts in unattended cron.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot="$(mktemp "${TMPDIR:-/tmp}/fatq-worker-ps.XXXXXX")"
cleanup() { rm -f "$snapshot"; }
trap cleanup EXIT

# The dispatcher consumes exact gateway-builder-<bot> tokens.  If ps fails,
# pipefail stops here: an unknown signal must never become an orphan alert.
ps -eo args= | sed -nE 's|.*(gateway-builder-[[:alnum:]_-]+).*|\1|p' | sort -u > "$snapshot"
FATQ_WORKER_PS_FILE="$snapshot" "$SCRIPT_DIR/fatq-dispatch.sh" "$@"

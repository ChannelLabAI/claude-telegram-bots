#!/usr/bin/env bash
# probe-marker.sh — Stop hook probe: checks if a marker file exists, writes result to log
#
# Tests filesystem visibility between sibling hook processes:
# - If hook A writes a file and hook B is invoked next, can hook B see it?
# - Race window: how quickly does the marker become visible?
#
# Env vars:
#   MARKER_FILE  — path to the marker file to check/write
#   MARKER_MODE  — "write" (create marker) | "check" (check for marker existence)
#   PROBE_LOG    — where to append results
#   PROBE_ID     — identifier string for this probe instance
#   INVOCATION   — run number (for 5-run test harness)

MARKER_FILE="${MARKER_FILE:-/tmp/probe-marker-test.marker}"
MARKER_MODE="${MARKER_MODE:-check}"
LOG_FILE="${PROBE_LOG:-/tmp/probe-marker.log}"

# Read stdin (hook protocol requires consuming stdin)
INPUT=$(cat)

MARKER_EXISTS="false"
WRITE_RESULT="n/a"

if [[ "$MARKER_MODE" == "write" ]]; then
    # Write the marker file (simulate hook A creating a marker)
    if mkdir -p "$(dirname "$MARKER_FILE")" && echo "$$:$(date +%s):$(date -Iseconds)" > "$MARKER_FILE" 2>/dev/null; then
        WRITE_RESULT="ok"
    else
        WRITE_RESULT="failed"
    fi
    MARKER_EXISTS="written"
elif [[ "$MARKER_MODE" == "check" ]]; then
    # Check for marker visibility (simulate hook B reading hook A's marker)
    if [[ -f "$MARKER_FILE" ]]; then
        MARKER_EXISTS="true"
        MARKER_CONTENT=$(cat "$MARKER_FILE" 2>/dev/null || echo "unreadable")
    else
        MARKER_EXISTS="false"
        MARKER_CONTENT="n/a"
    fi
fi

python3 -c "
import json, sys, os
entry = {
    'probe': 'marker',
    'probe_id': os.environ.get('PROBE_ID', '?'),
    'invocation': os.environ.get('INVOCATION', '?'),
    'pid': os.getpid(),
    'ppid': os.getppid(),
    'marker_file': os.environ.get('MARKER_FILE', '/tmp/probe-marker-test.marker'),
    'marker_mode': os.environ.get('MARKER_MODE', 'check'),
    'marker_exists': sys.argv[1],
    'write_result': sys.argv[2],
    'marker_content': sys.argv[3],
}
with open(os.environ.get('PROBE_LOG', '/tmp/probe-marker.log'), 'a') as f:
    f.write(json.dumps(entry) + '\n')
" "$MARKER_EXISTS" "$WRITE_RESULT" "${MARKER_CONTENT:-n/a}"

# Pass-through
echo "{}"
exit 0

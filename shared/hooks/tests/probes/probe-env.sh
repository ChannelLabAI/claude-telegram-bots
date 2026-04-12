#!/usr/bin/env bash
# probe-env.sh — Stop hook probe: dumps STOP_HOOK_ACTIVE env var value to log
#
# Tests whether the STOP_HOOK_ACTIVE env var set in one sibling hook process
# propagates to another sibling hook process (it should NOT — they are independent
# subprocesses, not parent/child relationships).
#
# Writes to: $PROBE_LOG (env var) or /tmp/probe-env.log

LOG_FILE="${PROBE_LOG:-/tmp/probe-env.log}"

# Read stdin (must consume stdin even if we don't need it — hook protocol)
INPUT=$(cat)

# Dump the env var value as-seen in this process
python3 -c "
import json, sys, os
entry = {
    'probe': 'env',
    'probe_id': os.environ.get('PROBE_ID', '?'),
    'invocation': os.environ.get('INVOCATION', '?'),
    'pid': os.getpid(),
    'ppid': os.getppid(),
    'env_STOP_HOOK_ACTIVE': os.environ.get('STOP_HOOK_ACTIVE', '__not_set__'),
    'env_is_set': 'STOP_HOOK_ACTIVE' in os.environ,
    # Capture full env snapshot of stop-hook-relevant vars
    'env_snapshot': {k: v for k, v in os.environ.items() if 'STOP' in k or 'HOOK' in k or 'CLAUDE' in k or 'TELEGRAM' in k},
}
with open(os.environ.get('PROBE_LOG', '/tmp/probe-env.log'), 'a') as f:
    f.write(json.dumps(entry) + '\n')
"

# Pass-through
echo "{}"
exit 0

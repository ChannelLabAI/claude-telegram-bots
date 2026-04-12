#!/usr/bin/env bash
# probe-stdin.sh — Stop hook probe: dumps stdin content + stop_hook_active field to log
#
# Used by test_stop_hook_contract.sh to verify Claude Code's stdin delivery
# behavior across sibling hook processes.
#
# Writes to: $PROBE_LOG (env var) or /tmp/probe-stdin.log
# Format: one JSON line per invocation with probe metadata

LOG_FILE="${PROBE_LOG:-/tmp/probe-stdin.log}"
PROBE_ID="${PROBE_ID:-stdin}"
INVOCATION="${INVOCATION:-?}"

# Read stdin (this is the only way hooks receive data from Claude Code)
INPUT=$(cat)

# Parse stop_hook_active from JSON
STOP_HOOK_ACTIVE_FIELD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('stop_hook_active', None)
    print(str(v).lower() if isinstance(v, bool) else str(v))
except Exception as e:
    print('parse_error:' + str(e))
" 2>/dev/null)

SESSION_ID=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', 'unknown'))
except:
    print('unknown')
" 2>/dev/null)

# Write result to log (append, one JSON line per probe call)
python3 -c "
import json, sys, os
entry = {
    'probe': 'stdin',
    'probe_id': os.environ.get('PROBE_ID', '?'),
    'invocation': os.environ.get('INVOCATION', '?'),
    'pid': os.getpid(),
    'ppid': os.getppid(),
    'raw_stdin': sys.argv[1],
    'session_id': sys.argv[2],
    'stop_hook_active_field': sys.argv[3],
    'env_STOP_HOOK_ACTIVE': os.environ.get('STOP_HOOK_ACTIVE', ''),
    'stdin_len': len(sys.argv[1]),
}
with open(os.environ.get('PROBE_LOG', '/tmp/probe-stdin.log'), 'a') as f:
    f.write(json.dumps(entry) + '\n')
" "$INPUT" "$SESSION_ID" "$STOP_HOOK_ACTIVE_FIELD"

# Pass-through (allow Claude Code to continue)
echo "{}"
exit 0

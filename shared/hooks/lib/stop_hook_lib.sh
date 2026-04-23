#!/usr/bin/env bash
# stop_hook_lib.sh — shared library for Stop hooks
#
# Provides two primitives:
#   guard_stop_hook_active  — dead-loop prevention: exit 0 if already in a save cycle
#   emit_block_reason       — output JSON block decision for Claude Code to parse
#
# Usage in any Stop hook:
#
#   source "$(dirname "$0")/../lib/stop_hook_lib.sh"
#
#   # MUST be first call in the hook
#   guard_stop_hook_active
#
#   # ... logic ...
#
#   emit_block_reason "Before stopping, save session.json with current state."
#
# Claude Code Stop hook protocol:
#   - stdin: JSON with fields: session_id, stop_hook_active, transcript_path
#   - stdout: JSON {"decision":"block","reason":"..."} to block, or {} to allow
#   - stop_hook_active field in stdin: true when Claude is re-stopping after a block cycle
#     (this is how Claude Code prevents infinite recursion natively)
#
# The guard_stop_hook_active function checks BOTH the stdin JSON field (stop_hook_active)
# AND an env var STOP_HOOK_ACTIVE that our own hooks set before triggering Claude actions.
# Both paths prevent infinite loops.

# guard_stop_hook_active: read stdin JSON, check stop_hook_active field.
# If set (true/True/1), emit {} and exit 0 immediately.
# Also checks env var STOP_HOOK_ACTIVE=1 for cases where hook is re-entered via shell.
#
# IMPORTANT: Call this FIRST in any stop hook, before any other logic.
# After calling this, the parsed INPUT is available in $STOP_HOOK_LIB_INPUT.
guard_stop_hook_active() {
    # Check shell env var first (fast path, no python needed)
    if [[ "${STOP_HOOK_ACTIVE:-}" == "1" ]]; then
        echo "{}"
        exit 0
    fi

    # Read stdin and parse stop_hook_active from Claude Code's JSON
    STOP_HOOK_LIB_INPUT=$(cat)
    export STOP_HOOK_LIB_INPUT

    local active
    active=$(echo "$STOP_HOOK_LIB_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('stop_hook_active', False)
    print('true' if v else 'false')
except:
    print('false')
" 2>/dev/null)

    if [[ "$active" == "true" ]]; then
        echo "{}"
        exit 0
    fi
}

# guard_stop_hook_file_marker <bot_name>
#
# File-based re-entry guard for concurrent sibling hook processes using an
# atomic mkdir lock directory. Unlike a plain file write, mkdir is atomic on
# Linux: exactly one caller wins the race; all others fail instantly.
#
# Lock directory: $HOME/.claude-bots/bots/<bot_name>/.stop_hook_active.lock
# Inside the lock dir: "info" file containing "<pid>:<epoch>".
#
# Behaviour:
#   - mkdir succeeds → this caller wins; writes pid+timestamp; installs EXIT
#     trap to clean up; returns 0 (proceed).
#   - mkdir fails → check whether existing lock is stale (>30s old OR dead pid).
#     If stale: remove lock dir and retry mkdir once.
#     If fresh: return 1 (skip — another live instance is already working).
#
# The caller does NOT need to write or remove the marker manually; this
# function handles both via the EXIT trap.
#
# Returns: 0 = proceed (this caller won the lock), 1 = skip
guard_stop_hook_file_marker() {
    local _bot_name="$1"
    local _lock_dir="$HOME/.claude-bots/bots/${_bot_name}/.stop_hook_active.lock"
    local _info_file="$_lock_dir/info"

    _acquire_lock() {
        if mkdir "$_lock_dir" 2>/dev/null; then
            echo "$$:$(date +%s)" > "$_info_file"
            # shellcheck disable=SC2064
            trap "rm -rf '$_lock_dir'" EXIT
            return 0
        fi
        return 1
    }

    if _acquire_lock; then
        return 0
    fi

    # Lock already exists — check if it is stale.
    # Wait briefly for the info file in case the winner just created the lock
    # dir and hasn't written info yet (avoids false-stale from a write race).
    local _stored _pid _epoch _now _age _wait
    _wait=0
    while [[ ! -f "$_info_file" ]] && [[ $_wait -lt 5 ]]; do
        sleep 0.02
        _wait=$(( _wait + 1 ))
    done

    _stored=$(cat "$_info_file" 2>/dev/null || true)
    _pid="${_stored%%:*}"
    _epoch="${_stored##*:}"
    _now=$(date +%s)

    # If info is still missing or malformed, treat as fresh (lock just acquired)
    if ! [[ "$_pid" =~ ^[0-9]+$ ]] || ! [[ "$_epoch" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    _age=$(( _now - _epoch ))

    if [[ $_age -gt 30 ]] || ! kill -0 "$_pid" 2>/dev/null; then
        # Stale lock (old or dead pid) — remove and retry once
        rm -rf "$_lock_dir"
        _acquire_lock && return 0
    fi

    # Fresh lock held by a live sibling — skip
    return 1
}

# emit_block_reason <reason>: print JSON block decision to stdout and exit 0.
# The "reason" string becomes a system message Claude sees before retrying stop.
# Claude Code will show this to the AI, which will act on it, then try to stop again.
# On that second stop, stop_hook_active=true → guard_stop_hook_active lets it through.
emit_block_reason() {
    local reason="$1"
    python3 -c "
import json, sys
print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}))
" "$reason"
    exit 0
}

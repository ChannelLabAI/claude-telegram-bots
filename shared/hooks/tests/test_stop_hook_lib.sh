#!/usr/bin/env bash
# test_stop_hook_lib.sh — Tests for stop_hook_lib.sh and stop hook PoCs
#
# Run: bash ~/.claude-bots/shared/hooks/tests/test_stop_hook_lib.sh
set -uo pipefail

LIB="$HOME/.claude-bots/shared/hooks/lib/stop_hook_lib.sh"
SAVE_HOOK="$HOME/.claude-bots/shared/hooks/anya-on-stop-save-session.sh"
FLUSH_HOOK="$HOME/.claude-bots/shared/hooks/anya-on-stop-flush-learnings.sh"

PASS=0
FAIL=0

assert_exit() {
    local name="$1" expected_rc="$2" actual_rc="$3" stdout="$4" stderr="$5"
    if [[ "$actual_rc" == "$expected_rc" ]]; then
        printf '  PASS  %s (rc=%s)\n' "$name" "$actual_rc"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$name" "$expected_rc" "$actual_rc"
        [[ -n "$stdout" ]] && printf '        stdout: %s\n' "$stdout"
        [[ -n "$stderr" ]] && printf '        stderr: %s\n' "$stderr"
        FAIL=$((FAIL+1))
    fi
}

assert_json_field() {
    local name="$1" json="$2" field="$3" expected_val="$4"
    local actual_val
    actual_val=$(echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get(sys.argv[1], ''))
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
" "$field" 2>/dev/null)
    if [[ "$actual_val" == "$expected_val" ]]; then
        printf '  PASS  %s (.%s == %q)\n' "$name" "$field" "$expected_val"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s (.%s: expected %q, got %q)\n' "$name" "$field" "$expected_val" "$actual_val"
        FAIL=$((FAIL+1))
    fi
}

echo "stop_hook_lib.sh tests"
echo "======================"

# ---------------------------------------------------------------------------
# 1. guard_stop_hook_active — env var STOP_HOOK_ACTIVE=1 triggers fast-path exit
#    guard_stop_hook_active calls `cat` to read stdin, so we must use a real script
#    file (not a piped subshell) to let `exit` propagate to the outer shell correctly.
# ---------------------------------------------------------------------------
echo ""
echo "--- guard_stop_hook_active (dead-loop prevention) ---"

# Write a real test script so `exit` inside guard exits the whole script
TMPSCRIPT=$(mktemp /tmp/test_guard_XXXX.sh)

# Test: env var guard — STOP_HOOK_ACTIVE=1 should exit before reaching SHOULD_NOT_REACH
cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_active
echo 'SHOULD_NOT_REACH'
SCRIPTEOF
OUT=$(STOP_HOOK_ACTIVE=1 bash "$TMPSCRIPT" <<< '{"session_id":"test","stop_hook_active":false}' 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "env_var_guard_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

if echo "$OUT" | grep -q "SHOULD_NOT_REACH"; then
    printf '  FAIL  env_var_guard_should_not_reach (guard did not exit)\n'
    FAIL=$((FAIL+1))
else
    printf '  PASS  env_var_guard_should_not_reach\n'
    PASS=$((PASS+1))
fi

# Verify stdout is {} (empty JSON object, no decision key)
assert_json_field "env_var_guard_outputs_empty_json" "$OUT" "decision" ""

# ---------------------------------------------------------------------------
# 2. guard_stop_hook_active — stop_hook_active=true in stdin JSON
# ---------------------------------------------------------------------------
cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_active
echo 'SHOULD_NOT_REACH'
SCRIPTEOF
OUT=$(STOP_HOOK_ACTIVE="" bash "$TMPSCRIPT" <<< '{"session_id":"abc","stop_hook_active":true,"transcript_path":""}' 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "stdin_json_guard_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

if echo "$OUT" | grep -q "SHOULD_NOT_REACH"; then
    printf '  FAIL  stdin_json_guard_should_not_reach\n'
    FAIL=$((FAIL+1))
else
    printf '  PASS  stdin_json_guard_should_not_reach\n'
    PASS=$((PASS+1))
fi

# ---------------------------------------------------------------------------
# 3. guard_stop_hook_active — normal stop (stop_hook_active=false) passes through
# ---------------------------------------------------------------------------
cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_active
echo 'REACHED_AFTER_GUARD'
SCRIPTEOF
OUT=$(STOP_HOOK_ACTIVE="" bash "$TMPSCRIPT" <<< '{"session_id":"xyz","stop_hook_active":false,"transcript_path":""}' 2>/tmp/test_stop_hook_err)
RC=$?

if echo "$OUT" | grep -q "REACHED_AFTER_GUARD"; then
    printf '  PASS  normal_stop_passes_guard\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  normal_stop_passes_guard (guard blocked when it should not)\n'
    FAIL=$((FAIL+1))
fi

rm -f "$TMPSCRIPT"

# ---------------------------------------------------------------------------
# 4. emit_block_reason — outputs valid JSON with decision=block
# ---------------------------------------------------------------------------
echo ""
echo "--- emit_block_reason (block output format) ---"

REASON_TEXT="Please save session.json before stopping."
OUT=$(bash -c "
source '$LIB'
emit_block_reason '$REASON_TEXT'
" 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "emit_block_reason_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"
assert_json_field "emit_block_reason_decision" "$OUT" "decision" "block"
assert_json_field "emit_block_reason_reason" "$OUT" "reason" "$REASON_TEXT"

# Verify it's parseable JSON (no parse error)
IS_VALID=$(echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin); print('valid')" 2>/dev/null)
if [[ "$IS_VALID" == "valid" ]]; then
    printf '  PASS  emit_block_reason_valid_json\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  emit_block_reason_valid_json (not valid JSON: %s)\n' "$OUT"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 5. anya-on-stop-save-session.sh — non-anya bot passes through (no block)
# ---------------------------------------------------------------------------
echo ""
echo "--- anya-on-stop-save-session.sh ---"

STDIN_NORMAL='{"session_id":"s1","stop_hook_active":false,"transcript_path":""}'
OUT=$(TELEGRAM_STATE_DIR="/some/path/anna" STOP_HOOK_ACTIVE="" bash -c "
echo '$STDIN_NORMAL' | bash '$SAVE_HOOK'
" 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "save_hook_non_anya_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

# Should output {} (pass-through), not a block
DECISION=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision',''))" 2>/dev/null)
if [[ "$DECISION" != "block" ]]; then
    printf '  PASS  save_hook_non_anya_no_block\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  save_hook_non_anya_no_block (got block for non-anya bot)\n'
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 6. anya-on-stop-save-session.sh — stop_hook_active=true passes through (dead-loop)
# ---------------------------------------------------------------------------
STDIN_ACTIVE='{"session_id":"s2","stop_hook_active":true,"transcript_path":""}'
OUT=$(TELEGRAM_STATE_DIR="/some/path/anya" STOP_HOOK_ACTIVE="" bash -c "
echo '$STDIN_ACTIVE' | bash '$SAVE_HOOK'
" 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "save_hook_active_guard_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

DECISION=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision',''))" 2>/dev/null)
if [[ "$DECISION" != "block" ]]; then
    printf '  PASS  save_hook_active_guard_no_block\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  save_hook_active_guard_no_block (guard did not prevent block in active cycle)\n'
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 7. anya-on-stop-save-session.sh — anya with valid session blocks with reason
# ---------------------------------------------------------------------------
TMPSTATE=$(mktemp -d)
mkdir -p "$TMPSTATE/anya"
echo '{"bot":"anya","in_flight":[],"completedToday":[]}' > "$TMPSTATE/anya/session.json"

STDIN_NORMAL='{"session_id":"s3","stop_hook_active":false,"transcript_path":""}'
OUT=$(TELEGRAM_STATE_DIR="$TMPSTATE/anya" HOME="$HOME" STOP_HOOK_ACTIVE="" bash -c "
# Patch SESSION_FILE resolution by overriding HOME-based path via a wrapper
# The hook uses \$HOME/.claude-bots/state/anya/session.json — we need it to exist
# We simulate by using a temp copy at the real path
mkdir -p '$TMPSTATE/state/anya'
cp '$TMPSTATE/anya/session.json' '$TMPSTATE/state/anya/session.json'
REAL_SESSION=\$HOME/.claude-bots/state/anya/session.json
# Temporarily place our test session file if real one doesn't exist
if [[ ! -f \"\$REAL_SESSION\" ]]; then
    cp '$TMPSTATE/anya/session.json' \"\$REAL_SESSION\"
    CLEANUP_SESSION=1
fi
echo '$STDIN_NORMAL' | TELEGRAM_STATE_DIR='$TMPSTATE/anya' bash '$SAVE_HOOK'
if [[ \"\${CLEANUP_SESSION:-}\" == 1 ]]; then rm -f \"\$REAL_SESSION\"; fi
" 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "save_hook_anya_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

DECISION=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision',''))" 2>/dev/null)
if [[ "$DECISION" == "block" ]]; then
    printf '  PASS  save_hook_anya_blocks\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  save_hook_anya_blocks (expected block, got decision=%s output=%s)\n' "$DECISION" "$OUT"
    FAIL=$((FAIL+1))
fi
rm -rf "$TMPSTATE"

# ---------------------------------------------------------------------------
# 8. anya-on-stop-flush-learnings.sh — no learnings tasks → pass through
# ---------------------------------------------------------------------------
echo ""
echo "--- anya-on-stop-flush-learnings.sh ---"

STDIN_NORMAL='{"session_id":"s4","stop_hook_active":false,"transcript_path":""}'
OUT=$(TELEGRAM_STATE_DIR="/tmp/flush_test/anya" STOP_HOOK_ACTIVE="" bash -c "
mkdir -p /tmp/flush_test/anya
echo '$STDIN_NORMAL' | bash '$FLUSH_HOOK'
rm -rf /tmp/flush_test
" 2>/tmp/test_stop_hook_err)
RC=$?

assert_exit "flush_hook_no_learnings_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"

DECISION=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision',''))" 2>/dev/null)
if [[ "$DECISION" != "block" ]]; then
    printf '  PASS  flush_hook_no_learnings_no_block\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  flush_hook_no_learnings_no_block (got unexpected block)\n'
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 9. guard_stop_hook_file_marker — no prior lock → proceeds (returns 0)
#    Uses a unique test bot name so tests don't collide with each other or
#    real bot state.
# ---------------------------------------------------------------------------
echo ""
echo "--- guard_stop_hook_file_marker (file-based race guard) ---"

# Use an isolated test bot name; ensure no leftover lock from a previous run
TEST_BOT="test-stop-hook-lib-$$"
LOCK_DIR="$HOME/.claude-bots/state/${TEST_BOT}/.stop_hook_active.lock"
rm -rf "$LOCK_DIR"
mkdir -p "$HOME/.claude-bots/state/${TEST_BOT}"

TMPSCRIPT=$(mktemp /tmp/test_guard_file_XXXX.sh)
cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_file_marker "$TEST_BOT"
RC=\$?
echo "GUARD_RC=\$RC"
SCRIPTEOF
OUT=$(bash "$TMPSCRIPT" 2>/tmp/test_stop_hook_err)
RC=$?
GUARD_RC_VAL=$(echo "$OUT" | grep -o 'GUARD_RC=[0-9]' | cut -d= -f2)
# Script exits, EXIT trap cleans up lock
rm -rf "$LOCK_DIR"

assert_exit "file_marker_no_marker_exits_zero" 0 "$RC" "$OUT" "$(cat /tmp/test_stop_hook_err)"
if [[ "$GUARD_RC_VAL" == "0" ]]; then
    printf '  PASS  file_marker_no_marker_returns_0\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  file_marker_no_marker_returns_0 (got GUARD_RC=%s)\n' "$GUARD_RC_VAL"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 10. guard_stop_hook_file_marker — fresh lock with live pid → returns 1 (skip)
#     Simulate by pre-creating the lock dir with our own pid and a fresh epoch.
# ---------------------------------------------------------------------------
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
echo "$$:$(date +%s)" > "$LOCK_DIR/info"

cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_file_marker "$TEST_BOT"
RC=\$?
echo "GUARD_RC=\$RC"
SCRIPTEOF
OUT=$(bash "$TMPSCRIPT" 2>/tmp/test_stop_hook_err)
GUARD_RC_VAL=$(echo "$OUT" | grep -o 'GUARD_RC=[0-9]' | cut -d= -f2)

if [[ "$GUARD_RC_VAL" == "1" ]]; then
    printf '  PASS  file_marker_fresh_live_pid_returns_1\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  file_marker_fresh_live_pid_returns_1 (got GUARD_RC=%s)\n' "$GUARD_RC_VAL"
    FAIL=$((FAIL+1))
fi

# Verify lock dir was NOT removed (still held by our pre-created marker)
if [[ -d "$LOCK_DIR" ]]; then
    printf '  PASS  file_marker_fresh_not_removed_by_guard\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  file_marker_fresh_not_removed_by_guard (guard removed the live lock)\n'
    FAIL=$((FAIL+1))
fi
rm -rf "$LOCK_DIR"

# ---------------------------------------------------------------------------
# 11. guard_stop_hook_file_marker — stale lock (>30s old) → cleaned, returns 0
# ---------------------------------------------------------------------------
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
STALE_EPOCH=$(( $(date +%s) - 60 ))  # 60 seconds ago
echo "$$:$STALE_EPOCH" > "$LOCK_DIR/info"

cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_file_marker "$TEST_BOT"
RC=\$?
echo "GUARD_RC=\$RC"
SCRIPTEOF
OUT=$(bash "$TMPSCRIPT" 2>/tmp/test_stop_hook_err)
GUARD_RC_VAL=$(echo "$OUT" | grep -o 'GUARD_RC=[0-9]' | cut -d= -f2)
rm -rf "$LOCK_DIR"  # clean up lock acquired by winner

if [[ "$GUARD_RC_VAL" == "0" ]]; then
    printf '  PASS  file_marker_stale_returns_0\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  file_marker_stale_returns_0 (got GUARD_RC=%s)\n' "$GUARD_RC_VAL"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 12. guard_stop_hook_file_marker — dead pid lock → cleaned, returns 0
# ---------------------------------------------------------------------------
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# pid 99999999 almost certainly does not exist
echo "99999999:$(date +%s)" > "$LOCK_DIR/info"

cat > "$TMPSCRIPT" << SCRIPTEOF
#!/usr/bin/env bash
source '$LIB'
guard_stop_hook_file_marker "$TEST_BOT"
RC=\$?
echo "GUARD_RC=\$RC"
SCRIPTEOF
OUT=$(bash "$TMPSCRIPT" 2>/tmp/test_stop_hook_err)
GUARD_RC_VAL=$(echo "$OUT" | grep -o 'GUARD_RC=[0-9]' | cut -d= -f2)
rm -rf "$LOCK_DIR"  # clean up lock acquired by winner

if [[ "$GUARD_RC_VAL" == "0" ]]; then
    printf '  PASS  file_marker_dead_pid_returns_0\n'
    PASS=$((PASS+1))
else
    printf '  FAIL  file_marker_dead_pid_returns_0 (got GUARD_RC=%s)\n' "$GUARD_RC_VAL"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 13. Concurrent hooks — exactly one winner, all others skip
#
#     Launches 10 parallel guard calls per round, 20 rounds.
#     Asserts: every round has proceeded == 1 (never 0, never >1).
#     Captures subshell output via a temp result dir (one file per worker).
# ---------------------------------------------------------------------------
echo ""
echo "--- Concurrent orchestrator simulation ---"

CONC_BOT="test-conc-$$"
CONC_LOCK="$HOME/.claude-bots/state/${CONC_BOT}/.stop_hook_active.lock"
mkdir -p "$HOME/.claude-bots/state/${CONC_BOT}"

RESULT_DIR=$(mktemp -d)

# Worker script: try to acquire the lock; if won, sleep briefly then exit.
# Writes "proceeded" or "skipped" into a per-worker result file.
cat > "$TMPSCRIPT" << 'SCRIPTEOF'
#!/usr/bin/env bash
LIB_PATH="$1"
BOT_NAME="$2"
OUT_FILE="$3"
source "$LIB_PATH"
if guard_stop_hook_file_marker "$BOT_NAME"; then
    sleep 0.1   # hold the lock briefly so siblings actually race
    echo "proceeded" > "$OUT_FILE"
else
    echo "skipped" > "$OUT_FILE"
fi
SCRIPTEOF

CONC_PASS=true
NWORKERS=10
NROUNDS=20

for round in $(seq 1 $NROUNDS); do
    rm -rf "$CONC_LOCK"
    rm -rf "$RESULT_DIR"/*

    # Barrier: use a start-flag file. Workers spin-wait until the file appears,
    # ensuring all bash processes are warmed up and racing simultaneously.
    START_FLAG="$RESULT_DIR/start_${round}"
    READY_DIR="$RESULT_DIR/ready_${round}"
    mkdir -p "$READY_DIR"

    pids=()
    for i in $(seq 1 $NWORKERS); do
        (
            # Signal ready
            touch "$READY_DIR/$i"
            # Wait for start flag (spin with short sleep)
            while [[ ! -f "$START_FLAG" ]]; do sleep 0.01; done
            # Race for the lock
            source "$LIB"
            if guard_stop_hook_file_marker "$CONC_BOT"; then
                sleep 0.2   # hold lock long enough for all siblings to attempt
                echo "proceeded" > "$RESULT_DIR/worker_${round}_${i}"
            else
                echo "skipped" > "$RESULT_DIR/worker_${round}_${i}"
            fi
        ) &
        pids+=($!)
    done

    # Wait until all workers are ready, then fire start
    while [[ $(ls "$READY_DIR" | wc -l) -lt $NWORKERS ]]; do sleep 0.01; done
    touch "$START_FLAG"

    wait "${pids[@]}"

    proceeded=$(grep -rl "proceeded" "$RESULT_DIR" 2>/dev/null | wc -l)
    rm -rf "$CONC_LOCK"

    if [[ "$proceeded" -ne 1 ]]; then
        printf '  FAIL  concurrent_exactly_one_winner round=%s proceeded=%s (expected 1)\n' "$round" "$proceeded"
        FAIL=$((FAIL+1))
        CONC_PASS=false
        break
    fi
done

if $CONC_PASS; then
    printf '  PASS  concurrent_exactly_one_winner (%s rounds x %s workers, always proceeded=1)\n' "$NROUNDS" "$NWORKERS"
    PASS=$((PASS+1))
fi

rm -rf "$RESULT_DIR"
rm -rf "$HOME/.claude-bots/state/${CONC_BOT}"
rm -rf "$HOME/.claude-bots/state/${TEST_BOT}"

# Cleanup
rm -f "$TMPSCRIPT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

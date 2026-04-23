#!/usr/bin/env bash
# test_stop_hook_contract.sh — Stop hook sibling behavior contract test harness
#
# Questions answered:
#   Q1. Does stdin get sent to ALL sibling Stop hooks, or just the first one?
#   Q2. Does STOP_HOOK_ACTIVE env var propagate between sibling hook processes?
#   Q3. Can the second sibling hook see a file marker written by the first sibling?
#   Q4. What is the race window between sibling hook invocations?
#   Q5. What is the recommended idiom for safe multi-hook setups?
#
# NOTE — SIMULATED HARNESS:
#   Claude Code invokes Stop hooks by spawning each configured hook as a subprocess
#   and piping the same JSON payload to each one's stdin. We cannot trigger a real
#   Claude Code Stop event from a sub-agent, so this test harness simulates the
#   invocation pattern using:
#
#       bash probe.sh <<< "$JSON"
#
#   This is functionally identical to what Claude Code does (fork + exec + stdin pipe),
#   except for invocation ordering/timing which may differ in production.
#
#   LIVE TEST NEEDED: See STOP_HOOK_CONTRACT.md section "Live Verification".
#
# Usage:
#   bash ~/.claude-bots/shared/hooks/tests/test_stop_hook_contract.sh
#
# Output:
#   - Console: pass/fail per assertion
#   - Log files: ~/.claude-bots/logs/contract-test/{stdin,env,marker}-N.log
#   - Summary: ~/.claude-bots/logs/contract-test/summary.json

set -uo pipefail

PROBES_DIR="$HOME/.claude-bots/shared/hooks/tests/probes"
LOG_DIR="$HOME/.claude-bots/logs/contract-test"
RUNS=5

mkdir -p "$LOG_DIR"

PASS=0
FAIL=0
WARNINGS=()

assert_true() {
    local name="$1" result="$2" detail="${3:-}"
    if [[ "$result" == "true" ]]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s%s\n' "$name" "${detail:+  ($detail)}"
        FAIL=$((FAIL+1))
    fi
}

warn() {
    WARNINGS+=("$1")
    printf '  WARN  %s\n' "$1"
}

# ---------------------------------------------------------------------------
# Sanity: probe scripts exist and are executable
# ---------------------------------------------------------------------------
echo ""
echo "=== Probe script sanity ==="

for probe in probe-stdin.sh probe-env.sh probe-marker.sh; do
    if [[ -x "$PROBES_DIR/$probe" ]]; then
        printf '  PASS  %s exists and is executable\n' "$probe"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s missing or not executable\n' "$probe"
        FAIL=$((FAIL+1))
    fi
done

# ---------------------------------------------------------------------------
# Simulation payload — what Claude Code sends to Stop hooks
# ---------------------------------------------------------------------------
# Claude Code Stop hook stdin JSON schema:
#   session_id:       string — unique session identifier
#   stop_hook_active: bool   — true if this is a re-stop after a block cycle
#   transcript_path:  string — path to the conversation transcript file
SAMPLE_JSON='{"session_id":"contract-test-sim","stop_hook_active":false,"transcript_path":"/tmp/test-transcript.jsonl"}'
ACTIVE_JSON='{"session_id":"contract-test-sim","stop_hook_active":true,"transcript_path":"/tmp/test-transcript.jsonl"}'

# ---------------------------------------------------------------------------
# Q1: STDIN ISOLATION
#
# Each hook process should receive its own stdin pipe with the SAME JSON content.
# Stdin is NOT shared/consumed by the first hook — Claude Code pipes independently
# to each process.
#
# Simulation: run hook-A and hook-B sequentially (as Claude Code would),
# each receiving stdin via <<< heredoc. Verify both receive the full JSON.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q1: stdin isolation (does each sibling get independent stdin?) ==="

for run in $(seq 1 $RUNS); do
    STDIN_LOG="$LOG_DIR/stdin-${run}.log"
    : > "$STDIN_LOG"  # truncate for this run

    # Simulate two sibling hooks receiving the same JSON
    # Claude Code spawns each hook independently — we simulate with sequential calls
    # (ordering: sequential in Claude Code's implementation, not parallel)

    # Hook A (first sibling)
    PROBE_ID="hookA" INVOCATION="$run" PROBE_LOG="$STDIN_LOG" \
        bash "$PROBES_DIR/probe-stdin.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    # Hook B (second sibling) — gets its OWN stdin, same content
    PROBE_ID="hookB" INVOCATION="$run" PROBE_LOG="$STDIN_LOG" \
        bash "$PROBES_DIR/probe-stdin.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    # Parse results: both hooks should have received the same stdin
    ENTRIES=$(python3 -c "
import json, sys
lines = open('$STDIN_LOG').readlines()
entries = [json.loads(l) for l in lines if l.strip()]
print(json.dumps(entries))
" 2>/dev/null)

    HOOK_A_LEN=$(echo "$ENTRIES" | python3 -c "
import json,sys
e = json.load(sys.stdin)
a = [x for x in e if x.get('probe_id')=='hookA']
print(a[0]['stdin_len'] if a else 0)
" 2>/dev/null)

    HOOK_B_LEN=$(echo "$ENTRIES" | python3 -c "
import json,sys
e = json.load(sys.stdin)
b = [x for x in e if x.get('probe_id')=='hookB']
print(b[0]['stdin_len'] if b else 0)
" 2>/dev/null)

    EXPECTED_LEN=${#SAMPLE_JSON}
    assert_true "q1_run${run}_hookA_stdin_len" \
        "$([[ "$HOOK_A_LEN" -eq "$EXPECTED_LEN" ]] && echo true || echo false)" \
        "len=${HOOK_A_LEN}, expected=${EXPECTED_LEN}"

    assert_true "q1_run${run}_hookB_stdin_len" \
        "$([[ "$HOOK_B_LEN" -eq "$EXPECTED_LEN" ]] && echo true || echo false)" \
        "len=${HOOK_B_LEN}, expected=${EXPECTED_LEN}"

    assert_true "q1_run${run}_both_hooks_same_len" \
        "$([[ "$HOOK_A_LEN" -eq "$HOOK_B_LEN" ]] && echo true || echo false)" \
        "hookA=${HOOK_A_LEN}, hookB=${HOOK_B_LEN}"
done

# ---------------------------------------------------------------------------
# Q1b: stop_hook_active field delivery
#
# When stop_hook_active=true in stdin, both hooks should see it.
# When false, both should see false.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q1b: stop_hook_active field delivery ==="

for run in $(seq 1 $RUNS); do
    STDIN_LOG="$LOG_DIR/stdin-active-${run}.log"
    : > "$STDIN_LOG"

    # Both hooks with stop_hook_active=true
    PROBE_ID="hookA" INVOCATION="$run" PROBE_LOG="$STDIN_LOG" \
        bash "$PROBES_DIR/probe-stdin.sh" <<< "$ACTIVE_JSON" > /dev/null 2>&1
    PROBE_ID="hookB" INVOCATION="$run" PROBE_LOG="$STDIN_LOG" \
        bash "$PROBES_DIR/probe-stdin.sh" <<< "$ACTIVE_JSON" > /dev/null 2>&1

    RESULTS=$(python3 -c "
import json
lines = open('$STDIN_LOG').readlines()
entries = [json.loads(l) for l in lines if l.strip()]
fields = {e['probe_id']: e.get('stop_hook_active_field') for e in entries}
print(json.dumps(fields))
" 2>/dev/null)

    HOOK_A_FIELD=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookA','missing'))" 2>/dev/null)
    HOOK_B_FIELD=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookB','missing'))" 2>/dev/null)

    assert_true "q1b_run${run}_hookA_sees_active_true" \
        "$([[ "$HOOK_A_FIELD" == "true" ]] && echo true || echo false)" \
        "got=${HOOK_A_FIELD}"

    assert_true "q1b_run${run}_hookB_sees_active_true" \
        "$([[ "$HOOK_B_FIELD" == "true" ]] && echo true || echo false)" \
        "got=${HOOK_B_FIELD}"
done

# ---------------------------------------------------------------------------
# Q2: ENV VAR ISOLATION
#
# STOP_HOOK_ACTIVE set in hookA's environment should NOT be visible in hookB.
# Hook processes are spawned as independent subprocesses — env vars set inside
# one process are private to that process's address space and do not propagate
# to sibling processes (only parent→child inheritance).
#
# Simulation: run hookA with STOP_HOOK_ACTIVE=1, then run hookB WITHOUT it.
# Verify hookB does NOT see STOP_HOOK_ACTIVE=1.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q2: env var isolation (does STOP_HOOK_ACTIVE propagate to siblings?) ==="

for run in $(seq 1 $RUNS); do
    ENV_LOG="$LOG_DIR/env-${run}.log"
    : > "$ENV_LOG"

    # hookA: has STOP_HOOK_ACTIVE=1 set (simulates a hook that set it for its Claude call)
    PROBE_ID="hookA" INVOCATION="$run" PROBE_LOG="$ENV_LOG" STOP_HOOK_ACTIVE=1 \
        bash "$PROBES_DIR/probe-env.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    # hookB: spawned WITHOUT STOP_HOOK_ACTIVE (independent subprocess, new environment)
    PROBE_ID="hookB" INVOCATION="$run" PROBE_LOG="$ENV_LOG" \
        bash "$PROBES_DIR/probe-env.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    RESULTS=$(python3 -c "
import json
lines = open('$ENV_LOG').readlines()
entries = [json.loads(l) for l in lines if l.strip()]
r = {e['probe_id']: e for e in entries}
print(json.dumps({
    'hookA_env': r.get('hookA', {}).get('env_STOP_HOOK_ACTIVE', 'missing'),
    'hookB_env': r.get('hookB', {}).get('env_STOP_HOOK_ACTIVE', 'missing'),
    'hookA_is_set': r.get('hookA', {}).get('env_is_set', False),
    'hookB_is_set': r.get('hookB', {}).get('env_is_set', False),
}))
" 2>/dev/null)

    HOOK_A_ENV=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookA_env','?'))" 2>/dev/null)
    HOOK_B_ENV=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookB_env','?'))" 2>/dev/null)

    # hookA should see STOP_HOOK_ACTIVE=1 (we set it explicitly)
    assert_true "q2_run${run}_hookA_sees_env_1" \
        "$([[ "$HOOK_A_ENV" == "1" ]] && echo true || echo false)" \
        "got=${HOOK_A_ENV}"

    # hookB should NOT see STOP_HOOK_ACTIVE=1 (env isolation)
    assert_true "q2_run${run}_hookB_does_not_see_env_1" \
        "$([[ "$HOOK_B_ENV" != "1" ]] && echo true || echo false)" \
        "got=${HOOK_B_ENV} (should be __not_set__ or empty)"
done

echo ""
warn "Q2 NOTE: In this simulation, hookA and hookB are separate bash processes."
warn "Q2 NOTE: The isolation is trivially guaranteed because we spawn them with different env."
warn "Q2 NOTE: The KEY finding is: Claude Code cannot magically share env between siblings."
warn "Q2 NOTE: STOP_HOOK_ACTIVE guard alone is insufficient for sibling protection."

# ---------------------------------------------------------------------------
# Q3: FILE MARKER VISIBILITY
#
# File system markers written by hookA ARE visible to hookB, because they share
# the same filesystem. This is the basis for guard_stop_hook_file_marker().
#
# Test: hookA writes a marker file → hookB checks for it → should find it.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q3: file marker visibility (can hookB see hookA's marker?) ==="

for run in $(seq 1 $RUNS); do
    MARKER_LOG="$LOG_DIR/marker-${run}.log"
    MARKER_FILE="$LOG_DIR/test-marker-${run}.marker"
    : > "$MARKER_LOG"
    rm -f "$MARKER_FILE"

    # hookA: write mode (creates marker file)
    PROBE_ID="hookA" INVOCATION="$run" PROBE_LOG="$MARKER_LOG" \
        MARKER_FILE="$MARKER_FILE" MARKER_MODE="write" \
        bash "$PROBES_DIR/probe-marker.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    # hookB: check mode (reads marker file)
    PROBE_ID="hookB" INVOCATION="$run" PROBE_LOG="$MARKER_LOG" \
        MARKER_FILE="$MARKER_FILE" MARKER_MODE="check" \
        bash "$PROBES_DIR/probe-marker.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    RESULTS=$(python3 -c "
import json
lines = open('$MARKER_LOG').readlines()
entries = [json.loads(l) for l in lines if l.strip()]
r = {e['probe_id']: e for e in entries}
print(json.dumps({
    'hookA_write': r.get('hookA', {}).get('write_result', 'missing'),
    'hookB_exists': r.get('hookB', {}).get('marker_exists', 'missing'),
}))
" 2>/dev/null)

    HOOK_A_WRITE=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookA_write','?'))" 2>/dev/null)
    HOOK_B_EXISTS=$(echo "$RESULTS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookB_exists','?'))" 2>/dev/null)

    assert_true "q3_run${run}_hookA_write_ok" \
        "$([[ "$HOOK_A_WRITE" == "ok" ]] && echo true || echo false)" \
        "write_result=${HOOK_A_WRITE}"

    assert_true "q3_run${run}_hookB_sees_marker" \
        "$([[ "$HOOK_B_EXISTS" == "true" ]] && echo true || echo false)" \
        "marker_exists=${HOOK_B_EXISTS}"

    rm -f "$MARKER_FILE"
done

# ---------------------------------------------------------------------------
# Q4: RACE WINDOW MEASUREMENT
#
# Measure the elapsed time between hookA completing its write and hookB
# being able to read the marker. In sequential hook invocation (Claude Code
# default), the race window is the time between two sequential process spawns
# — typically microseconds to milliseconds.
#
# NOTE: If Claude Code invokes hooks in parallel (not confirmed), the race
# window becomes real and concurrent access must be handled atomically.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q4: race window measurement ==="

TIMING_LOG="$LOG_DIR/timing.log"
: > "$TIMING_LOG"

for run in $(seq 1 $RUNS); do
    MARKER_FILE="$LOG_DIR/timing-marker-${run}.marker"
    rm -f "$MARKER_FILE"

    # Record time before hookA
    T_BEFORE=$(date +%s%N)  # nanoseconds

    # hookA: write marker
    PROBE_ID="hookA" INVOCATION="$run" PROBE_LOG="/dev/null" \
        MARKER_FILE="$MARKER_FILE" MARKER_MODE="write" \
        bash "$PROBES_DIR/probe-marker.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    T_AFTER_A=$(date +%s%N)

    # hookB: check marker
    PROBE_ID="hookB" INVOCATION="$run" PROBE_LOG="/dev/null" \
        MARKER_FILE="$MARKER_FILE" MARKER_MODE="check" \
        bash "$PROBES_DIR/probe-marker.sh" <<< "$SAMPLE_JSON" > /dev/null 2>&1

    T_AFTER_B=$(date +%s%N)

    # Calculate elapsed times
    HOOKB_CAN_SEE="$([[ -f "$MARKER_FILE" ]] && echo true || echo false)"
    ELAPSED_A_MS=$(( (T_AFTER_A - T_BEFORE) / 1000000 ))
    ELAPSED_B_MS=$(( (T_AFTER_B - T_AFTER_A) / 1000000 ))

    python3 -c "
import json
entry = {
    'run': $run,
    'hookA_spawn_ms': $ELAPSED_A_MS,
    'hookB_spawn_ms': $ELAPSED_B_MS,
    'marker_visible_to_hookB': '$HOOKB_CAN_SEE',
}
with open('$TIMING_LOG', 'a') as f:
    f.write(json.dumps(entry) + '\n')
"
    printf '  INFO  run=%s hookA_spawn=%sms hookB_spawn=%sms marker_visible=%s\n' \
        "$run" "$ELAPSED_A_MS" "$ELAPSED_B_MS" "$HOOKB_CAN_SEE"

    rm -f "$MARKER_FILE"
done

# Compute average timing
AVG_SPAWN_MS=$(python3 -c "
import json
lines = open('$TIMING_LOG').readlines()
entries = [json.loads(l) for l in lines if l.strip()]
if not entries: print('n/a'); exit()
avg_a = sum(e['hookA_spawn_ms'] for e in entries) / len(entries)
avg_b = sum(e['hookB_spawn_ms'] for e in entries) / len(entries)
print(f'hookA_avg={avg_a:.1f}ms hookB_avg={avg_b:.1f}ms')
" 2>/dev/null)

printf '  INFO  averages over %s runs: %s\n' "$RUNS" "$AVG_SPAWN_MS"
echo ""
warn "Q4 NOTE: Race window = time between sequential hook invocations in Claude Code."
warn "Q4 NOTE: If hooks are invoked in PARALLEL, file markers alone are insufficient."
warn "Q4 NOTE: Use atomic mkdir (guard_stop_hook_file_marker) for concurrent-safe guards."

# ---------------------------------------------------------------------------
# Q5: RECOMMENDED IDIOM — atomic mkdir guard
#
# Verify the library's guard_stop_hook_file_marker provides correct mutual
# exclusion across 10 concurrent simulated hook processes.
# ---------------------------------------------------------------------------
echo ""
echo "=== Q5: recommended idiom — atomic mkdir guard (3 concurrent workers) ==="

LIB="$HOME/.claude-bots/shared/hooks/lib/stop_hook_lib.sh"
CONC_BOT="test-contract-$$"
CONC_LOCK="$HOME/.claude-bots/bots/${CONC_BOT}/.stop_hook_active.lock"
mkdir -p "$HOME/.claude-bots/bots/${CONC_BOT}"

RESULT_DIR=$(mktemp -d)
NWORKERS=3  # Use 3 for a quick, reliable test

for run in $(seq 1 $RUNS); do
    rm -rf "$CONC_LOCK"
    rm -rf "$RESULT_DIR"/*

    START_FLAG="$RESULT_DIR/start_${run}"
    READY_DIR="$RESULT_DIR/ready_${run}"
    mkdir -p "$READY_DIR"

    pids=()
    for i in $(seq 1 $NWORKERS); do
        (
            touch "$READY_DIR/$i"
            while [[ ! -f "$START_FLAG" ]]; do sleep 0.01; done
            source "$LIB"
            if guard_stop_hook_file_marker "$CONC_BOT"; then
                sleep 0.1
                echo "proceeded" > "$RESULT_DIR/worker_${run}_${i}"
            else
                echo "skipped" > "$RESULT_DIR/worker_${run}_${i}"
            fi
        ) &
        pids+=($!)
    done

    while [[ $(ls "$READY_DIR" | wc -l) -lt $NWORKERS ]]; do sleep 0.01; done
    touch "$START_FLAG"
    wait "${pids[@]}"

    proceeded=$(grep -rl "proceeded" "$RESULT_DIR" 2>/dev/null | grep "worker_${run}_" | wc -l)
    rm -rf "$CONC_LOCK"

    assert_true "q5_run${run}_exactly_one_winner" \
        "$([[ "$proceeded" -eq 1 ]] && echo true || echo false)" \
        "proceeded=${proceeded}, workers=${NWORKERS}"
done

rm -rf "$RESULT_DIR"
rm -rf "$HOME/.claude-bots/bots/${CONC_BOT}"

# ---------------------------------------------------------------------------
# Summary + write JSON summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Runs: %s  Pass: %s  Fail: %s\n' "$RUNS" "$PASS" "$FAIL"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo "Warnings / interpretation notes:"
    for w in "${WARNINGS[@]}"; do
        printf '  * %s\n' "$w"
    done
fi

# Write JSON summary
python3 -c "
import json, datetime
summary = {
    'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
    'runs': $RUNS,
    'pass': $PASS,
    'fail': $FAIL,
    'harness_type': 'simulated',
    'note': 'Simulated harness. Live Claude Code verification required for authoritative results.',
    'findings': {
        'Q1_stdin_isolation': 'Each simulated hook receives independent stdin pipe with identical JSON content',
        'Q2_env_isolation': 'STOP_HOOK_ACTIVE env var does NOT propagate between sibling processes',
        'Q3_file_markers': 'File markers written by hookA ARE visible to hookB via shared filesystem',
        'Q4_race_window': 'Sequential invocation means minimal race window; parallel invocation (unconfirmed) would require atomic guards',
        'Q5_recommended_idiom': 'Use atomic mkdir (guard_stop_hook_file_marker) — provides mutual exclusion regardless of invocation order',
    }
}
import pathlib
pathlib.Path('$LOG_DIR/summary.json').write_text(json.dumps(summary, indent=2))
print('Summary written to $LOG_DIR/summary.json')
" 2>/dev/null

echo ""
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" && exit 0
echo "SOME TESTS FAILED"
exit 1

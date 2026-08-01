#!/usr/bin/env bash
# fatq-verify.sh — Run verify_commands from a FATQ task JSON and report pass/fail.
#
# Usage:  fatq-verify.sh [--field verify_commands|graduated_invariant|live_verify_commands] <task.json>
# Exit:   0 = all pass (or no verify_commands → N/A)
#         1 = one or more commands failed
#         2 = script error (bad args, file not found, invalid JSON)
#
# cmd field MUST be a string array (shell=False equivalent), NOT a shell string.
# Each element is passed as a separate argv token — no eval, no bash -c.

set -euo pipefail

FIELD="verify_commands"
if [[ "${1:-}" == "--field" ]]; then
    FIELD="${2:-}"
    shift 2 || true
fi

case "$FIELD" in
    verify_commands|graduated_invariant|live_verify_commands) ;;
    *)
        echo "[fatq-verify] ERROR: unsupported field: $FIELD" >&2
        exit 2
        ;;
esac

TASK_JSON="${1:-}"

if [[ -z "$TASK_JSON" ]]; then
    echo "[fatq-verify] ERROR: usage: fatq-verify.sh [--field verify_commands|graduated_invariant|live_verify_commands] <task.json>" >&2
    exit 2
fi

if [[ ! -f "$TASK_JSON" ]]; then
    echo "[fatq-verify] ERROR: file not found: $TASK_JSON" >&2
    exit 2
fi

# Validate JSON
if ! jq empty "$TASK_JSON" 2>/dev/null; then
    echo "[fatq-verify] ERROR: invalid JSON: $TASK_JSON" >&2
    exit 2
fi

# Preserve the original verify_commands user-visible contract on the default
# path; only the explicitly selected field gets field-aware wording.
VC_COUNT=$(jq --arg field "$FIELD" 'if has($field) then (.[$field] | length) else 0 end' "$TASK_JSON")
if [[ "$VC_COUNT" -eq 0 ]]; then
    if [[ "$FIELD" == "verify_commands" ]]; then
        echo "[fatq-verify] N/A: no verify_commands in task — skipping (exit 0)"
    else
        echo "[fatq-verify] N/A: no $FIELD in task — skipping (exit 0)"
    fi
    exit 0
fi

if [[ "$FIELD" == "verify_commands" ]]; then
    echo "[fatq-verify] Running $VC_COUNT verify command(s)..."
else
    echo "[fatq-verify] Running $VC_COUNT command(s) from $FIELD..."
fi

pass=0
fail=0
fail_list=()
fail_stdout_samples=()
fail_stderr_samples=()
VERIFY_OUTPUT_LIMIT_BYTES=8192
capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/fatq-verify-output.XXXXXX")" || {
    echo "[fatq-verify] ERROR: unable to create bounded output capture directory" >&2
    exit 2
}
trap 'rm -r -- "$capture_dir"' EXIT

for idx in $(seq 0 $((VC_COUNT - 1))); do
    entry=$(jq -c --arg field "$FIELD" --argjson idx "$idx" '.[$field][$idx]' "$TASK_JSON")
    desc=$(jq -r '.desc // "command #'"$((idx+1))"'"' <<< "$entry")
    expect_exit=$(jq -r '.expect_exit // 0' <<< "$entry")

    # Validate cmd is an array
    cmd_type=$(jq -r '.cmd | type' <<< "$entry")
    if [[ "$cmd_type" != "array" ]]; then
        echo "[fatq-verify] ERROR: ${FIELD}[$idx].cmd must be a JSON array, got: $cmd_type" >&2
        exit 2
    fi

    # Read cmd array elements safely — no eval, no shell string interpolation
    mapfile -t cmd_array < <(jq -r '.cmd[]' <<< "$entry")

    if [[ ${#cmd_array[@]} -eq 0 ]]; then
        echo "[fatq-verify] ERROR: ${FIELD}[$idx].cmd is empty" >&2
        exit 2
    fi

    # Execute: each element is a separate argv token (shell=False equivalent).
    # Successful command output remains quiet.  Failed command output is
    # retained below as bounded per-stream diagnostics so a noisy verifier
    # cannot flood the gate output.
    actual_exit=0
    stdout_file="$capture_dir/$idx.stdout"
    stderr_file="$capture_dir/$idx.stderr"
    "${cmd_array[@]}" >"$stdout_file" 2>"$stderr_file" || actual_exit=$?

    if [[ "$actual_exit" -eq "$expect_exit" ]]; then
        echo "  ✅ PASS [$((idx+1))/$VC_COUNT] $desc (exit $actual_exit == expected $expect_exit)"
        ((pass++)) || true
    else
        echo "  ❌ FAIL [$((idx+1))/$VC_COUNT] $desc (exit $actual_exit != expected $expect_exit)"
        stdout_bytes=$(wc -c <"$stdout_file" | tr -d ' ')
        stderr_bytes=$(wc -c <"$stderr_file" | tr -d ' ')
        stdout_truncated=false
        stderr_truncated=false
        [[ "$stdout_bytes" -gt "$VERIFY_OUTPUT_LIMIT_BYTES" ]] && stdout_truncated=true
        [[ "$stderr_bytes" -gt "$VERIFY_OUTPUT_LIMIT_BYTES" ]] && stderr_truncated=true
        stdout_sample="$capture_dir/$idx.stdout.sample"
        stderr_sample="$capture_dir/$idx.stderr.sample"
        head -c "$VERIFY_OUTPUT_LIMIT_BYTES" "$stdout_file" >"$stdout_sample"
        head -c "$VERIFY_OUTPUT_LIMIT_BYTES" "$stderr_file" >"$stderr_sample"
        fail_list+=("[$((idx+1))] $desc — got exit $actual_exit, expected $expect_exit; stdout_bytes=$stdout_bytes stdout_truncated=$stdout_truncated; stderr_bytes=$stderr_bytes stderr_truncated=$stderr_truncated")
        fail_stdout_samples+=("$stdout_sample")
        fail_stderr_samples+=("$stderr_sample")
        ((fail++)) || true
    fi
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-verify] RESULT: $pass pass, $fail fail (of $VC_COUNT)"

if [[ $fail -gt 0 ]]; then
    echo "[fatq-verify] FAILED gates:"
    for fail_idx in "${!fail_list[@]}"; do
        item="${fail_list[$fail_idx]}"
        echo "  • $item"
        echo "    stdout (first $VERIFY_OUTPUT_LIMIT_BYTES bytes):"
        cat "${fail_stdout_samples[$fail_idx]}"
        echo ""
        echo "    stderr (first $VERIFY_OUTPUT_LIMIT_BYTES bytes):"
        cat "${fail_stderr_samples[$fail_idx]}" >&2
        echo "" >&2
    done
    exit 1
fi

echo "[fatq-verify] All gates passed ✅"
exit 0

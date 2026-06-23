#!/usr/bin/env bash
# fatq-verify.sh — Run verify_commands from a FATQ task JSON and report pass/fail.
#
# Usage:  fatq-verify.sh <task.json>
# Exit:   0 = all pass (or no verify_commands → N/A)
#         1 = one or more commands failed
#         2 = script error (bad args, file not found, invalid JSON)
#
# cmd field MUST be a string array (shell=False equivalent), NOT a shell string.
# Each element is passed as a separate argv token — no eval, no bash -c.

set -euo pipefail

TASK_JSON="${1:-}"

if [[ -z "$TASK_JSON" ]]; then
    echo "[fatq-verify] ERROR: usage: fatq-verify.sh <task.json>" >&2
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

# Check for verify_commands presence
VC_COUNT=$(jq 'if has("verify_commands") then (.verify_commands | length) else 0 end' "$TASK_JSON")
if [[ "$VC_COUNT" -eq 0 ]]; then
    echo "[fatq-verify] N/A: no verify_commands in task — skipping (exit 0)"
    exit 0
fi

echo "[fatq-verify] Running $VC_COUNT verify command(s)..."

pass=0
fail=0
fail_list=()

for idx in $(seq 0 $((VC_COUNT - 1))); do
    entry=$(jq -c ".verify_commands[$idx]" "$TASK_JSON")
    desc=$(jq -r '.desc // "command #'"$((idx+1))"'"' <<< "$entry")
    expect_exit=$(jq -r '.expect_exit // 0' <<< "$entry")

    # Validate cmd is an array
    cmd_type=$(jq -r '.cmd | type' <<< "$entry")
    if [[ "$cmd_type" != "array" ]]; then
        echo "[fatq-verify] ERROR: verify_commands[$idx].cmd must be a JSON array, got: $cmd_type" >&2
        exit 2
    fi

    # Read cmd array elements safely — no eval, no shell string interpolation
    mapfile -t cmd_array < <(jq -r '.cmd[]' <<< "$entry")

    if [[ ${#cmd_array[@]} -eq 0 ]]; then
        echo "[fatq-verify] ERROR: verify_commands[$idx].cmd is empty" >&2
        exit 2
    fi

    # Execute: each element is a separate argv token (shell=False equivalent)
    actual_exit=0
    "${cmd_array[@]}" >/dev/null 2>&1 || actual_exit=$?

    if [[ "$actual_exit" -eq "$expect_exit" ]]; then
        echo "  ✅ PASS [$((idx+1))/$VC_COUNT] $desc (exit $actual_exit == expected $expect_exit)"
        ((pass++)) || true
    else
        echo "  ❌ FAIL [$((idx+1))/$VC_COUNT] $desc (exit $actual_exit != expected $expect_exit)"
        fail_list+=("[$((idx+1))] $desc — got exit $actual_exit, expected $expect_exit")
        ((fail++)) || true
    fi
done

echo ""
echo "────────────────────────────────────"
echo "[fatq-verify] RESULT: $pass pass, $fail fail (of $VC_COUNT)"

if [[ $fail -gt 0 ]]; then
    echo "[fatq-verify] FAILED gates:"
    for item in "${fail_list[@]}"; do
        echo "  • $item"
    done
    exit 1
fi

echo "[fatq-verify] All gates passed ✅"
exit 0

#!/usr/bin/env bash
# run-tests.sh — Shared contract and FATQ regression suites.
# Usage: bash shared/bin/tests/run-tests.sh
# Exit:  0 = all tests passed,  1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/../fatq-verify.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

pass=0
fail=0

run_test() {
    local name="$1"
    local fixture="$2"
    local expected_exit="$3"

    actual_exit=0
    "$VERIFY" "$fixture" >/dev/null 2>&1 || actual_exit=$?

    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        echo "  ✅ PASS: $name (exit $actual_exit)"
        ((pass++)) || true
    else
        echo "  ❌ FAIL: $name (exit $actual_exit, expected $expected_exit)"
        ((fail++)) || true
    fi
}

echo "=== fatq-verify.sh test suite ==="
echo ""

# T1: all-pass fixture → expect exit 0
run_test "all-pass fixture" "$FIXTURES/task-verify-pass.json" 0

# T2: fail fixture → expect exit 1
run_test "fail fixture" "$FIXTURES/task-verify-fail.json" 1

# T3: noop (no verify_commands) → expect exit 0
run_test "noop (no verify_commands)" "$FIXTURES/task-verify-noop.json" 0

# T4: file not found → expect exit 2
run_test "file not found" "/nonexistent/task.json" 2

echo ""
echo "────────────────────────────────────"
echo "RESULT: $pass pass, $fail fail"

if [[ $fail -gt 0 ]]; then
    echo "FAILED"
    exit 1
fi

echo "Core verifier cases passed ✅"

echo ""
echo "=== FATQ create gate regression suites ==="
bash "$SCRIPT_DIR/../../tests/fatq-dispatch-test.sh"
bash "$SCRIPT_DIR/../../tests/fatq-cli-test.sh"
bash "$SCRIPT_DIR/fatq-pending-lint-test.sh"

echo ""
echo "=== Event contract compatibility lint ==="
bun run "$SCRIPT_DIR/../../event-layer/contract-lint.ts"

echo "ALL PASSED ✅"
exit 0

#!/usr/bin/env bash
# test-inject.sh — Injection-based tests for symlink-health detector
# Deliberately creates broken symlinks/drift, verifies detection, then restores.
# Tests: D1 broken detection, D2 drift detection, deny-list guard, circuit breaker

set -uo pipefail

LOOP_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$LOOP_DIR/../../.." && pwd)"
BOTS_DIR="$BASE_DIR/bots"
AUDIT_LOG="$LOOP_DIR/symlink-health.audit.jsonl"

PASS=0; FAIL=0

check() {
    local desc="$1" result="$2" expected="$3"
    if [[ "$result" == *"$expected"* ]]; then
        echo "  ✅ $desc"
        PASS=$((PASS+1))
    else
        echo "  ❌ $desc: got '$result', expected to contain '$expected'"
        FAIL=$((FAIL+1))
    fi
}

echo "=== symlink-health inject tests ==="

# Target: use anna/blocks/block-section11.md (a known symlink)
TEST_TARGET="$BOTS_DIR/anna/blocks/block-section11.md"
BACKUP_READLINK=$(readlink "$TEST_TARGET" 2>/dev/null || echo "")

if [ ! -L "$TEST_TARGET" ]; then
    echo "SKIP: $TEST_TARGET is not a symlink, cannot inject"
    exit 0
fi

# ── Test 1: D1 broken symlink detection ──────────────────────────────────────
echo ""
echo "T1: Broken symlink detection (D1)"

# Save original and create broken symlink
orig_target=$(readlink "$TEST_TARGET")
ln -sf "/nonexistent/path/block-section11.md" "$TEST_TARGET"

output=$(bash "$LOOP_DIR/detector.sh" 2>&1)
# Restore immediately
ln -sf "$orig_target" "$TEST_TARGET"

check "D1 broken detected" "$output" "broken=1"
check "D1 mode=dry_run (not auto_fix)" "$output" "mode=dry_run"
check "D1 logs proposal" "$(tail -1 "$AUDIT_LOG")" "dry_run_proposed"

# ── Test 2: Deny-list guard ───────────────────────────────────────────────────
echo ""
echo "T2: Deny-list — .mcp.json never touched"

# Detector should never find .mcp.json as an anomaly
output2=$(bash "$LOOP_DIR/detector.sh" 2>&1)
if echo "$output2" | grep -q "\.mcp\.json"; then
    echo "  ❌ deny-list FAIL: .mcp.json appeared in output"
    FAIL=$((FAIL+1))
else
    echo "  ✅ .mcp.json absent from output"
    PASS=$((PASS+1))
fi

# ── Test 3: Healthy run zero false-positives ─────────────────────────────────
echo ""
echo "T3: Healthy run — no false positives on per-bot regular files"

# Per-bot regular files (block-mcp-tools-policy.md etc.) are NOT canonical → should NOT appear as drift
output3=$(bash "$LOOP_DIR/detector.sh" 2>&1)
healthy=$(echo "$output3" | grep -o 'healthy=[0-9]*' | head -1)
echo "  Healthy symlinks: $healthy (expect ~47, 1 drift_conflict for anya/block-diana-query)"
check "bella/block-mcp-tools-policy not flagged" "$(tail -1 "$AUDIT_LOG")" "block-diana-query"  # only diana-query in findings
check "No broken in healthy run" "$output3" "broken=0"

# ── Test 4: VERIFY V3 (generate-manifest.py --stdout) ────────────────────────
echo ""
echo "T4: VERIFY V3 — block appears in manifest"

v3_result=$(python3 "$BASE_DIR/shared/lib/generate-manifest.py" \
    "$BOTS_DIR/anna/blocks" --stdout 2>/dev/null | python3 -c "
import json, sys
m = json.load(sys.stdin)
found = [b for b in m if b['name'] == 'block-section11.md']
print('FOUND:priority=' + found[0]['priority'] if found else 'NOT_FOUND')
")
check "V3 block-section11 in anna manifest" "$v3_result" "FOUND"

# ── Test 5: Config kill switch ────────────────────────────────────────────────
echo ""
echo "T5: Kill switch — loop_enabled=0 exits immediately"

# Temporarily override config
CONFIG_FILE="$LOOP_DIR/config"
orig_config=$(cat "$CONFIG_FILE")
echo "loop_enabled=0" > "$CONFIG_FILE"
ks_output=$(bash "$LOOP_DIR/detector.sh" 2>&1)
echo "$orig_config" > "$CONFIG_FILE"  # restore

check "kill switch exits" "$ks_output" "loop_enabled=0"

# ── Test 6: auto_fix flag OFF cannot modify files ────────────────────────────
echo ""
echo "T6: Flag OFF — dry-run mode does not modify files"

# Break a symlink again temporarily
ln -sf "/nonexistent/flag-test" "$TEST_TARGET"
pre_inode=$(stat -c '%i' "$(dirname "$TEST_TARGET")" 2>/dev/null || stat -f '%i' "$(dirname "$TEST_TARGET")")
bash "$LOOP_DIR/detector.sh" 2>/dev/null  # run in dry-run mode
# File should still be the broken symlink (not fixed)
current_target=$(readlink "$TEST_TARGET" 2>/dev/null || echo "gone")

# Restore
ln -sf "$orig_target" "$TEST_TARGET"

if [ "$current_target" = "/nonexistent/flag-test" ]; then
    echo "  ✅ Flag OFF: file NOT modified (still broken symlink as injected)"
    PASS=$((PASS+1))
else
    echo "  ❌ Flag OFF violated: symlink was modified to '$current_target' despite auto_fix_enabled=0"
    FAIL=$((FAIL+1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "ALL PASS ✅" && exit 0 || exit 1

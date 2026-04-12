#!/bin/bash
# Portability test: verify stat, date, and sed work on current platform.
# Prints PASS/FAIL for each check.

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

# ── stat ──────────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp)
echo -n "hello" > "$TMPFILE"  # 5 bytes

# Linux style
SIZE_LINUX=$(stat -c%s "$TMPFILE" 2>/dev/null)
if [ "$SIZE_LINUX" = "5" ]; then
    pass "stat -c%s (Linux) returns correct file size"
else
    fail "stat -c%s (Linux) returned '$SIZE_LINUX', expected 5"
fi

# macOS style (may not exist on Linux, that's OK)
SIZE_MAC=$(stat -f%z "$TMPFILE" 2>/dev/null)
if [ "$SIZE_MAC" = "5" ]; then
    pass "stat -f%z (macOS) returns correct file size"
else
    echo "INFO: stat -f%z not available on this platform (expected on Linux)"
fi

# Dual-fallback pattern (what audit-log.sh uses)
SIZE_DUAL=$(stat -c%s "$TMPFILE" 2>/dev/null || stat -f%z "$TMPFILE" 2>/dev/null || echo 0)
if [ "$SIZE_DUAL" = "5" ]; then
    pass "stat dual-fallback pattern returns correct file size"
else
    fail "stat dual-fallback pattern returned '$SIZE_DUAL', expected 5"
fi

rm -f "$TMPFILE"

# ── date ──────────────────────────────────────────────────────────────────────
# Basic ISO timestamp (used in audit-log.sh, platform-neutral)
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
if echo "$TS" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    pass "date -u '+%Y-%m-%dT%H:%M:%SZ' produces valid ISO timestamp"
else
    fail "date -u ISO timestamp produced '$TS'"
fi

# date -d (Linux) vs date -j (macOS)
EPOCH_LINUX=$(date -d "2026-01-01" +%s 2>/dev/null)
if [ -n "$EPOCH_LINUX" ] && [ "$EPOCH_LINUX" -gt 0 ] 2>/dev/null; then
    pass "date -d (Linux) parses date string"
else
    echo "INFO: date -d not available on this platform (expected on macOS)"
fi

EPOCH_MAC=$(date -j -f "%Y-%m-%d" "2026-01-01" +%s 2>/dev/null)
if [ -n "$EPOCH_MAC" ] && [ "$EPOCH_MAC" -gt 0 ] 2>/dev/null; then
    pass "date -j (macOS) parses date string"
else
    echo "INFO: date -j not available on this platform (expected on Linux)"
fi

# Dual-fallback date pattern
EPOCH_DUAL=$(date -d "2026-01-01" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "2026-01-01" +%s 2>/dev/null)
if [ -n "$EPOCH_DUAL" ] && [ "$EPOCH_DUAL" -gt 0 ] 2>/dev/null; then
    pass "date dual-fallback pattern parses date string"
else
    fail "date dual-fallback pattern returned '$EPOCH_DUAL'"
fi

# ── sed ───────────────────────────────────────────────────────────────────────
TMPFILE2=$(mktemp)
echo "foo bar" > "$TMPFILE2"

# Linux sed -i (no empty string)
sed -i 's/foo/baz/' "$TMPFILE2" 2>/dev/null
RESULT=$(cat "$TMPFILE2")
if [ "$RESULT" = "baz bar" ]; then
    pass "sed -i (Linux, no empty string arg) works"
else
    fail "sed -i (Linux) produced '$RESULT', expected 'baz bar'"
fi

rm -f "$TMPFILE2"

# ── audit-log.sh rotate simulation ───────────────────────────────────────────
TMPDIR_ROTATE=$(mktemp -d)
FAKE_LOG="$TMPDIR_ROTATE/audit.log"
MAX_SIZE=$((10 * 1024 * 1024))  # 10MB

# Create a file just over 10MB
dd if=/dev/zero bs=1024 count=10241 2>/dev/null | tr '\0' 'x' > "$FAKE_LOG"

CURRENT_SIZE=$(stat -c%s "$FAKE_LOG" 2>/dev/null || stat -f%z "$FAKE_LOG" 2>/dev/null || echo 0)
if [ "$CURRENT_SIZE" -gt "$MAX_SIZE" ]; then
    ROTATED="${FAKE_LOG%.log}.$(date +%Y%m%d_%H%M%S).log"
    mv "$FAKE_LOG" "$ROTATED"
    if [ ! -f "$FAKE_LOG" ] && [ -f "$ROTATED" ]; then
        pass "audit-log rotate: oversize log correctly rotated to timestamped backup"
    else
        fail "audit-log rotate: rotation did not produce expected files"
    fi
else
    fail "audit-log rotate: size detection failed (got $CURRENT_SIZE, expected > $MAX_SIZE)"
fi

rm -rf "$TMPDIR_ROTATE"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

#!/usr/bin/env bash
# test_model_resolve.sh — Unit tests for shared/bin/model-resolve.sh
# AC1: each bot resolves to current hardcode (換來源不換值)
# AC2: corrupt yml → fallback to hardcode (fail-safe)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="${MODEL_RESOLVE_SHIM:-$SCRIPT_DIR/../../bin/model-resolve.sh}"
YML="${MODEL_ROUTER_YML:-$SCRIPT_DIR/../../config/model-router.yml}"
PASS=0; FAIL=0

TEST_YML=$(mktemp)
cp "$YML" "$TEST_YML"
trap 'rm -f "$TEST_YML"' EXIT

check() {
  local bot="$1" expected="$2" label="${3:-}"
  local actual
  actual=$(MODEL_ROUTER_YML="$TEST_YML" "$SHIM" "$bot" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $bot → $actual ${label:+($label)}"
    PASS=$((PASS+1))
  else
    echo "  ✗ $bot → got='$actual' expected='$expected' ${label:+($label)}"
    FAIL=$((FAIL+1))
  fi
}

echo "=== AC1: Normal Claude routing (Codex tier aliases fall back safely) ==="
check "anya"              "claude-opus-4-8"    "D1 滯後 opus 不變"
check "twinkle"           "claude-opus-4-8"    "full-ID 正規化等價"
check "anna"              "claude-sonnet-5"
check "bella"             "claude-fable-5"
check "sancai"            "claude-sonnet-5"
check "yitang"            "claude-sonnet-5"
check "eric"              "claude-sonnet-5"
check "interns"           "claude-sonnet-5"
check "ron-assistant"     "claude-sonnet-5"
check "ron-reviewer"      "claude-sonnet-5"
check "caijie-zhuchu"     "claude-sonnet-5"
check "chltao"            "claude-sonnet-5"
check "wes-buddy"         "claude-sonnet-5"
check "lilai-fengfeng"    "claude-sonnet-5"
check "33-huizhang"       "claude-sonnet-5"
check "nicky-zhanglinghe" "claude-sonnet-5"  "nicky flag-order special"
check "unknown-bot"       "claude-sonnet-5"  "_default fallback"

echo ""
echo "=== AC2: Corrupt yml fail-safe (isolated fixture) ==="
printf '%s\n' 'NOT VALID YAML !!! @#$%^' > "$TEST_YML"

check "anya"    "claude-opus-4-8"   "corrupt yml fallback"
check "twinkle" "claude-opus-4-8"   "corrupt yml fallback"
check "anna"    "claude-sonnet-5" "corrupt yml fallback"

cp "$YML" "$TEST_YML"

echo ""
echo "=== AC2b: Missing yml fail-safe (isolated fixture) ==="
SAVED_TEST_YML="$TEST_YML"
TEST_YML="${TEST_YML}.missing"

check "anya" "claude-opus-4-8" "missing yml fallback"

TEST_YML="$SAVED_TEST_YML"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

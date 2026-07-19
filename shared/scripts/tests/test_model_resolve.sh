#!/usr/bin/env bash
# test_model_resolve.sh — Unit tests for shared/bin/model-resolve.sh
# AC1: each bot resolves to current hardcode (換來源不換值)
# AC2: corrupt yml → fallback to hardcode (fail-safe)

set -euo pipefail

SHIM="/home/oldrabbit/.claude-bots/shared/bin/model-resolve.sh"
YML="/home/oldrabbit/.claude-bots/shared/config/model-router.yml"
PASS=0; FAIL=0

check() {
  local bot="$1" expected="$2" label="${3:-}"
  local actual
  actual=$("$SHIM" "$bot" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $bot → $actual ${label:+($label)}"
    PASS=$((PASS+1))
  else
    echo "  ✗ $bot → got='$actual' expected='$expected' ${label:+($label)}"
    FAIL=$((FAIL+1))
  fi
}

echo "=== AC1: Normal routing (yml present) ==="
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
echo "=== AC2: Corrupt yml fail-safe (modifies real yml, restore on exit) ==="
# Must corrupt the REAL yml (shim hardcodes its path; env var override doesn't work)
YML_BACKUP=$(mktemp)
# Trap ensures yml is always restored even if tests crash
trap "cp -f '$YML_BACKUP' '$YML' 2>/dev/null; rm -f '$YML_BACKUP'" EXIT

cp "$YML" "$YML_BACKUP"
echo "NOT VALID YAML !!! @#\$%^" > "$YML"

check "anya"    "claude-opus-4-8"   "corrupt yml fallback"
check "twinkle" "claude-opus-4-8"   "corrupt yml fallback"
check "anna"    "claude-sonnet-5" "corrupt yml fallback"

cp "$YML_BACKUP" "$YML"
trap - EXIT  # clear trap (yml restored)
rm -f "$YML_BACKUP"

echo ""
echo "=== AC2b: Missing yml fail-safe ==="
YML_BACKUP2=$(mktemp)
trap "cp -f '$YML_BACKUP2' '$YML' 2>/dev/null; rm -f '$YML_BACKUP2'" EXIT
cp "$YML" "$YML_BACKUP2"
rm -f "$YML"

check "anya" "claude-opus-4-8" "missing yml fallback"

cp "$YML_BACKUP2" "$YML"
trap - EXIT
rm -f "$YML_BACKUP2"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

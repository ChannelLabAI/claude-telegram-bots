#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$ROOT/shared/bin/fatq-verify.sh"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

write_fixture() {
  local path="$1"
  local verify_commands="$2"
  local graduated_invariant="$3"
  jq -n \
    --argjson verify_commands "$verify_commands" \
    --argjson graduated_invariant "$graduated_invariant" \
    '{verify_commands:$verify_commands, graduated_invariant:$graduated_invariant}' \
    > "$path"
}

expect_rc() {
  local expected="$1"
  shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'FAIL: expected rc=%s, got rc=%s: %q\n' "$expected" "$actual" "$*" >&2
    exit 1
  fi
}

expect_output() {
  local expected="$1"
  shift
  local actual
  actual="$("$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: output changed for: %q\n--- expected ---\n%s\n--- actual ---\n%s\n' \
      "$*" "$expected" "$actual" >&2
    exit 1
  fi
}

PASS='[{"cmd":["bash","-c","exit 0"],"expect_exit":0,"desc":"pass"}]'
FAIL='[{"cmd":["bash","-c","exit 1"],"expect_exit":0,"desc":"fail"}]'
EMPTY='[]'

write_fixture "$FIXTURE_DIR/default-pass.json" "$PASS" "$FAIL"
write_fixture "$FIXTURE_DIR/default-fail.json" "$FAIL" "$PASS"
write_fixture "$FIXTURE_DIR/invariant-fail.json" "$PASS" "$FAIL"
write_fixture "$FIXTURE_DIR/invariant-empty.json" "$FAIL" "$EMPTY"

# No flag remains backward compatible with verify_commands.
expect_rc 0 "$VERIFY" "$FIXTURE_DIR/default-pass.json"
expect_rc 1 "$VERIFY" "$FIXTURE_DIR/default-fail.json"
expect_output "[fatq-verify] Running 1 verify command(s)...
  ✅ PASS [1/1] pass (exit 0 == expected 0)

────────────────────────────────────
[fatq-verify] RESULT: 1 pass, 0 fail (of 1)
[fatq-verify] All gates passed ✅" \
  "$VERIFY" "$FIXTURE_DIR/default-pass.json"

default_fail_output="$("$VERIFY" "$FIXTURE_DIR/default-fail.json" || true)"
expected_default_fail_output="[fatq-verify] Running 1 verify command(s)...
  ❌ FAIL [1/1] fail (exit 1 != expected 0)

────────────────────────────────────
[fatq-verify] RESULT: 0 pass, 1 fail (of 1)
[fatq-verify] FAILED gates:
  • [1] fail — got exit 1, expected 0"
if [[ "$default_fail_output" != "$expected_default_fail_output" ]]; then
  printf 'FAIL: legacy failing verify_commands output changed\n' >&2
  exit 1
fi

# The explicit field selects graduated_invariant and preserves pass/fail/N/A.
expect_rc 0 "$VERIFY" --field graduated_invariant "$FIXTURE_DIR/default-fail.json"
expect_rc 1 "$VERIFY" --field graduated_invariant "$FIXTURE_DIR/invariant-fail.json"
expect_rc 0 "$VERIFY" --field graduated_invariant "$FIXTURE_DIR/invariant-empty.json"

# Argument errors fail closed.
expect_rc 2 "$VERIFY" --field unsupported "$FIXTURE_DIR/default-pass.json"
expect_rc 2 "$VERIFY" --field
expect_rc 2 "$VERIFY"

echo "PASS fatq-verify field compatibility fixtures"

#!/usr/bin/env bash
# Run the KG cold-candidate reconciliation audit and alert a concrete human-facing
# relay recipient only when the audit fails. The audit itself remains read-only.

set -euo pipefail

ROOT="${KG_COLD_AUDIT_ROOT:-/home/oldrabbit/.claude-bots}"
AUDIT_SCRIPT="${KG_COLD_AUDIT_SCRIPT:-$ROOT/shared/scripts/kg-cold-candidate-audit.sh}"
AUDIT_DB="${KG_COLD_AUDIT_DB:-$ROOT/memory.db}"
RELAY_NOTIFY="${KG_COLD_AUDIT_RELAY_NOTIFY:-$ROOT/shared/bin/relay-notify}"
RECIPIENT="${KG_COLD_AUDIT_RECIPIENT:-anya}"
TIMEOUT_BIN="${KG_COLD_AUDIT_TIMEOUT_BIN:-/usr/bin/timeout}"
BASH_BIN="${KG_COLD_AUDIT_BASH_BIN:-/usr/bin/bash}"
AUDIT_TIMEOUT_SECS="${KG_COLD_AUDIT_TIMEOUT_SECS:-90}"
NOTIFY_TIMEOUT_SECS="${KG_COLD_AUDIT_NOTIFY_TIMEOUT_SECS:-15}"
NOW="${KG_COLD_AUDIT_NOW:-}"

fail() {
  printf '[kg-cold-audit] ERROR %s\n' "$*" >&2
  exit 2
}

[[ -x "$TIMEOUT_BIN" ]] || fail "timeout is not executable: $TIMEOUT_BIN"
[[ -x "$BASH_BIN" ]] || fail "bash is not executable: $BASH_BIN"
[[ -x "$RELAY_NOTIFY" ]] || fail "relay-notify is not executable: $RELAY_NOTIFY"
[[ "$AUDIT_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || fail "invalid audit timeout: $AUDIT_TIMEOUT_SECS"
[[ "$NOTIFY_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || fail "invalid notify timeout: $NOTIFY_TIMEOUT_SECS"

if [[ -z "$NOW" ]]; then
  if ! NOW="$("$TIMEOUT_BIN" --signal=TERM --kill-after=2s 5s /usr/bin/date -Iseconds)"; then
    fail "could not obtain observation timestamp"
  fi
fi

set +e
audit_output="$(KG_COLD_CANDIDATE_DB="$AUDIT_DB" \
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "${AUDIT_TIMEOUT_SECS}s" \
  "$BASH_BIN" "$AUDIT_SCRIPT" 2>&1)"
audit_rc=$?
set -e

checked=0
if [[ "$audit_output" =~ (^|[[:space:]])checked=([0-9]+) ]]; then
  checked="${BASH_REMATCH[2]}"
elif ((audit_rc == 0)); then
  audit_rc=2
  audit_output="audit returned success without a numeric checked observation; ${audit_output}"
fi

if ((audit_rc == 0)); then
  printf '[kg-cold-audit] OK observed_at=%s checked=%s alert_sent=0 %s\n' \
    "$NOW" "$checked" "$audit_output"
  exit 0
fi

one_line="${audit_output//$'\n'/; }"
message="[KG cold candidate audit] FAIL observed_at=${NOW} checked=${checked} audit_exit=${audit_rc}. ${one_line}"

set +e
notify_output="$("$TIMEOUT_BIN" --signal=TERM --kill-after=2s "${NOTIFY_TIMEOUT_SECS}s" \
  "$BASH_BIN" "$RELAY_NOTIFY" kg-cold-audit "$RECIPIENT" "$message" 2>&1)"
notify_rc=$?
set -e

if ((notify_rc != 0)); then
  printf '[kg-cold-audit] NOTIFY_FAILED observed_at=%s checked=%s recipient=%s audit_exit=%s notify_exit=%s detail=%s\n' \
    "$NOW" "$checked" "$RECIPIENT" "$audit_rc" "$notify_rc" "$notify_output" >&2
  exit 2
fi

printf '[kg-cold-audit] ALERT_SENT observed_at=%s checked=%s recipient=%s audit_exit=%s envelope=%s\n' \
  "$NOW" "$checked" "$RECIPIENT" "$audit_rc" "$notify_output"
exit "$audit_rc"

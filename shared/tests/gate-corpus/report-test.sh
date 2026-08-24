#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../../bin/gate-corpus-report.sh"

policy_output="$("$REPORT" "$HERE/cases.jsonl")"
grep -Eq '^G09[[:space:]]+0[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+disabled$' <<< "$policy_output"
grep -Eq '^G12[[:space:]]+0[[:space:]]+2[[:space:]]+0[[:space:]]+0[[:space:]]+advisory$' <<< "$policy_output"

rollback_output="$(FATQ_G09_BLOCKING=1 FATQ_G12_BLOCKING=1 "$REPORT" "$HERE/cases.jsonl")"
grep -Eq '^G09[[:space:]]+0[[:space:]]+1[[:space:]]+2[[:space:]]+0[[:space:]]+blocking$' <<< "$rollback_output"
grep -Eq '^G12[[:space:]]+0[[:space:]]+2[[:space:]]+2[[:space:]]+0[[:space:]]+blocking$' <<< "$rollback_output"
"$HERE/selection-check.sh" "$HERE/cases.jsonl" >/dev/null

tmp="$(mktemp "${TMPDIR:-/tmp}/gate-corpus-broken.XXXXXX.jsonl")"
trap 'rm -f -- "$tmp"' EXIT
jq -c 'if .id == "C001" then del(.description) else . end' "$HERE/cases.jsonl" >"$tmp"

set +e
output="$("$REPORT" "$tmp" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 || "$output" != *"C001"* || "$output" != *"description"* ]]; then
  echo "negative control failed: rc=$rc output=$output" >&2
  exit 1
fi

echo "gate corpus tests PASS (phase-1 policy, rollback modes, reproducible selection, negative required-field control)"

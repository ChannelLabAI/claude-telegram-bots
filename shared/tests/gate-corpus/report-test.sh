#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../../bin/gate-corpus-report.sh"

"$REPORT" "$HERE/cases.jsonl" >/dev/null
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

echo "gate corpus tests PASS (positive report, reproducible selection, negative required-field control)"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${1:-$ROOT/tests/gate-corpus/cases.jsonl}"
POLICY_FILE="${FATQ_GATE_POLICY_FILE:-$ROOT/lib/fatq-gate-policy.sh}"

if [[ -r "$POLICY_FILE" ]]; then
  # shellcheck source=../lib/fatq-gate-policy.sh
  source "$POLICY_FILE"
fi
FATQ_G09_BLOCKING="${FATQ_G09_BLOCKING:-0}"
FATQ_G12_BLOCKING="${FATQ_G12_BLOCKING:-0}"
case "$FATQ_G09_BLOCKING:$FATQ_G12_BLOCKING" in
  0:0|0:1|1:0|1:1) ;;
  *) echo "gate-corpus: FATQ_G09_BLOCKING and FATQ_G12_BLOCKING must be 0 or 1" >&2; exit 2 ;;
esac

if [[ ! -s "$CORPUS" ]]; then
  echo "gate-corpus: missing or empty corpus: $CORPUS" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-corpus-report.XXXXXX")"
trap 'rm -r -- "$tmp"' EXIT

line_no=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_no=$((line_no + 1))
  if ! jq -e . >/dev/null 2>"$tmp/jq-error" <<<"$line"; then
    echo "gate-corpus: line $line_no invalid JSON: $(<"$tmp/jq-error")" >&2
    exit 2
  fi
  printf '%s\n' "$line" >>"$tmp/cases.jsonl"
done <"$CORPUS"

if ! error="$(jq -r '
  def nonempty_string: type == "string" and length > 0;
  def gate: type == "string" and test("^G(0[1-9]|1[0-2])$");
  if type != "object" then "case is not an object"
  elif (.id | nonempty_string | not) then "id is required"
  elif (.source | type) != "object" then "source is required"
  elif (.source.kind | nonempty_string | not) then "source.kind is required"
  elif (.source.ref | nonempty_string | not) then "source.ref is required"
  elif (.date | type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)) then "date must be YYYY-MM-DD"
  elif (.description | nonempty_string | not) then "description is required"
  elif (.expected_gates | type != "array" or length == 0 or any(.[]; gate | not)) then "expected_gates must be a non-empty known-gate array"
  elif (.outcome != "caught" and .outcome != "missed" and .outcome != "false_block") then "outcome must be caught, missed, or false_block"
  elif .outcome == "caught" and ((.caught_by | type) != "array" or (.caught_by | length) == 0 or any(.caught_by[]; gate | not)) then "caught case needs non-empty caught_by"
  elif .outcome == "missed" and ((.caught_by | type) != "array" or (.caught_by | length) != 0) then "missed case needs empty caught_by"
  elif .outcome == "false_block" and ((.blocked_by | type) != "array" or (.blocked_by | length) == 0 or any(.blocked_by[]; gate | not)) then "false_block case needs non-empty blocked_by"
  else empty end
' "$tmp/cases.jsonl" | awk 'NF {print "case " NR " (" $0 ")"; exit}')"; then
  echo "gate-corpus: validation engine failed" >&2
  exit 2
fi

# Re-run diagnostics with stable case identity rather than physical line alone.
validation_error="$(jq -r '
  def ns: type == "string" and length > 0;
  def gate: type == "string" and test("^G(0[1-9]|1[0-2])$");
  . as $c | ($c.id // ("line-" + (input_line_number|tostring))) as $id |
  if type != "object" then "\($id): case is not an object"
  elif (.id | ns | not) then "\($id): id is required"
  elif (.source | type) != "object" then "\($id): source is required"
  elif (.source.kind | ns | not) then "\($id): source.kind is required"
  elif (.source.ref | ns | not) then "\($id): source.ref is required"
  elif (.date | type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)) then "\($id): date must be YYYY-MM-DD"
  elif (.description | ns | not) then "\($id): description is required"
  elif (.expected_gates | type != "array" or length == 0 or any(.[]; gate | not)) then "\($id): expected_gates invalid"
  elif (.outcome != "caught" and .outcome != "missed" and .outcome != "false_block") then "\($id): outcome invalid"
  elif .outcome == "caught" and ((.caught_by | type) != "array" or (.caught_by | length) == 0 or any(.caught_by[]; gate | not)) then "\($id): caught_by invalid"
  elif .outcome == "missed" and ((.caught_by | type) != "array" or (.caught_by | length) != 0) then "\($id): caught_by must be empty"
  elif .outcome == "false_block" and ((.blocked_by | type) != "array" or (.blocked_by | length) == 0 or any(.blocked_by[]; gate | not)) then "\($id): blocked_by invalid"
  else empty end
' "$tmp/cases.jsonl" | head -1)"
if [[ -n "$validation_error" ]]; then
  echo "gate-corpus: $validation_error" >&2
  exit 2
fi

duplicate="$(jq -s -r 'group_by(.id)[] | select(length > 1) | .[0].id' "$tmp/cases.jsonl" | head -1)"
if [[ -n "$duplicate" ]]; then
  echo "gate-corpus: duplicate id: $duplicate" >&2
  exit 2
fi

count="$(wc -l <"$tmp/cases.jsonl" | tr -d ' ')"
if [[ "$count" -lt 30 ]]; then
  echo "gate-corpus: need at least 30 cases, got $count" >&2
  exit 2
fi

echo "Gate corpus scorecard (cases=$count)"
printf '%-4s\t%6s\t%6s\t%11s\t%9s\t%s\n' GATE caught missed false_block exclusive mode
for n in $(seq -w 1 12); do
  gate="G$n"
  mode="blocking"
  if [[ "$gate" == "G09" && "$FATQ_G09_BLOCKING" == "0" ]]; then
    mode="disabled"
  elif [[ "$gate" == "G12" && "$FATQ_G12_BLOCKING" == "0" ]]; then
    mode="advisory"
  fi
  jq -s -r --arg gate "$gate" --arg mode "$mode" '
    [ $gate,
      ([.[] | select(.outcome == "caught" and ((.caught_by // []) | index($gate)))] | length),
      ([.[] | select(.outcome == "missed" and (.expected_gates | index($gate)))] | length),
      (if $mode == "blocking" then ([.[] | select(.outcome == "false_block" and ((.blocked_by // []) | index($gate)))] | length) else 0 end),
      ([.[] | select(.outcome == "caught" and (.caught_by | length) == 1 and (.caught_by[0] == $gate))] | length),
      $mode
    ] | @tsv' "$tmp/cases.jsonl"
done

echo
echo "Zero-score gates (caught=0):"
jq -s -r '
  [range(1;13) | "G" + (if . < 10 then "0" else "" end) + tostring] as $gates
  | $gates[] as $g
  | select([.[] | select(.outcome == "caught" and ((.caught_by // []) | index($g)))] | length == 0)
  | $g' "$tmp/cases.jsonl" | paste -sd, -

echo "No-exclusive gates (exclusive=0):"
jq -s -r '
  [range(1;13) | "G" + (if . < 10 then "0" else "" end) + tostring] as $gates
  | $gates[] as $g
  | select([.[] | select(.outcome == "caught" and (.caught_by | length) == 1 and .caught_by[0] == $g)] | length == 0)
  | $g' "$tmp/cases.jsonl" | paste -sd, -

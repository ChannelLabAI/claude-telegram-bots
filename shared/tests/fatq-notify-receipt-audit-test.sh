#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fatq-notify-receipt-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fatq-notify-receipt-audit.sh"
NOW=1787832000
TASKS="$ROOT/tasks"
RELAY="$ROOT/relay"
mkdir -p "$TASKS/done" "$RELAY/read" "$ROOT/shared/config" "$ROOT/pods"

cat > "$ROOT/shared/config/patrol-scan.json" <<'JSON'
{
  "thresholds_seconds": {"relay_unconsumed": 900},
  "true_bot_recipients_fallback": ["anna", "Annadesu_bot"]
}
JSON
cat > "$ROOT/shared/config/relay-consumed-readers.json" <<'JSON'
{
  "readers": [{
    "marker": "DianaAI_v2_bot",
    "system_identity": "keeper",
    "roster_id": "diana",
    "dispatch_key": "keeper",
    "tg_username": "DianaAI_v2_bot",
    "aliases": ["diana", "keeper", "DianaAI_v2_bot"]
  }, {
    "marker": "WeirdBot_bot",
    "system_identity": "weirdbot",
    "roster_id": "weirdbot",
    "dispatch_key": "weird-dispatch-only",
    "tg_username": "WeirdBot_bot",
    "aliases": ["weirdbot", "WeirdBot_bot"]
  }]
}
JSON
cat > "$ROOT/pods/builder.json" <<'JSON'
{"bots":[{"name":"anna","username":"Annadesu_bot"}]}
JSON

write_task() {
  local task_id="$1" action="$2" relay_file="$3" ts="${4:-2026-08-27T19:00:00+08:00}"
  jq -n --arg task_id "$task_id" --arg action "$action" --arg relay_file "$relay_file" --arg ts "$ts" \
    '{task_id:$task_id, history:[{ts:$ts, action:$action, relay_file:$relay_file}]}' \
    > "$TASKS/done/$task_id.json"
}

write_envelope() {
  local directory="$1" relay_file="$2" recipient="$3"
  jq -n --arg recipient "$recipient" '{recipient:$recipient, text:"fixture"}' > "$directory/$relay_file"
}

reset_fixture() {
  find "$TASKS/done" "$RELAY" "$RELAY/read" -maxdepth 1 -type f -delete
}

run_script() {
  local script_path="$1"
  shift
  FATQ_NOTIFY_RECEIPT_ROOT="$ROOT" \
  FATQ_NOTIFY_RECEIPT_TASKS_DIR="$TASKS" \
  FATQ_NOTIFY_RECEIPT_RELAY_DIR="$RELAY" \
  FATQ_NOTIFY_RECEIPT_READ_DIR="$RELAY/read" \
  FATQ_NOTIFY_RECEIPT_PATROL_CONFIG="$ROOT/shared/config/patrol-scan.json" \
  FATQ_NOTIFY_RECEIPT_READERS_CONFIG="$ROOT/shared/config/relay-consumed-readers.json" \
  FATQ_NOTIFY_RECEIPT_PODS_DIR="$ROOT/pods" \
  FATQ_NOTIFY_RECEIPT_NOW_EPOCH="$NOW" \
  "$script_path" --since 24 "$@"
}

run_audit() { run_script "$SCRIPT" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass_count=0
pass() { pass_count=$((pass_count + 1)); echo "PASS $pass_count: $*"; }

# AC1: zero markers for a mapped recipient is an itemized, alerting rejection.
write_task fixture-no-marker completion_delivery_notified fatq-fixture-no-marker.json
write_envelope "$RELAY" fatq-fixture-no-marker.json keeper
set +e
no_marker_output="$(run_audit --json 2>&1)"
no_marker_rc=$?
set -e
[[ "$no_marker_rc" -eq 1 ]] || fail "no-marker fixture must exit 1, got $no_marker_rc"
jq -e '.counts.unconsumed == 1 and .counts.alerting == 1 and
  (.unconsumed[] | select(.task_id == "fixture-no-marker" and
    .relay_file == "fatq-fixture-no-marker.json" and
    .expected_marker == "DianaAI_v2_bot"))' <<<"$no_marker_output" >/dev/null \
  || fail "no-marker fixture was not itemized as unconsumed"
echo "BASELINE zero-marker-rejected task_id=fixture-no-marker relay_file=fatq-fixture-no-marker.json"
pass "AC1 zero-marker rejection is visible"

# AC1 mutant: deleting unconsumed classification kills the same rejection.
ZERO_MUTANT="$ROOT/fatq-notify-zero-mutant.sh"
sed 's/classification="unconsumed"/classification="consumed"/' "$SCRIPT" > "$ZERO_MUTANT"
chmod +x "$ZERO_MUTANT"
set +e
zero_mutant_output="$(run_script "$ZERO_MUTANT" --json 2>&1)"
zero_mutant_rc=$?
set -e
if [[ "$zero_mutant_rc" -eq 1 ]] && jq -e '.counts.unconsumed == 1' <<<"$zero_mutant_output" >/dev/null 2>&1; then
  fail "zero-marker mutant unexpectedly preserved rejection"
fi
echo "MUTANT zero-marker-rejection-killed task_id=fixture-no-marker relay_file=fatq-fixture-no-marker.json"
pass "AC1 mutant proves the rejection assertion can fail"

# AC2 + AC4(a): readers-config alias resolves keeper to Diana's exact marker.
: > "$RELAY/fatq-fixture-no-marker.json.read-by-DianaAI_v2_bot"
consumed_output="$(run_audit --json)"
jq -e '.counts.consumed == 1 and .counts.unconsumed == 0 and
  (.consumed[] | select(.task_id == "fixture-no-marker" and
    .expected_marker == "DianaAI_v2_bot" and
    .reason == "expected-consumer-marker-present"))' <<<"$consumed_output" >/dev/null \
  || fail "reader alias marker did not classify as consumed"
echo "DISCRIMINATOR own-marker unconsumed=0; zero-marker-positive-control unconsumed=1"
pass "AC2/AC4(a) readers-config alias matches its own marker only"

# AC4(a) mismatch direction: the same readers-config alias rejects another bot's marker.
reset_fixture
write_task fixture-reader-config-mismatch completion_delivery_notified fatq-reader-config-mismatch.json
write_envelope "$RELAY" fatq-reader-config-mismatch.json keeper
: > "$RELAY/fatq-reader-config-mismatch.json.read-by-Annadesu_bot"
set +e
reader_mismatch_output="$(run_audit --json 2>&1)"
reader_mismatch_rc=$?
set -e
[[ "$reader_mismatch_rc" -eq 1 ]] || fail "readers-config mismatch must alert"
jq -e '.counts.unconsumed == 1 and .counts.consumed == 0 and
  (.unconsumed[] | select(.task_id == "fixture-reader-config-mismatch" and
    .expected_marker == "DianaAI_v2_bot" and
    .reason == "expected-consumer-marker-missing"))' <<<"$reader_mismatch_output" >/dev/null \
  || fail "readers-config mismatch was not unconsumed"
pass "AC4(a) readers-config alias rejects another bot marker"

# R1 regression: reader metadata outside aliases[] must not broaden map_alias.
reset_fixture
write_task fixture-dispatch-only-alias completion_delivery_notified fatq-dispatch-only-alias.json
write_envelope "$RELAY" fatq-dispatch-only-alias.json weird-dispatch-only
: > "$RELAY/fatq-dispatch-only-alias.json.read-by-WeirdBot_bot"
dispatch_only_output="$(run_audit --json)"
jq -e '.counts.consumed == 0 and .counts.unconsumed == 0 and .counts.undetermined == 1 and
  (.undetermined[] | select(.task_id == "fixture-dispatch-only-alias" and
    .reason == "recipient-marker-unmapped" and .expected_marker == ""))' \
  <<<"$dispatch_only_output" >/dev/null \
  || fail "dispatch_key outside aliases[] incorrectly broadened reader identity mapping"
pass "R1 reader mapping stays identical to archiver map_alias aliases-only semantics"

# AC3: an unrelated bot marker must not consume Anna's relay.
reset_fixture
write_task fixture-wrong-reader completion_delivery_notified fatq-fixture-wrong-reader.json
write_envelope "$RELAY" fatq-fixture-wrong-reader.json anna
: > "$RELAY/fatq-fixture-wrong-reader.json.read-by-DianaAI_v2_bot"
set +e
wrong_reader_output="$(run_audit --json 2>&1)"
wrong_reader_rc=$?
set -e
[[ "$wrong_reader_rc" -eq 1 ]] || fail "wrong-reader fixture must alert"
jq -e '.counts.unconsumed == 1 and .counts.consumed == 0 and
  (.unconsumed[] | select(.task_id == "fixture-wrong-reader" and
    .expected_marker == "Annadesu_bot" and
    .reason == "expected-consumer-marker-missing"))' <<<"$wrong_reader_output" >/dev/null \
  || fail "unrelated marker incorrectly consumed Anna relay"
echo "BASELINE identity-mismatch-rejected recipient=anna marker=DianaAI_v2_bot expected=Annadesu_bot"
pass "AC3 unrelated marker remains unconsumed"

# AC3 mutant: accepting any marker makes the identity assertion fail.
IDENTITY_MUTANT="$ROOT/fatq-notify-identity-mutant.sh"
sed 's@elif \[\[ -n "${MARKER_IDENTITY_SET\[.*@elif find "$RELAY_DIR" "$READ_DIR" -maxdepth 1 -type f -name "$relay_file.read-by-*" -print -quit | grep -q .; then@' \
  "$SCRIPT" > "$IDENTITY_MUTANT"
chmod +x "$IDENTITY_MUTANT"
grep -F 'find "$RELAY_DIR" "$READ_DIR"' "$IDENTITY_MUTANT" >/dev/null \
  || fail "identity mutant was not created"
identity_mutant_output="$(run_script "$IDENTITY_MUTANT" --json)"
if jq -e '.counts.unconsumed == 1 and .counts.consumed == 0' <<<"$identity_mutant_output" >/dev/null 2>&1; then
  fail "identity mutant unexpectedly preserved mismatch rejection"
fi
jq -e '.counts.consumed == 1' <<<"$identity_mutant_output" >/dev/null \
  || fail "identity mutant did not expose the false negative"
echo "MUTANT identity-check-killed recipient=anna unrelated-marker=DianaAI_v2_bot classification=consumed"
pass "AC3 mutant proves exact recipient identity is load-bearing"

# AC4(b): recipient absent from readers config resolves through pod tg_username.
reset_fixture
write_task fixture-pod-recipient reject_notified fatq-fixture-pod.json
write_envelope "$RELAY" fatq-fixture-pod.json anna
: > "$RELAY/fatq-fixture-pod.json.read-by-Annadesu_bot"
pod_output="$(run_audit --json)"
jq -e '.counts.consumed == 1 and
  (.consumed[] | select(.task_id == "fixture-pod-recipient" and .expected_marker == "Annadesu_bot"))' \
  <<<"$pod_output" >/dev/null || fail "pod recipient did not resolve to tg_username"
pass "AC4(b) pod name resolves to its tg_username marker"

# AC4(c): non-bot filtering precedes all marker fallback.
reset_fixture
write_task fixture-script-recipient completion_delivery_notified gateway-reply-patrol-scan.json
write_envelope "$RELAY" gateway-reply-patrol-scan.json patrol-scan
: > "$RELAY/gateway-reply-patrol-scan.json.read-by-patrol-scan"
script_output="$(run_audit --json)"
jq -e '.counts.unconsumed == 0 and .counts.undetermined == 1 and
  (.undetermined[] | select(.task_id == "fixture-script-recipient" and
    .reason == "recipient-not-true-bot" and .expected_marker == ""))' <<<"$script_output" >/dev/null \
  || fail "script recipient was not isolated as undetermined"
echo "DISCRIMINATOR non-bot unconsumed=0; mapped-zero-marker-positive-control unconsumed=1"
pass "AC4(c) non-bot remains undetermined even when a same-name marker exists"

# AC5: archived and split-location evidence both retain identity matching.
reset_fixture
write_task fixture-archived reject_notified fatq-fixture-archived.json
write_envelope "$RELAY/read" fatq-fixture-archived.json anna
: > "$RELAY/read/fatq-fixture-archived.json.read-by-Annadesu_bot"
archived_output="$(run_audit --json)"
jq -e '.counts.consumed == 1 and (.consumed[] | select(.task_id == "fixture-archived"))' \
  <<<"$archived_output" >/dev/null || fail "archived evidence was not consumed"
pass "AC5 archived envelope and marker are consumed"

reset_fixture
write_task fixture-split reject_notified fatq-fixture-split.json
write_envelope "$RELAY/read" fatq-fixture-split.json anna
: > "$RELAY/fatq-fixture-split.json.read-by-Annadesu_bot"
split_output="$(run_audit --json)"
jq -e '.counts.consumed == 1 and (.consumed[] | select(.task_id == "fixture-split"))' \
  <<<"$split_output" >/dev/null || fail "split envelope/marker evidence was not consumed"
pass "AC5 read-directory envelope plus top-level marker is consumed"

# Preserve the predecessor review's path-traversal guard as an adversarial regression.
reset_fixture
write_task fixture-unsafe-path reject_notified ../../etc/passwd
unsafe_output="$(run_audit --json)"
jq -e '.counts.unconsumed == 0 and .counts.undetermined == 1 and
  (.undetermined[] | select(.task_id == "fixture-unsafe-path" and
    .relay_file == "../../etc/passwd" and .reason == "relay-file-unsafe"))' \
  <<<"$unsafe_output" >/dev/null || fail "unsafe relay path was not isolated"
pass "adversarial relay path remains undetermined without filesystem traversal"

# --since and threshold behavior remain independent.
reset_fixture
write_task fixture-old reject_notified fatq-fixture-old.json 2026-08-25T19:00:00+08:00
write_envelope "$RELAY" fatq-fixture-old.json anna
write_task fixture-young reject_notified fatq-fixture-young.json 2026-08-27T19:55:00+08:00
write_envelope "$RELAY" fatq-fixture-young.json anna
young_output="$(run_audit --json)"
jq -e '.counts.unconsumed == 1 and .counts.alerting == 0 and
  (.unconsumed[] | select(.task_id == "fixture-young" and .alert == false)) and
  ([.unconsumed[], .consumed[], .undetermined[] | select(.task_id == "fixture-old")] | length == 0)' \
  <<<"$young_output" >/dev/null || fail "since window or threshold behavior is wrong"
set +e
wide_output="$(run_script "$SCRIPT" --since 72 --json 2>&1)"
wide_rc=$?
set -e
[[ "$wide_rc" -eq 1 ]] || fail "72-hour positive control must alert on old fixture"
jq -e '(.unconsumed[] | select(.task_id == "fixture-old" and .alert == true))' \
  <<<"$wide_output" >/dev/null || fail "since exclusion lacks a positive control"
echo "DISCRIMINATOR fixture-old absent-at-24h present-at-72h"
pass "--since window and alert threshold are independently enforced"

# AC6/AC7/AC9: itemized neutral output, with non-zero controls above for every zero assertion.
reset_fixture
write_task fixture-itemized-unconsumed reject_notified fatq-itemized-unconsumed.json
write_envelope "$RELAY" fatq-itemized-unconsumed.json anna
write_task fixture-itemized-undetermined reject_notified gateway-reply-owner.json
write_envelope "$RELAY" gateway-reply-owner.json owner
set +e
human_output="$(run_audit 2>&1)"
human_rc=$?
set -e
[[ "$human_rc" -eq 1 ]] || fail "itemized fixture must alert"
grep -F 'UNCONSUMED task_id=fixture-itemized-unconsumed' <<<"$human_output" >/dev/null \
  || fail "human output omits unconsumed task"
grep -F 'relay_file=fatq-itemized-unconsumed.json' <<<"$human_output" >/dev/null \
  || fail "human output omits unconsumed relay filename"
grep -F 'UNDETERMINED task_id=fixture-itemized-undetermined' <<<"$human_output" >/dev/null \
  || fail "human output omits undetermined task"
grep -F 'relay_file=gateway-reply-owner.json' <<<"$human_output" >/dev/null \
  || fail "human output omits undetermined relay filename"
if grep -E '已送達對方|對方已讀|已確認收到|delivered|recipient-read' <<<"$human_output" >/dev/null; then
  fail "human output overstates consumer-marker semantics"
fi
echo "DISCRIMINATOR itemized unconsumed=1 undetermined=1 (positive controls for zero-count checks)"
pass "AC6/AC7/AC9 output is itemized, neutral, and discriminator-backed"

echo "RESULT: $pass_count passed, 0 failed"

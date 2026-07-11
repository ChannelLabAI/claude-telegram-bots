#!/usr/bin/env bash
# Fixture tests for claim-time spec hash and mid-task spec staleness relay.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="$SCRIPT_DIR/../bin/fatq-cli.sh"
WATCH_SH="$SCRIPT_DIR/../bin/fatq-watch.sh"

TMPROOT=""
TOTAL_PASS=0
TOTAL_FAIL=0
FAIL_NAMES=()

fail() {
  echo "    x $*"
  return 1
}

setup() {
  TMPROOT="$(mktemp -d)"
  export FATQ_ROOT="$TMPROOT/tasks"
  export FATQ_RELAY_DIR="$TMPROOT/relay"
  export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
  export FATQ_VERIFY_SH="$TMPROOT/verify-ok.sh"
  export FATQ_WATCH_LOG="$TMPROOT/fatq-watch.log"
  export FATQ_WATCH_SKIP_INITIAL_DISPATCH=1
  export FATQ_WATCH_RUN_ONCE=1
  export FATQ_MATTERMOST_DISABLE=1
  mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending}
  mkdir -p "$FATQ_RELAY_DIR"
  cat > "$FATQ_TEAM_CONFIG" <<'JSON'
{
  "assistants": [{"state_dir": "interns"}],
  "shared_pools": {
    "builder": [{"state_dir": "interns"}],
    "reviewer": [{"state_dir": "bella"}]
  },
  "external_identities": ["anya", "mac-agent"]
}
JSON
  cat > "$FATQ_VERIFY_SH" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FATQ_VERIFY_SH"
}

teardown() {
  rm -rf "$TMPROOT"
}

make_pending_task() {
  local tid="$1"
  jq -n --arg tid "$tid" '{
    task_id: $tid,
    slug: "spec-staleness-fixture",
    status: "pending",
    assigned: "interns",
    reviewer: "bella",
    goal: "original goal",
    context: "original context",
    acceptance_criteria: ["original acceptance"],
    deliverables: ["original deliverable"],
    out_of_scope: ["original out of scope"],
    history: []
  }' > "$FATQ_ROOT/pending/${tid}.json"
}

relay_count() {
  find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

test_claim_context_change_notifies() {
  local tid="20260711-0000-stal-t1"
  make_pending_task "$tid"

  bash "$CLI_SH" claim "$tid" --as interns >/dev/null || fail "claim failed" || return 1
  local task_file="$FATQ_ROOT/in_progress/${tid}.json"
  [[ -f "$task_file" ]] || fail "claim did not move task to in_progress" || return 1
  [[ "$(jq '[.history[] | select(.action=="claim" and (.spec_hash // "") != "")] | length' "$task_file")" == "1" ]] || fail "claim did not persist spec_hash on claim history" || return 1

  local tmp
  tmp="$(mktemp "$FATQ_ROOT/in_progress/.edit.XXXXXX")"
  jq '.context = "changed context after claim"' "$task_file" > "$tmp" && mv -f "$tmp" "$task_file"

  bash "$WATCH_SH" >/dev/null || fail "watch run-once failed" || return 1
  [[ "$(relay_count)" == "1" ]] || fail "spec change should create exactly one relay, got $(relay_count)" || return 1

  local relay_file
  relay_file="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -type f -name '*.json' | head -1)"
  [[ "$(jq -r '.from_bot' "$relay_file")" == "fatq-watch" ]] || fail "relay from_bot should be fatq-watch" || return 1
  [[ "$(jq -r '.recipient' "$relay_file")" == "interns" ]] || fail "relay recipient should be assignee interns" || return 1
  [[ "$(jq -r '.fatq_task_id' "$relay_file")" == "$tid" ]] || fail "relay fatq_task_id mismatch" || return 1
  jq -e '.text | contains("context")' "$relay_file" >/dev/null || fail "relay text should include changed field context" || return 1
  [[ "$(jq '[.history[] | select(.action=="spec_staleness_notified")] | length' "$task_file")" == "1" ]] || fail "task history should record notification for dedupe" || return 1

  bash "$WATCH_SH" >/dev/null || fail "second watch run-once failed" || return 1
  [[ "$(relay_count)" == "1" ]] || fail "same spec hash should not notify twice" || return 1
  return 0
}

test_history_only_append_is_silent() {
  local tid="20260711-0000-stal-t2"
  make_pending_task "$tid"
  bash "$CLI_SH" claim "$tid" --as interns >/dev/null || fail "claim failed" || return 1
  local task_file="$FATQ_ROOT/in_progress/${tid}.json"
  local before_count tmp
  before_count="$(relay_count)"
  tmp="$(mktemp "$FATQ_ROOT/in_progress/.edit.XXXXXX")"
  jq '.history += [{"ts":"2026-07-11T00:00:00+08:00","by":"anya","action":"comment","text":"history only"}]' "$task_file" > "$tmp" && mv -f "$tmp" "$task_file"
  bash "$WATCH_SH" >/dev/null || fail "watch run-once failed" || return 1
  [[ "$(relay_count)" == "$before_count" ]] || fail "history-only append must not create relay" || return 1
  return 0
}

run_test() {
  local name="$1"
  setup
  echo "-- $name --"
  if "test_$name"; then
    echo "  PASS $name"
    TOTAL_PASS=$((TOTAL_PASS+1))
  else
    echo "  FAIL $name"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAIL_NAMES+=("$name")
  fi
  teardown
}

for t in claim_context_change_notifies history_only_append_is_silent; do
  run_test "$t"
done

echo "[fatq-spec-staleness-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-spec-staleness-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
exit 0

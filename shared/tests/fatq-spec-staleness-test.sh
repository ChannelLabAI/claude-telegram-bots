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

# Real filesystem timing regression for the post-3357 ghost shape:
# fatq-watch has rendered its history write, then submit tries to move the task.
# The stable cross-state lock must serialize both operations, leaving only the
# review copy with both history entries. The old inode lock recreates an
# in_progress ghost after submit.
test_watch_submit_race_has_no_ghost() {
  local tid="20260724-1852-stal-race"
  make_pending_task "$tid"
  bash "$CLI_SH" claim "$tid" --as interns >/dev/null || fail "claim failed" || return 1
  local task_file="$FATQ_ROOT/in_progress/${tid}.json"
  local tmp
  tmp="$(mktemp "$FATQ_ROOT/in_progress/.edit.XXXXXX")"
  jq '.context = "changed before concurrent submit"' "$task_file" > "$tmp" &&
    mv -f "$tmp" "$task_file"

  local real_jq wrapper_dir ready release watch_pid submit_pid watch_rc submit_rc
  real_jq="$(command -v jq)"
  wrapper_dir="$TMPROOT/jq-wrapper"
  ready="$TMPROOT/watch-jq-ready"
  release="$TMPROOT/watch-jq-release"
  mkdir -p "$wrapper_dir"
  sed \
    -e "s|__REAL_JQ__|$real_jq|g" \
    -e "s|__READY__|$ready|g" \
    -e "s|__RELEASE__|$release|g" \
    > "$wrapper_dir/jq" <<'JQWRAP'
#!/usr/bin/env bash
set -e
if [[ " $* " == *'.history = ((.history // []) + [$entry])'* ]]; then
  "__REAL_JQ__" "$@"
  touch "__READY__"
  while [[ ! -e "__RELEASE__" ]]; do sleep 0.01; done
  exit 0
fi
exec "__REAL_JQ__" "$@"
JQWRAP
  chmod +x "$wrapper_dir/jq"

  ( PATH="$wrapper_dir:$PATH" bash "$WATCH_SH" >"$TMPROOT/watch-race.log" 2>&1 ) &
  watch_pid=$!
  local waits=0
  while [[ ! -e "$ready" && "$waits" -lt 500 ]]; do
    sleep 0.01
    waits=$((waits+1))
  done
  [[ -e "$ready" ]] || {
    kill "$watch_pid" 2>/dev/null || true
    fail "watch did not reach read-to-temp barrier"
    return 1
  }

  ( bash "$CLI_SH" submit "$tid" --as interns >"$TMPROOT/submit-race.log" 2>&1 ) &
  submit_pid=$!
  local review_file="$FATQ_ROOT/review/${tid}.json"
  waits=0
  while [[ ! -e "$review_file" && "$waits" -lt 200 ]]; do
    sleep 0.01
    waits=$((waits+1))
  done
  [[ ! -e "$review_file" && -f "$task_file" ]] || {
    touch "$release"
    wait "$watch_pid" 2>/dev/null || true
    wait "$submit_pid" 2>/dev/null || true
    fail "submit bypassed the stable watch lock"
    return 1
  }

  touch "$release"
  wait "$watch_pid"; watch_rc=$?
  wait "$submit_pid"; submit_rc=$?
  [[ "$watch_rc" -eq 0 ]] || fail "watch exited $watch_rc" || return 1
  [[ "$submit_rc" -eq 0 ]] || fail "submit exited $submit_rc" || return 1
  [[ ! -e "$task_file" ]] || fail "stale in_progress ghost was recreated" || return 1

  [[ -f "$review_file" ]] || fail "review task missing" || return 1
  [[ "$(jq '[.history[] | select(.action=="spec_staleness_notified")] | length' "$review_file")" == "1" ]] ||
    fail "review task lost spec_staleness_notified" || return 1
  [[ "$(jq '[.history[] | select(.action=="submit")] | length' "$review_file")" == "1" ]] ||
    fail "review task lost submit history" || return 1
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

for t in claim_context_change_notifies history_only_append_is_silent watch_submit_race_has_no_ghost; do
  run_test "$t"
done

echo "[fatq-spec-staleness-test] RESULT: ${TOTAL_PASS} pass, ${TOTAL_FAIL} fail"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "[fatq-spec-staleness-test] FAILED: ${FAIL_NAMES[*]}"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Functional regression fixture for the §12 precompact backup/inject hooks.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PRECOMPACT_HOOK="${SECTION12_PRECOMPACT_HOOK:-$REPO_ROOT/shared/hooks/section12-precompact-backup.sh}"
INJECT_HOOK="${SECTION12_INJECT_HOOK:-$REPO_ROOT/shared/hooks/section12-inject.sh}"
PRODUCTION_BOTS_ROOT="${SECTION12_PRODUCTION_BOTS_ROOT:-/home/oldrabbit/.claude-bots/bots}"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
BOT_NAME="fixture-assistant"
BOT_CWD="$TEST_HOME/.claude-bots/bots/$BOT_NAME"
BACKUP_DIR="$TEST_HOME/.claude-bots/state/_compact_backup/$BOT_NAME"
LOG_DIR="$TEST_HOME/.claude-bots/logs/section12"
TRANSCRIPT_DIR="$TEST_ROOT/transcripts"
mkdir -p "$BOT_CWD" "$TRANSCRIPT_DIR"
printf '# fixture\n\n- **§12 Proactive Compact**: ✅ 適用（test）\n' > "$BOT_CWD/CLAUDE.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -s "$1" ]] || fail "expected non-empty file: $1"
}

make_transcript() {
  local path="$1" target_bytes="$2"
  python3 - "$path" "$target_bytes" <<'PY'
import json
import sys

path, target = sys.argv[1], int(sys.argv[2])
base = {"type": "user", "message": {"role": "user", "content": ""}}
empty = (json.dumps(base, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
if len(empty) > target:
    raise SystemExit(f"target {target} is smaller than fixture envelope {len(empty)}")
base["message"]["content"] = "x" * (target - len(empty))
payload = (json.dumps(base, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
if len(payload) != target:
    raise SystemExit(f"fixture size mismatch: expected {target}, got {len(payload)}")
with open(path, "wb") as handle:
    handle.write(payload)
PY
}

run_precompact() {
  local transcript="$1" session_id="$2" bot_cwd="${3:-$BOT_CWD}" input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg cwd "$bot_cwd" \
    --arg transcript "$transcript" \
    '{session_id:$sid,cwd:$cwd,transcript_path:$transcript}')
  HOME="$TEST_HOME" "$PRECOMPACT_HOOK" <<< "$input"
}

run_inject() {
  local session_id="$1" bot_cwd="${2:-$BOT_CWD}" input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg cwd "$bot_cwd" \
    '{session_id:$sid,cwd:$cwd,source:"compact"}')
  HOME="$TEST_HOME" "$INJECT_HOOK" <<< "$input"
}

SMALL_TRANSCRIPT="$TRANSCRIPT_DIR/small.jsonl"
BOUNDARY_TRANSCRIPT="$TRANSCRIPT_DIR/boundary.jsonl"
LARGE_TRANSCRIPT="$TRANSCRIPT_DIR/large.jsonl"
make_transcript "$SMALL_TRANSCRIPT" 499999
make_transcript "$BOUNDARY_TRANSCRIPT" 500000
make_transcript "$LARGE_TRANSCRIPT" 500001

exercise_gate() {
  local bot_name="$1" source_claude="$2" expected="$3"
  local mirror_cwd="$TEST_HOME/.claude-bots/bots/$bot_name"
  local bot_backup_dir="$TEST_HOME/.claude-bots/state/_compact_backup/$bot_name"
  local precompact_result inject_result inject_output

  [[ -f "$source_claude" ]] || fail "missing production CLAUDE.md: $source_claude"
  mkdir -p "$mirror_cwd"
  ln -s "$source_claude" "$mirror_cwd/CLAUDE.md"

  run_precompact "$BOUNDARY_TRANSCRIPT" "gate-$bot_name" "$mirror_cwd"
  if [[ -s "$bot_backup_dir/gate-$bot_name.json" ]]; then
    precompact_result="APPLY"
  else
    precompact_result="SKIP"
  fi

  rm -rf "$bot_backup_dir"
  mkdir -p "$bot_backup_dir"
  printf '{"must_keep":{"3_owner_last_cmd":"gate probe"}}\n' \
    > "$bot_backup_dir/inject-probe.json"
  inject_output=$(run_inject "inject-$bot_name" "$mirror_cwd")
  if [[ -n "$inject_output" ]]; then
    inject_result="APPLY"
  else
    inject_result="SKIP"
  fi

  echo "GATE bot=$bot_name precompact=$precompact_result inject=$inject_result expected=$expected source=$source_claude"
  [[ "$precompact_result" == "$expected" ]] \
    || fail "$bot_name precompact gate: expected $expected, got $precompact_result"
  [[ "$inject_result" == "$expected" ]] \
    || fail "$bot_name inject gate: expected $expected, got $inject_result"

  rm -rf "$bot_backup_dir"
  rm -f "$mirror_cwd/CLAUDE.md"
}

echo "PRODUCTION-GATE-BEGIN root=$PRODUCTION_BOTS_ROOT"
for bot_name in anya panda zhanglinghe elon zhuchu fengfeng huizhang buddy; do
  exercise_gate "$bot_name" "$PRODUCTION_BOTS_ROOT/$bot_name/CLAUDE.md" APPLY
done
for bot_name in anna yitang kk eric sancai twinkle orange; do
  exercise_gate "$bot_name" "$PRODUCTION_BOTS_ROOT/$bot_name/CLAUDE.md" SKIP
done
echo "PRODUCTION-GATE-END apply=8 skip=7"

POSITIVE_MARKER="$TEST_ROOT/constructed-positive.md"
NEGATIVE_MARKER="$TEST_ROOT/constructed-negative.md"
printf '%s\n' '- **§12 Proactive Compact with intervening text**: ✅ 適用' \
  > "$POSITIVE_MARKER"
printf '%s\n' '- **§12 Proactive Compact**: ❌ 不適用' \
  > "$NEGATIVE_MARKER"
exercise_gate constructed-positive "$POSITIVE_MARKER" APPLY
exercise_gate constructed-negative "$NEGATIVE_MARKER" SKIP
echo "PASS: constructed ✅ marker with intervening text applied; ❌ 不適用 marker skipped"

# Keep the original size/age assertions independent from the gate probes above.
rm -rf "$LOG_DIR"

run_precompact "$SMALL_TRANSCRIPT" "small-session"
[[ ! -e "$BACKUP_DIR/small-session.json" ]] \
  || fail "transcript below 500000 bytes produced a backup"
[[ ! -e "$LOG_DIR/backups.jsonl" ]] \
  || fail "transcript below 500000 bytes produced a backup log"
echo "PASS: 499999-byte transcript skipped"

run_precompact "$BOUNDARY_TRANSCRIPT" "boundary-session"
assert_file "$BACKUP_DIR/boundary-session.json"
jq -e '.meta.transcript_bytes == 500000' "$BACKUP_DIR/boundary-session.json" >/dev/null \
  || fail "500000-byte boundary was not preserved"
echo "PASS: 500000-byte transcript backed up"

run_precompact "$LARGE_TRANSCRIPT" "large-session"
LARGE_BACKUP="$BACKUP_DIR/large-session.json"
assert_file "$LARGE_BACKUP"
jq -e '
  .meta.transcript_bytes == 500001
  and (.must_keep | keys == [
    "1_task_state",
    "2_subagent_index",
    "3_owner_last_cmd",
    "4_recent_dialogue",
    "5_half_finished",
    "6_agent_memo"
  ])
' "$LARGE_BACKUP" >/dev/null || fail "large backup content or Must-Keep 6 changed"
jq -e 'select(.event == "precompact_snapshot" and .session == "large-session" and .transcript_bytes == 500001)' \
  "$LOG_DIR/backups.jsonl" >/dev/null || fail "large backup log entry missing"
echo "PASS: 500001-byte transcript produced backup and log"

rm -f "$BACKUP_DIR/boundary-session.json"
INJECT_OUTPUT=$(run_inject "fresh-inject-session")
jq -e '.hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | contains("§12 Compact 後恢復"))' \
  <<< "$INJECT_OUTPUT" >/dev/null || fail "fresh backup was not injected"
assert_file "$BACKUP_DIR/consumed/large-session.json"
jq -e 'select(.event == "inject" and .session == "fresh-inject-session")' \
  "$LOG_DIR/injects.jsonl" >/dev/null || fail "fresh inject log entry missing"
echo "PASS: backup newer than 86400 seconds injected"

OLD_BACKUP="$BACKUP_DIR/old-session.json"
cp "$BACKUP_DIR/consumed/large-session.json" "$OLD_BACKUP"
touch -d '2 days ago' "$OLD_BACKUP"
INJECT_LOG_LINES_BEFORE=$(wc -l < "$LOG_DIR/injects.jsonl")
OLD_OUTPUT=$(run_inject "stale-inject-session")
[[ -z "$OLD_OUTPUT" ]] || fail "backup older than 86400 seconds was injected"
assert_file "$OLD_BACKUP"
[[ "$(wc -l < "$LOG_DIR/injects.jsonl")" -eq "$INJECT_LOG_LINES_BEFORE" ]] \
  || fail "stale backup produced an inject log"
echo "PASS: backup older than 86400 seconds skipped"

FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 73\n' > "$FAKE_BIN/stat"
chmod +x "$FAKE_BIN/stat"

set +e
PRECOMPACT_INPUT=$(jq -nc \
  --arg sid "stat-error-session" \
  --arg cwd "$BOT_CWD" \
  --arg transcript "$LARGE_TRANSCRIPT" \
  '{session_id:$sid,cwd:$cwd,transcript_path:$transcript}')
PRECOMPACT_ERROR=$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" "$PRECOMPACT_HOOK" \
  <<< "$PRECOMPACT_INPUT" 2>&1)
PRECOMPACT_RC=$?
set -e
[[ "$PRECOMPACT_RC" -ne 0 ]] || fail "precompact stat failure was hidden"
grep -Fq 'ERROR: failed to read transcript size' <<< "$PRECOMPACT_ERROR" \
  || fail "precompact stat failure was not visible"
echo "PASS: precompact stat failure is visible and non-zero"

rm -f "$OLD_BACKUP"
cp "$BACKUP_DIR/consumed/large-session.json" "$BACKUP_DIR/stat-error-backup.json"
set +e
INJECT_INPUT=$(jq -nc \
  --arg sid "inject-stat-error-session" \
  --arg cwd "$BOT_CWD" \
  '{session_id:$sid,cwd:$cwd,source:"compact"}')
INJECT_ERROR=$(HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" "$INJECT_HOOK" \
  <<< "$INJECT_INPUT" 2>&1)
INJECT_RC=$?
set -e
[[ "$INJECT_RC" -ne 0 ]] || fail "inject stat failure was hidden"
grep -Fq 'ERROR: failed to read backup mtime' <<< "$INJECT_ERROR" \
  || fail "inject stat failure was not visible"
echo "PASS: inject stat failure is visible and non-zero"

echo "PASS: section12 hook regression fixture"

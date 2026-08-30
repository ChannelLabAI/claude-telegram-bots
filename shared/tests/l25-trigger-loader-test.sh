#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$REPO_ROOT/shared/hooks/l25-trigger-loader.sh"
AUDIT="$REPO_ROOT/shared/bin/l25-load-audit.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

ROOT="$FIXTURE/home/.claude-bots"
BOT_DIR="$ROOT/bots/testbot"
BLOCKS="$BOT_DIR/blocks"
LOG="$ROOT/logs/l25-trigger.jsonl"
mkdir -p "$BLOCKS" "$ROOT/shared/lib"
cp "$REPO_ROOT/shared/lib/generate-manifest.py" "$ROOT/shared/lib/generate-manifest.py"

cat > "$BLOCKS/block-high.md" <<'EOF'
---
triggers: ["always high"]
priority: high
size_tokens: 10
---
# High block
FIRST_HIGH_CONTEXT
EOF

cat > "$BLOCKS/block-daily-cron.md" <<'EOF'
---
triggers: ["daily cron"]
priority: medium
size_tokens: 10
---
# Daily cron
FIRST_DYNAMIC_CONTEXT
EOF

run_hook() {
    local payload="$1"
    HOME="$FIXTURE/home" L25_LOG_PATH="$LOG" "$HOOK" <<<"$payload"
}

session_start_a=$(run_hook '{"hook_event_name":"SessionStart","session_id":"session-A","cwd":"'"$BOT_DIR"'"}')
first_dynamic=$(run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"session-A","cwd":"'"$BOT_DIR"'","prompt":"please check daily cron"}')
second_dynamic=$(run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"session-A","cwd":"'"$BOT_DIR"'","prompt":"daily cron again"}')
duplicate_start=$(run_hook '{"hook_event_name":"SessionStart","session_id":"session-A","cwd":"'"$BOT_DIR"'"}')
new_session=$(run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"session-B","cwd":"'"$BOT_DIR"'","prompt":"daily cron in a new session"}')

# Two simultaneous events for one fresh session must produce exactly one
# injection. This exercises the lock, not only the sequential fast path.
run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"session-C","cwd":"'"$BOT_DIR"'","prompt":"daily cron concurrently"}' > "$FIXTURE/concurrent-1.out" &
pid_one=$!
run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"session-C","cwd":"'"$BOT_DIR"'","prompt":"daily cron concurrently"}' > "$FIXTURE/concurrent-2.out" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"

grep -Fq 'FIRST_HIGH_CONTEXT' <<<"$session_start_a"
grep -Fq 'FIRST_DYNAMIC_CONTEXT' <<<"$first_dynamic"
[[ -z "$second_dynamic" ]]
[[ -z "$duplicate_start" ]]
grep -Fq 'FIRST_DYNAMIC_CONTEXT' <<<"$new_session"

[[ $(jq -s '[.[] | select(.block == "block-daily-cron.md" and .session_id == "session-A" and .first_in_session == true and .injected == true)] | length' "$LOG") -eq 1 ]]
[[ $(jq -s '[.[] | select(.block == "block-daily-cron.md" and .session_id == "session-A" and .first_in_session == false and .injected == false)] | length' "$LOG") -eq 1 ]]
[[ $(jq -s '[.[] | select(.block == "block-daily-cron.md" and .session_id == "session-B" and .first_in_session == true and .injected == true)] | length' "$LOG") -eq 1 ]]
[[ $(jq -s '[.[] | select(.block == "block-high.md" and .session_id == "session-A" and .first_in_session == false)] | length' "$LOG") -eq 1 ]]
[[ $(grep -l 'FIRST_DYNAMIC_CONTEXT' "$FIXTURE"/concurrent-*.out | wc -l) -eq 1 ]]
[[ $(jq -s '[.[] | select(.block == "block-daily-cron.md" and .session_id == "session-C" and .first_in_session == true)] | length' "$LOG") -eq 1 ]]
[[ $(jq -s '[.[] | select(.block == "block-daily-cron.md" and .session_id == "session-C" and .first_in_session == false)] | length' "$LOG") -eq 1 ]]

audit_output=$("$AUDIT" --log "$LOG" --sort count)
grep -Fq $'block\tloads\tcumulative_bytes\tdedup_hits\tdedup_saved_bytes\tattempts' <<<"$audit_output"
daily_row=$(awk -F '\t' '$1 == "block-daily-cron.md" {print}' <<<"$audit_output")
[[ $(cut -f2 <<<"$daily_row") -eq 3 ]]
[[ $(cut -f4 <<<"$daily_row") -eq 2 ]]

printf 'FIRST_INJECTION_OUTPUT=%s\n' "$first_dynamic"
printf 'SECOND_SAME_SESSION_OUTPUT=%s\n' "${second_dynamic:-<empty: deduplicated>}"
printf 'NEW_SESSION_FIRST_OUTPUT=%s\n' "$new_session"
printf 'JSONL_SAMPLE\n'
head -n 5 "$LOG"
printf 'AUDIT_OUTPUT\n%s\n' "$audit_output"
if [[ -n "${L25_TEST_ARTIFACT_DIR:-}" ]]; then
    mkdir -p "$L25_TEST_ARTIFACT_DIR"
    cp "$LOG" "$L25_TEST_ARTIFACT_DIR/l25-trigger.jsonl"
    printf '%s\n' "$first_dynamic" > "$L25_TEST_ARTIFACT_DIR/first-injection.out"
    printf '%s\n' "${second_dynamic:-<empty: deduplicated>}" > "$L25_TEST_ARTIFACT_DIR/second-same-session.out"
    printf '%s\n' "$new_session" > "$L25_TEST_ARTIFACT_DIR/new-session-first.out"
    printf '%s\n' "$audit_output" > "$L25_TEST_ARTIFACT_DIR/audit-output.tsv"
fi
printf 'PASS: first injects, duplicate deduplicates, duplicate SessionStart stays deduplicated, concurrent duplicate locks, new session injects\n'

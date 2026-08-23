#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/../bin/probe-pinned-files.sh"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    fail=$((fail + 1))
  fi
}

mkdir -p "$FIXTURE_ROOT/tasks/done" "$FIXTURE_ROOT/tasks/cancelled" "$FIXTURE_ROOT/tasks/archived"

cat > "$FIXTURE_ROOT/tasks/done/closed.json" <<'JSON'
{
  "task_id": "closed-task",
  "closeout": {
    "state": "closed",
    "host_effect_proof": {
      "commands": [{"cmd": ["bash", "/home/oldrabbit/.claude-bots/shared/tests/closed-proof.sh"]}]
    }
  },
  "verify_commands": [{"cmd": ["bash", "shared/tests/closed-verify.sh"]}],
  "live_verify_commands": [{"cmd": ["bash", "/home/oldrabbit/.claude-bots/shared/bin/closed-live.sh"]}]
}
JSON

cat > "$FIXTURE_ROOT/tasks/cancelled/cancelled.json" <<'JSON'
{
  "task_id": "cancelled-task",
  "verify_commands": [{"cmd": ["bash", "shared/tests/cancelled-check.sh"]}],
  "live_verify_commands": []
}
JSON

cat > "$FIXTURE_ROOT/tasks/archived/unrelated.json" <<'JSON'
{
  "task_id": "archived-unrelated",
  "verify_commands": [{"cmd": ["test", "-f", "/tmp/not-a-repository-file"]}, {"cmd": ["bash", "/tmp/worktree/shared/bin/not-canonical.sh"]}],
  "live_verify_commands": []
}
JSON

all_output="$(PROBE_PINNED_TASKS_ROOT="$FIXTURE_ROOT/tasks" "$PROBE")"
closed_output="$(PROBE_PINNED_TASKS_ROOT="$FIXTURE_ROOT/tasks" "$PROBE" closed-live.sh)"
proof_output="$(PROBE_PINNED_TASKS_ROOT="$FIXTURE_ROOT/tasks" "$PROBE" shared/tests/closed-proof.sh)"
cancelled_output="$(PROBE_PINNED_TASKS_ROOT="$FIXTURE_ROOT/tasks" "$PROBE" cancelled-check.sh)"
missing_output="$(PROBE_PINNED_TASKS_ROOT="$FIXTURE_ROOT/tasks" "$PROBE" definitely-not-pinned.sh)"

check known_pinned_file grep -Fq $'PINNED\tshared/bin/closed-live.sh\tclosed-task\tlive_verify_commands' <<< "$all_output"
check closed_task_included grep -Fq $'PINNED\tshared/tests/closed-verify.sh\tclosed-task\tverify_commands' <<< "$all_output"
check host_effect_proof_field grep -Fq $'PINNED\tshared/tests/closed-proof.sh\tclosed-task\tcloseout.host_effect_proof.commands' <<< "$proof_output"
check filename_query grep -Fq $'PINNED\tshared/bin/closed-live.sh\tclosed-task\tlive_verify_commands' <<< "$closed_output"
check cancelled_directory_scanned grep -Fq $'PINNED\tshared/tests/cancelled-check.sh\tcancelled-task\tverify_commands' <<< "$cancelled_output"
check unpinned_not_reported grep -Fq $'NOT_PINNED\tdefinitely-not-pinned.sh' <<< "$missing_output"
check no_false_positive bash -c '! grep -Fq not-a-repository-file <<< "$1"' _ "$all_output"
check worktree_path_not_canonical bash -c '! grep -Fq not-canonical.sh <<< "$1"' _ "$all_output"

echo "RESULT: $pass pass, $fail fail"
[[ $fail -eq 0 ]]

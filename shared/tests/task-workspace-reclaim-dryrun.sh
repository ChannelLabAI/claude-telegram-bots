#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$BASE/bin/task-workspace-reclaimer.py"
ROOT="$(mktemp -d /tmp/task-workspace-reclaimer-fixture.XXXXXX)"
HELPER="$ROOT/shared/bin/clone-reclaim-safety.py"
trap 'rm -rf -- "$ROOT"' EXIT
mkdir -p "$ROOT/tasks/done" "$ROOT/tasks/work" "$ROOT/tasks/worktrees" "$ROOT/shared/bin"
cp "$BASE/bin/clone-reclaim-safety.py" "$HELPER"

task() { printf '{"task_id":"%s","status":"done"}\n' "$1" > "$ROOT/tasks/done/$1.json"; }
git init -q "$ROOT/source"
git -C "$ROOT/source" config user.name fixture
git -C "$ROOT/source" config user.email fixture@example.test
printf 'base\n' > "$ROOT/source/file.txt"
git -C "$ROOT/source" add file.txt && git -C "$ROOT/source" commit -qm base

SAFE=20260808-0000-aa01-safe-workspace
UNIQUE=20260808-0000-bb02-unique-workspace
APPLY=20260808-0000-cc03-apply-workspace
task "$SAFE"; task "$UNIQUE"; task "$APPLY"
git clone -q "$ROOT/source" "$ROOT/tasks/work/$SAFE"
git clone -q "$ROOT/source" "$ROOT/tasks/worktrees/$UNIQUE"
git clone -q "$ROOT/source" "$ROOT/tasks/work/$APPLY"
git -C "$ROOT/tasks/worktrees/$UNIQUE" config user.name fixture
git -C "$ROOT/tasks/worktrees/$UNIQUE" config user.email fixture@example.test
printf 'unique\n' > "$ROOT/tasks/worktrees/$UNIQUE/unique.txt"
git -C "$ROOT/tasks/worktrees/$UNIQUE" add unique.txt && git -C "$ROOT/tasks/worktrees/$UNIQUE" commit -qm unique

python3 "$SCRIPT" --root "$ROOT" --safety-helper "$HELPER" --source "$ROOT/source" --log-file "$ROOT/dry.jsonl" > "$ROOT/dry.out"
test -d "$ROOT/tasks/work/$SAFE" # dry-run never deletes
test -d "$ROOT/tasks/worktrees/$UNIQUE"
grep -F '"task_id": "20260808-0000-aa01-safe-workspace"' "$ROOT/dry.out" | grep -F '"action": "reclaimable"' >/dev/null
grep -F '"task_id": "20260808-0000-bb02-unique-workspace"' "$ROOT/dry.out" | grep -F '"reason": "unconfirmed_unpushed_commit"' >/dev/null

python3 "$SCRIPT" --root "$ROOT" --apply --safety-helper "$HELPER" --source "$ROOT/source" --log-file "$ROOT/apply.jsonl" > "$ROOT/apply.out"
test ! -e "$ROOT/tasks/work/$SAFE"
test ! -e "$ROOT/tasks/work/$APPLY"
test -d "$ROOT/tasks/worktrees/$UNIQUE" # unique done workspace is protected
echo 'PASS task-workspace-reclaimer fixture'

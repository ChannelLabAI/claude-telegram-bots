#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d /tmp/clone-ttl-fixture.XXXXXX)"
LOG="$ROOT/result.jsonl"
trap 'kill "${HOLDER:-}" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
for d in old-freshclone dirty-review active-review new-freshclone plain-old; do mkdir "$ROOT/$d"; done
git -C "$ROOT/old-freshclone" init -q
git -C "$ROOT/dirty-review" init -q
git -C "$ROOT/active-review" init -q
git -C "$ROOT/new-freshclone" init -q
touch "$ROOT/dirty-review/uncommitted.txt"
touch -d '2 days ago' "$ROOT/old-freshclone" "$ROOT/dirty-review" "$ROOT/active-review" "$ROOT/plain-old"
( cd "$ROOT/active-review"; exec sleep 30 ) & HOLDER=$!
CLONE_TTL_LOG_FILE="$LOG" "$BASE/bin/clone-ttl-cleaner.sh" --dry-run --root "$ROOT" --ttl-hours 24 > "$ROOT/dry.out"
test -d "$ROOT/old-freshclone" && test -d "$ROOT/active-review" && test -d "$ROOT/plain-old"
jq -se 'any(.[]; .action=="would_remove" and (.path|endswith("old-freshclone")))' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("dirty-review")) and .reason=="git_dirty")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="skipped_active" and (.path|endswith("active-review")) and .reason=="cwd_or_fd_held")' "$LOG" >/dev/null
jq -se 'any(.[]; .mode=="dry_run" and .eligible==1 and .needs_review==1 and .skipped_active==1)' "$LOG" >/dev/null
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
CLONE_TTL_LOG_FILE="$LOG" "$BASE/bin/clone-ttl-cleaner.sh" --apply --root "$ROOT" --ttl-hours 24 > "$ROOT/apply.out"
test ! -e "$ROOT/old-freshclone" && test ! -e "$ROOT/active-review" && test -d "$ROOT/dirty-review" && test -d "$ROOT/plain-old" && test -d "$ROOT/new-freshclone"
CLONE_TTL_LOG_FILE="$LOG" "$BASE/bin/clone-ttl-cleaner.sh" --apply --force-dirty --root "$ROOT" --ttl-hours 24 > "$ROOT/force.out"
test ! -e "$ROOT/dirty-review"
echo 'PASS clone TTL cleaner fixture: dry-run, active cwd and dirty-worktree protection, force-dirty, Git/name scope, apply cleanup'

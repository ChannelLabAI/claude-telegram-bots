#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d /tmp/clone-ttl-fixture.XXXXXX)"
SCAN="$ROOT/scan"
TASKS="$ROOT/tasks"
LOG="$ROOT/result.jsonl"
HELPER="$BASE/bin/clone-reclaim-safety.py"
HOLDER=""
HOLDER_FD=""
trap 'kill "${HOLDER:-}" "${HOLDER_FD:-}" 2>/dev/null || true; [[ "${CLONE_TTL_FIXTURE_KEEP_ROOT:-0}" == 1 ]] || rm -rf "$ROOT"' EXIT
mkdir -p "$SCAN" "$TASKS/pending" "$TASKS/in_progress" "$TASKS/review"

init_source() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.test
  printf 'alpha\nbeta\n' > "$repo/safety.txt"
  git -C "$repo" add safety.txt
  git -C "$repo" commit -qm baseline
  printf 'landed-review-line\n' >> "$repo/safety.txt"
  git -C "$repo" add safety.txt
  git -C "$repo" commit -qm landed
}

for repo in root pod-system mvp; do init_source "$ROOT/$repo"; done
export CLONE_TTL_SOURCE_REPOS="$ROOT/root:$ROOT/pod-system:$ROOT/mvp"
export CLONE_TTL_TASKS_ROOT="$TASKS"
export CLONE_TTL_ALLOW_NON_TMP=1

make_landed_dirty() {
  local name="$1" source="${2:-$ROOT/root}" target
  target="$SCAN/$name"
  git clone -q "$source" "$target"
  git -C "$target" reset -q --hard HEAD^
  cp "$source/safety.txt" "$target/safety.txt"
  touch -d '2 days ago' "$target"
}

# Exact reconstruction names from the 11-item 2438 production evidence.
positive=(
  a3cc-freshclone b2d8-freshclone b2d8-review-clone b6ea-verify
  b6ea-verify-clone bella-verify-3a7d bella-verify-dda6-2775571
  d257-review-clone e63a-repro.A9UnA7 mvp-review pod-system-review-6c0d
)
for name in "${positive[@]}"; do make_landed_dirty "$name"; done

# Negative: an unpushed commit absent from all three source repos.
git clone -q "$ROOT/root" "$SCAN/unpushed-review"
git -C "$SCAN/unpushed-review" config user.name fixture
git -C "$SCAN/unpushed-review" config user.email fixture@example.test
printf 'only copy\n' > "$SCAN/unpushed-review/unique.txt"
git -C "$SCAN/unpushed-review" add unique.txt
git -C "$SCAN/unpushed-review" commit -qm unpushed
touch -d '2 days ago' "$SCAN/unpushed-review"

# Negative: deletion-only and pure reorder must never pass vacuous inclusion.
git clone -q "$ROOT/root" "$SCAN/deletion-review"
sed -i '/^beta$/d' "$SCAN/deletion-review/safety.txt"
touch -d '2 days ago' "$SCAN/deletion-review"
git clone -q "$ROOT/root" "$SCAN/reorder-review"
printf 'beta\nalpha\nlanded-review-line\n' > "$SCAN/reorder-review/safety.txt"
touch -d '2 days ago' "$SCAN/reorder-review"

# Active FATQ state and an active process independently protect eligible trees.
make_landed_dirty aaaa-review
printf '{"task_id":"20260802-0300-aaaa-live-fixture","slug":"live-fixture","status":"review"}\n' > "$TASKS/review/20260802-0300-aaaa-live-fixture.json"
make_landed_dirty held-review
( cd "$SCAN/held-review"; exec sleep 60 ) & HOLDER=$!

# A descriptor below the candidate, rather than its cwd, exercises the
# original target/* branch of the in-use rule.
make_landed_dirty held-fd-review
mkdir -p "$SCAN/held-fd-review/subdir"
printf 'held\n' > "$SCAN/held-fd-review/subdir/file.txt"
touch -d '2 days ago' "$SCAN/held-fd-review"
( exec 9<"$SCAN/held-fd-review/subdir/file.txt"; exec sleep 60 ) & HOLDER_FD=$!

# A candidate can itself be a cleanable repo while containing a separate,
# gitignored worktree. Both repositories must be discovered: the nested
# unpushed commit makes the whole candidate fail closed.
make_landed_dirty nested-repo-review
printf 'tasks/\n' >> "$SCAN/nested-repo-review/.git/info/exclude"
mkdir -p "$SCAN/nested-repo-review/tasks/worktrees/other-task"
git init -q "$SCAN/nested-repo-review/tasks/worktrees/other-task"
git -C "$SCAN/nested-repo-review/tasks/worktrees/other-task" config user.name fixture
git -C "$SCAN/nested-repo-review/tasks/worktrees/other-task" config user.email fixture@example.test
printf 'only nested copy\n' > "$SCAN/nested-repo-review/tasks/worktrees/other-task/unique.txt"
git -C "$SCAN/nested-repo-review/tasks/worktrees/other-task" add unique.txt
git -C "$SCAN/nested-repo-review/tasks/worktrees/other-task" commit -qm unpushed
touch -d '2 days ago' "$SCAN/nested-repo-review"

# A linked worktree is eligible, but this task never invokes --apply. The
# implementation is also checked below for git-worktree-only removal routing.
git -C "$ROOT/root" worktree add -q --detach "$SCAN/registered-review" HEAD^
cp "$ROOT/root/safety.txt" "$SCAN/registered-review/safety.txt"
touch -d '2 days ago' "$SCAN/registered-review"

# Positive second opinion: the candidate tip is absent from its origin source
# but is contained by a branch in a different one of the three source repos.
git clone -q "$ROOT/root" "$SCAN/three-repo-review"
git -C "$SCAN/three-repo-review" config user.name fixture
git -C "$SCAN/three-repo-review" config user.email fixture@example.test
printf 'cross-source proof\n' > "$SCAN/three-repo-review/cross.txt"
git -C "$SCAN/three-repo-review" add cross.txt
git -C "$SCAN/three-repo-review" commit -qm cross-source
git -C "$ROOT/mvp" fetch -q "$SCAN/three-repo-review" HEAD:refs/heads/cross-source-proof
touch -d '2 days ago' "$SCAN/three-repo-review"

make_landed_dirty marked-review
touch "$SCAN/marked-review/.clone-ttl-never-touch"
touch -d '2 days ago' "$SCAN/marked-review"
make_landed_dirty new-review
touch "$SCAN/new-review"

# The production boundary remains fail-closed outside /tmp.
root_guard_rc=0
env -u CLONE_TTL_ALLOW_NON_TMP "$BASE/bin/clone-ttl-cleaner.sh" --dry-run --root "$BASE" > "$ROOT/root-guard.out" 2>&1 || root_guard_rc=$?
test "$root_guard_rc" -eq 2

CLONE_TTL_LOG_FILE="$LOG" "$BASE/bin/clone-ttl-cleaner.sh" --dry-run --root "$SCAN" --ttl-hours 24 > "$ROOT/dry.out"

for name in "${positive[@]}"; do
  jq -se --arg suffix "$name" 'any(.[]; .action=="would_remove" and (.path|endswith($suffix)))' "$LOG" >/dev/null
done
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("unpushed-review")) and .reason=="unconfirmed_unpushed_commit")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("deletion-review")) and .reason=="deletion_only_or_opaque")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("reorder-review")) and .reason=="pure_reorder")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="skipped_active" and (.path|endswith("aaaa-review")) and (.reason|startswith("active_fatq_task:")))' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="skipped_active" and (.path|endswith("held-review")) and .reason=="cwd_or_fd_held")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="skipped_active" and (.path|endswith("held-fd-review")) and .reason=="cwd_or_fd_held")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("nested-repo-review")) and .reason=="source_ambiguous")' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="would_remove" and (.path|endswith("registered-review")))' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="would_remove" and (.path|endswith("three-repo-review")))' "$LOG" >/dev/null
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("marked-review")) and .reason=="never_touch")' "$LOG" >/dev/null
jq -se 'all(.[]; .action!="removed")' "$LOG" >/dev/null
test -d "$SCAN/new-review"

# Legacy --force-dirty is accepted but cannot bypass either safety fuse.
FORCE_LOG="$ROOT/force-dirty-dry-run.jsonl"
CLONE_TTL_LOG_FILE="$FORCE_LOG" "$BASE/bin/clone-ttl-cleaner.sh" --dry-run --force-dirty --root "$SCAN" --ttl-hours 24 > "$ROOT/force-dirty.out"
jq -se 'any(.[]; .action=="needs_review" and (.path|endswith("deletion-review")) and .reason=="deletion_only_or_opaque")' "$FORCE_LOG" >/dev/null
jq -se 'all(.[]; ((.path // "")|endswith("deletion-review")|not) or .action!="would_remove")' "$FORCE_LOG" >/dev/null

# Race: the candidate list already contains z-race-review, but it disappears
# while an earlier candidate is being inspected. The pass must record it and
# continue rather than letting stat/find abort the complete cleaner run.
make_landed_dirty a-race-review
make_landed_dirty z-race-review
RACE_HELPER="$ROOT/race-helper.sh"
RACE_STARTED="$ROOT/race-helper-started"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'if [[ "${1:-}" == "--batch" ]]; then for repo in "${@:2}"; do if [[ "$(basename -- "$repo")" == "a-race-review" ]]; then touch "'$RACE_STARTED'"; sleep 1; break; fi; done; exec "'$HELPER'" "$@"; fi' \
  'if [[ "$(basename "$1")" == "a-race-review" ]]; then touch "'$RACE_STARTED'"; sleep 1; fi' \
  'exec "'$HELPER'" "$@"' > "$RACE_HELPER"
chmod +x "$RACE_HELPER"
(
  while [[ ! -e "$RACE_STARTED" ]]; do sleep 0.01; done
  rm -rf -- "$SCAN/z-race-review"
) & RACE_DELETER=$!
RACE_LOG="$ROOT/race.jsonl"
CLONE_TTL_LOG_FILE="$RACE_LOG" CLONE_TTL_SAFETY_HELPER="$RACE_HELPER" \
  "$BASE/bin/clone-ttl-cleaner.sh" --dry-run --root "$SCAN" --ttl-hours 24 > "$ROOT/race.out"
wait "$RACE_DELETER"
jq -se 'any(.[]; .action=="already_removed" and (.path|endswith("z-race-review")) and .reason=="candidate_disappeared")' "$RACE_LOG" >/dev/null

# Worktree apply routing is structural: linked worktrees use git worktree
# remove; rm -rf exists only in the standalone clone branch. No --apply runs.
grep -F 'git --git-dir="$common_dir" worktree remove --force "$repo"' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'if [[ "$git_dir" != "$common_dir" ]]' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
# One definition and one call establish that /proc is traversed once per run,
# before candidates are evaluated; held-review above proves the equivalent
# in-use decision still skips a directory whose cwd is held by a process.
test "$(grep -c 'build_process_holders' "$BASE/bin/clone-ttl-cleaner.sh")" -eq 2
test "$(grep -c 'for proc in /proc/\[0-9\]\*' "$BASE/bin/clone-ttl-cleaner.sh")" -eq 1
grep -F '"$SAFETY_HELPER" --batch "${BATCH_REPOS[@]}"' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'find "${find_args[@]}" 2>/dev/null' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'retained records deliberately use 0' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'Build its lookup table once' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'base="${entry##*/}"' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null

# Mutation self-proof. Removing only the deletion fuse makes the negative
# assertion fail (non-zero); restoring it is byte-identical.
cp "$HELPER" "$ROOT/helper.original"
cp "$HELPER" "$ROOT/helper.mutant"
sed -i 's/return not additions/return False  # mutation: fuse removed/' "$ROOT/helper.mutant"
chmod +x "$ROOT/helper.mutant"
mutation_rc=0
if "$ROOT/helper.mutant" "$SCAN/deletion-review" >/dev/null; then
  mutation_rc=1
fi
test "$mutation_rc" -ne 0
cp "$ROOT/helper.original" "$ROOT/helper.mutant"
cmp -s "$ROOT/helper.original" "$ROOT/helper.mutant"

echo 'PASS clone lifecycle fixture: 11 positive reconstructions; unpushed/deletion/reorder negatives; active task/process; race disappearance; one /proc scan; three-repo second opinion; NEVER_TOUCH; dry-run only; mutation red and byte-identical restore'

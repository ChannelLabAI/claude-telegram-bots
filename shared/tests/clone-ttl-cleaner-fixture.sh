#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d /tmp/clone-ttl-fixture.XXXXXX)"
SCAN="$ROOT/scan"
TASKS="$ROOT/tasks"
LOG="$ROOT/result.jsonl"
HELPER="$BASE/bin/clone-reclaim-safety.py"
HOLDER=""
trap 'kill "${HOLDER:-}" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
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

# Worktree apply routing is structural: linked worktrees use git worktree
# remove; rm -rf exists only in the standalone clone branch. No --apply runs.
grep -F 'git --git-dir="$common_dir" worktree remove --force "$repo"' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null
grep -F 'if [[ "$git_dir" != "$common_dir" ]]' "$BASE/bin/clone-ttl-cleaner.sh" >/dev/null

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

echo 'PASS clone lifecycle fixture: 11 positive reconstructions; unpushed/deletion/reorder negatives; active task/process; three-repo second opinion; NEVER_TOUCH; dry-run only; mutation red and byte-identical restore'

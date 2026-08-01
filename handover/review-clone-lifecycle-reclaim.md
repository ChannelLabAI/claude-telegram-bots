# Review clone lifecycle: producer-side options

This task changes reclamation eligibility only. It does not implement any
producer or closeout integration.

## Recommendation

Create a separate task for a manifest-backed closeout hook first, then migrate
review creation from full clones to source-repo worktrees. The hook fixes the
lifecycle leak directly; worktrees reduce the cost of any leak that remains.

## Option A — closeout-owned reclamation (recommended first)

At review workspace creation, atomically write a small manifest containing the
FATQ task ID, creator/reviewer, workspace path, repo identity, Git common dir,
creation time, and cleanup state. On a terminal FATQ transition (`done`,
`cancelled`, or `wont_do`), enqueue a cleanup attempt using the same safety
classifier as `clone-ttl-cleaner.sh`.

The hook must never run for `pending`, `in_progress`, `review`, or `rejected`.
It should be idempotent, log every decision, use `git worktree remove` for a
registered worktree, and leave a retryable manifest when process ownership,
unconfirmed commits, deletion-only/reorder diffs, external files, or an
inspection error blocks cleanup. Closeout itself should not fail merely because
cleanup was deferred.

Benefits: binds ownership to the task lifecycle, supplies an exact task ID
instead of guessing from directory names, and gives retries an authoritative
inventory. Cost: every producer must adopt the manifest contract, and the
terminal-transition worker needs a bounded retry/dead-letter policy.

## Option B — shared source objects plus `git worktree`

Replace full local clones with `git worktree add --detach` from one of the three
known source repos. Removal must always be `git worktree remove` followed by an
optional `git worktree prune`; raw `rm` is forbidden. Use a per-task path and
the same manifest from Option A.

Benefits: working trees share objects, so review copies are much smaller and
faster to create. Costs: worktree registrations become shared mutable state;
branch naming and concurrent creation need locking; a missed removal leaves a
registration that must be pruned. This is why switching producers without the
manifest/closeout owner would reduce disk growth but not solve lifecycle.

## Option C — reference clones

`git clone --reference-if-able` can share an object store while retaining clone
semantics. It is less attractive here: alternates create garbage-collection and
source-lifetime coupling, while `--dissociate` restores much of the disk cost.
Use only if a reviewer requires clone isolation that worktrees cannot provide.

## Proposed separate-task acceptance gates

1. Every review workspace has exactly one atomic manifest and terminal owner.
2. Repeated closeout delivery is idempotent.
3. Active/rejected tasks, held processes, unpushed commits, deletion-only or
   reorder changes, and external files all remain untouched.
4. Registered worktrees are removed only through `git worktree remove`; the
   three source repos have zero dangling registrations after the fixture.
5. A crash between task closeout and cleanup leaves a retryable manifest, not
   an untracked workspace.
6. Disk growth is measured for full clone versus worktree over a representative
   review batch before changing the default producer.

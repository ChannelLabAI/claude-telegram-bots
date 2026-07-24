# FATQ task writeback audit (f317)

Audit base: `a27fc2b`. Evidence was collected from the five preserved files in
`tasks/quarantine-ghosts/`; none of those files was changed or deleted.

## Result

`fatq-cli.sh` and `fatq-dispatch.sh` have no task read-modify-write site outside
the stable `${FATQ_ROOT}/.locks/<task-basename>.lock` protocol. The broader
search did find one real missed writer in `fatq-watch.sh`: the spec-staleness
scanner still locked the replaceable task inode. It now uses the same stable
cross-state lock as CLI and dispatch. This watcher defect is real but
independent: it is not the cause of any of the five preserved 7/24 ghosts.

The five preserved ghosts were caused by the dispatch instruction itself.
`fatq-dispatch.sh:1827,1843` told headless workers to perform an atomic `mv` and
append history themselves. Eric's and Sancai's durable Codex session summaries
say they atomically moved 31cb/f9e2, while the resulting entries at
`16:46:31`, `18:29:07`, and `18:37:17` have no `via:"fatq-cli"`. Gateway logs
tie those exact tasks to the dispatched worker turns. The raw one-shot Codex
tool transcript was not retained, so this audit does not invent whether the
worker used an Edit tool or a shell `jq`; the concrete mechanism is the
dispatcher-authored direct-mutation instruction plus the non-CLI transition
artifacts it produced.

That manual temp/move recipe did not acquire
`${FATQ_ROOT}/.locks/<task>.lock`. A concurrent locked dispatcher could still
hold and later replace the pre-transition path, recreating the source-state
file after the worker moved its own snapshot. The ghost is therefore the exact
pre-transition history prefix and later receives an ordinary dispatch/comment
write.

The preventive correction is at the same instruction source:

- pending and rejected relays now name the exact `fatq-cli.sh claim` and
  `fatq-cli.sh submit` commands and explicitly prohibit hand-written JSON or
  direct `mv`;
- the Codex builder discipline block explicitly overrides stale bot-local SOP
  text that still says to use `.tmp` plus `mv`, so prompt precedence cannot
  silently reintroduce the bypass before those generated bot files are
  refreshed;
- active lint now scans `pending`, `in_progress`, `review`, and `rejected` and
  emits `unsafe_non_cli_claim` / `unsafe_non_cli_submit` immediately when a
  worker bypasses the CLI; its installer changes the old daily schedule to
  every two minutes, with the existing flock and defect-fingerprint
  suppression retained;
- the lint fixture proves a valid-create/valid-claim task with a non-CLI submit
  is detected after it reaches `review/`, and statically prevents the unsafe
  dispatcher wording from returning.

## `fatq-dispatch.sh` task write sites

All dispatch-side task mutations reduce to two physical write helpers.

| Lines | Physical mutation | Lock status | Callers / action families | Action |
|---|---|---|---|---|
| 372-424 | `append_history_locked`: jq to temp, inode recheck, temp rename | locked by `task_lock_file_for()` at 389-394 | `dispatch_send`; unmapped-target fallback; creation-gate fallback; infra-gate override; dispatch, escalate, nudge, blocked-stall/auth, unassigned, reject and approval notices | no change |
| 434-477 | `append_history_action_once_locked`: dedupe read + jq/temp/rename | locked by `task_lock_file_for()` at 438-443 | completion closeout, delivery, aggregate, unmapped and seed markers | no change |
| 543-555 | `dispatch_send` | delegates the only task write to `append_history_locked` | all relay-plus-history paths, including `handle_creation_gate_failure` | no change |
| 1278-1295 | `send_completion_leg` | delegates the only task writes to `append_history_action_once_locked` | completion marker recovery and normal completion | no change |
| 1827,1843 | worker transition instructions | previously directed workers to hand-roll history + `mv`, outside the lock | pending and rejected dispatch relays | now require `fatq-cli claim/submit`; direct JSON/`mv` forbidden |

The remaining `jq` calls in dispatch are reads or construct JSON in memory.
Relay, audit-log and state-marker writes are not task JSON writebacks.

## `fatq-cli.sh` task write sites

The stable lock is defined at lines 442-448 and held by `with_task_lock` at
452-475. Every existing-task callback below is invoked through that wrapper.

| Mutation / lines | Stable-lock invocation | Result |
|---|---|---|
| shared claim/submit/verdict transition, 864-904 | 1074, 1125, 1198 | locked |
| reassign, 1262-1296 | 1300 | locked |
| archive, 1360-1402 | 1406 | locked |
| comment, 1451-1473 | 1477 | locked |
| attachment, 1535-1560 | 1564 | locked |
| hold/clear, 1628-1657 | 1661 | locked |
| closeout, 1754-1834 | 1838 | locked |
| update-field, 1941-2000 | 2004 | locked |
| approval request, 2025-2092 | 2096 | locked |
| approval verdict, 2118-2190 | 2194 | locked |
| approval expiry, 2320-2359 | 2363 | locked |
| force-mv, 2584-2629 | 2633 | locked |

`create` writes a new pending task and therefore has no pre-existing task
read-modify-write cycle. Its project roll-up uses the separate project lock.
`query`, `validate`, `list` and lookup helpers are read-only.

## Missed broader writer and fix

`fatq-watch.sh:104-175` is a task history writer. Before this patch it opened
and flocked the current task inode, rendered a temp file, then renamed the temp
over the path. A concurrent CLI submit locks
`${FATQ_ROOT}/.locks/<task>.lock`, not that old inode, so both processes could
proceed and the watcher could recreate `in_progress/<task>.json` after submit.

Fix:

- `fatq-watch.sh:87-93` now derives the same stable cross-state lock file.
- `scan_spec_staleness_file` holds that lock from its first state-dependent
  read through history writeback.
- `fatq-spec-staleness-test.sh` adds a real filesystem barrier: watcher pauses
  after rendering its jq temp, CLI submit starts concurrently, then the test
  asserts only `review/` remains and it contains both
  `spec_staleness_notified` and `submit`.
- The focused fixture is registered in `shared/bin/tests/run-tests.sh`.

## Five preserved ghosts

| Preserved file | First divergence from live task | Concrete attribution |
|---|---|---|
| `20260724-0927-3d0e.pending-ghost-143348.json` | ghost adds pending dispatch at 14:07; live adds non-CLI claim at 09:27:54 | Eric followed the pending relay's direct-move instruction; the unlocked transition raced a locked dispatch, which later replaced the retained pending path |
| `20260724-1645-31cb.pending-ghost-172519.json` | live adds non-CLI claim at 16:46:31; ghost later receives two CLI comments and pending dispatches | Eric followed the same pending relay instruction; pending-first lookup and dispatch extended the recreated source copy |
| `20260724-1645-31cb-stargazer-assistant-onboarding-duplicate-after-review-20260724T1829.json` | live adds non-CLI submit at 18:29:07; ghost retains the pre-submit prefix | Eric's manual submit, prompted by the same relay contract, bypassed the stable task lock; a later comment exposed the retained in-progress copy |
| `20260724-1645-31cb-stargazer-assistant-onboarding-inprogress-ghost-20260724T1834.json` | live adds non-CLI submit at 18:29:07; ghost receives Bella's 18:33 CLI comment | same unlocked Eric submit; CLI's existing multi-match warning selected the earlier state and extended the ghost |
| `20260722-141003-f9e2.inprogress-ghost-185128.json` | live adds non-CLI comment+submit at 18:37:17; ghost receives Anya's 18:50 CLI comment | Sancai's session says it atomically moved the task to review; the missing `via` and dispatcher instruction identify the same unlocked submit mechanism |

Checksums recorded before work:

- `3d0e`: `56ee3fabb50156492e46032da427d160c6194dbacc6f808b607f8e4b6c1fedcf`
- `31cb pending`: `0fb03b2a00a824fd0eca1f9d3e020beed8caf82d42d9b101787c3f2ffe188ace`
- `31cb post-review`: `16222afa0c7937b60badb2a11e764807b07c3dc82c6aa63ef1f8506e2173e559`
- `31cb review-comment`: `b7d9480b8c43e122162f55629ef425eb087815e1bb7fb1299cf8cca849b74647`
- `f9e2`: `cfeb0e2ea3df8073ccefb389f12a281311fc2ffd0532a0216cabae8b3fee9ab6`

Operational conclusion: task transitions must use `fatq-cli claim/submit/verdict`
or an implementation that acquires the identical stable task lock and performs
one source-to-destination rename. The task dispatcher must never instruct an
agent to reproduce this protocol manually. A hand-written history entry is not
evidence that the filesystem transition followed the protocol; it is now an
active-lint defect.

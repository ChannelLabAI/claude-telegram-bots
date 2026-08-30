# 49c0 stall alert attribution and routing

## Implementation

- Stale-task detection and all configured thresholds are unchanged.
- Every stale task alert now contains two explicit statements:
  `狀態事實` describes the event age/threshold and lack of transition;
  `責任事實` reports the assigned bot's last task comment and the current
  waiting target.
- For `in_progress`, a valid assigned comment no older than that state's
  configured stale threshold is treated as recent evidence. The waiting target
  is the first identity different from assigned in this order:
  `deliver_to`, `created_by`, `reviewer`. Without a recent comment or a distinct
  target, attribution and routing stay on assigned. `review` remains routed to
  reviewer. Owner routing remains additive and unchanged.
- The no-argument `shared/bin/patrol-alert-format-audit.sh` reads the latest
  durable patrol round. It checks every stale-task failure for both facts and
  exits nonzero with the missing parts named.

## AC1 before / after

Reproduce with `bash evidence/49c0/run-alert-before-after.sh`. The complete
captured texts are in `alert-before-after/before-alert.txt` and
`alert-before-after/after-alert.txt`.

Before:

```text
task_in_progress: ... task_id=05c1-SHAPE event_age=20s threshold=10s assigned=twinkle
```

After:

```text
task_in_progress: ... task_id=05c1-SHAPE 狀態事實: event_age=20s 已超過 threshold=10s，未產生狀態轉移；責任事實: assigned=twinkle 最近一次回應: 有，timestamp=2026-07-25T17:19:55+00:00; 本單目前等待對象: deliver_to=orange
```

## AC2 / AC3 / AC5 / AC6 evidence

`bash shared/tests/patrol-scan-safety.test.sh` prints the full alerts, not only
PASS labels. Final result: `RESULT: 16 pass, 0 fail`, exit 0.

The order is intentional:

1. AC3 positive control has no assigned comment and prints
   `本單目前等待對象: assigned=eric`; the bot-specific relay is addressed to
   Eric.
2. AC2 fixed 05c1 shape has a recent Twinkle comment and prints
   `本單目前等待對象: deliver_to=orange`; the bot-specific relay is addressed
   to Orange and no Twinkle relay exists.
3. AC2 mutant disables only the recent-response decision. The same task prints
   `本單目前等待對象: assigned=twinkle` and routes to Twinkle.

The suite also fixes the pre-existing hold safety properties with executable
assertions: a future hold cannot hide a missing meaningful event timestamp,
and malformed or expired holds both fail open to normal stale detection. The
audit has positive and negative fixtures; its negative output names all five
missing format parts.

## AC4 current-set comparison

`bash evidence/49c0/run-current-stall-set-ab.sh` copied the current pending,
in-progress, and review JSON files into one isolated fixture and ran the parent
and fixed scanners at the same pinned epoch (`1788033385`). The production task
files, patrol logs, relays, and services were not written.

- Before: 0 stale task IDs.
- After: 0 stale task IDs.
- Dropped set: empty; `AC4 PASS: no previously stale task disappeared`.

The empty live set is expected at capture time: 49c0 was only 394 seconds old,
and 05c1 had a valid hold until 12:00 +08:00. The AC3/AC2 fixtures supply the
non-empty true-positive calibration, while the A/B source diff changes only
formatting and recipient selection inside the already-stale branch.

Raw records and exact task-ID lists are under `current-stall-ab/`.

## AC7 external-wait design options

### Option A — structured `waiting_on` field (recommended)

Add a task field such as:

```json
{
  "waiting_on": {
    "kind": "external",
    "label": "final user preview confirmation",
    "since": "2026-08-30T00:16:00+08:00",
    "notify": "orange"
  }
}
```

`kind` should be a validated enum (`assigned`, `reviewer`, `created_by`,
`external`); `notify` remains an internal bot identity because an external
party is not necessarily a relay recipient. FATQ CLI needs locked set/clear
commands and history entries. Patrol uses the field for attribution/routing but
continues to detect and report staleness. Dispatch and UI can display the same
reason. Transitions should clear stale waiting metadata atomically.

This adds schema and consumer work, but preserves the existing timestamp type
and separates “who/what is awaited” from “when to suppress a reminder.” It can
represent indefinite external waits without pretending that work is held.

### Option B — extend `not_before` semantics

Turn the current timestamp into an object carrying `until`, `reason`, and
`waiting_on`, or add sibling reason/target fields. This touches every consumer
that currently parses `not_before` as a date string, requires a migration or
dual-read period, and still couples responsibility with temporary suppression.
An indefinite external wait has no honest `until`; choosing arbitrary expiries
recreates the current repeated-hold behavior, while no expiry risks silencing
stale detection.

Recommendation: implement Option A in a follow-up task. Keep `not_before` as a
short-lived scheduling/suppression mechanism with its existing fail-open safety
semantics.

## Production boundary

Implementation and tests exist only on the isolated task clone/branch. No
production checkout, task workspace, patrol log, relay, cron, or service was
modified or restarted. After reviewer approval, a maintainer must apply the
commit, install the executable audit script, allow a patrol round to run, and
then execute the registered live verify command.

---
triggers: ["model gate", "降模", "model-router", "bot_defaults", "gate:", "INSUFFICIENT_DATA", "回滾"]
description: "Model downgrade measurement gate: metrics, baseline/treatment windows, exception SOP, and rollback conditions"
---

# Block: Model Downgrade Gate

Model downgrades in `shared/config/model-router.yml` are controlled changes. The goal is not to ban cheaper models; it is to prove they do not cost more through rework, latency, or rate-limit pressure.

## Metrics

| Metric | Definition | Source | Status |
|---|---|---|---|
| M1 rework rounds | Per task count of `history[].action == "verdict_reject"`, aggregated by assigned bot and period | FATQ task JSON; final state is the containing directory, not `.status` | Available now |
| M2 reject rate by issue_type | Reject rounds by issue type; missing issue_type is conservatively counted as `execution_error` and reported with missing rate | FATQ task history | Available now with missingness note |
| M3 wall-clock | Claim-to-terminal verdict duration, with first-pass and total duration views | FATQ task history timestamps | Available now |
| M4 per-task total tokens | Builder/reviewer token use during task lifecycle including rework | `logs/usage.jsonl` x task history | Approximate only in v1 |
| M5 rate-limit pressure | Sum of `rate_limit_events` for the bot during the period | `logs/usage.jsonl` | Available now |

M4 gap: `usage.jsonl` is session-level cumulative snapshots and has no `task_id`. v1 estimates M4 from adjacent `session_id` token deltas inside the selected baseline/treatment calendar windows for the same bot, not by exact per-task attribution. Concurrent tasks for the same bot can over-count; every report must show the number of overlapping concurrent bot tasks as a noise marker. v2 instrumentation requirement: gateway dispatch injects `FATQ_TASK_ID` into the provider session and `usage-log.sh` writes `task_id`; that daemon work is out of scope for v1.

Cost language: subscription usage is not API billing. Reports use tokens, rate-limit events, rework rounds, and wall-clock. USD-equivalent fields are reference only.

## Windows

Baseline is the 14 days before the model change. Treatment starts on the change date and ends at the earlier of 14 days or 25 terminal tasks. If 14 days has fewer than 25 terminal tasks, extend until 25 tasks or 28 days, whichever comes first. If the treatment period still has fewer than 25 terminal tasks, the report is `INSUFFICIENT_DATA` and must not recommend rollback or approval.

Initial real case: Bella baseline `2026-06-29` through `2026-07-12`, treatment from `2026-07-13`. Twinkle uses the same method.

## Gate SOP

Any downgrade to `model-router.yml` `bot_defaults` must include an inline `gate:<report-path>` comment. Gate reports live under `handover/model-gate/<date>-<bot>.md` and should be generated from `shared/bin/model-gate-report.sh` plus a short human conclusion.

Emergency exception: a downgrade may be applied first for incident mitigation such as rate-limit stop-the-bleeding. Within 48h, the owner must add the gate report path in Mattermost and register a `graduated_invariant` asserting that the report file exists. The existing Goal Graduation daily loop checks and alerts; no commit hook, CI gate, or daemon change is introduced by this v1 SOP. If the report cannot be produced, roll back the downgrade.

Enforcement v1 is Bella review practice for shared infra plus the report script. Do not add pre-commit or CI interception in this version.

## Rollback Conditions

Evaluate each treatment observation window against baseline. A single window trigger is `WARNING(1/2)`, not failure. The same condition triggering in two consecutive observation windows is `FAIL` and recommends rollback. If the treatment data threshold is not met, all conditions are `INSUFFICIENT_DATA`.

| Rule | Condition |
|---|---|
| R1 | First-pass rate drops by more than 15 percentage points |
| R2 | Average rework rises enough that estimated total tokens are higher than baseline |
| R3 | Median total wall-clock rises by more than 50% |
| R4 | Escalations to the owner rise, using tasks with more than 3 reject rounds as the local proxy |

Rollback means revert only the affected `bot_defaults` line and append the conclusion to the gate report. Returning to the previously measured model state is exempt from a new downgrade gate.

## Future Extensions

Spec A `inline-work.jsonl` and Spec B `[advisor]` coverage can become additional evidence sources later. They are intentionally excluded from v1 to keep this gate small and auditable.

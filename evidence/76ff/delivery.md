# 76ff delivery evidence

## Result

`require_reason_value` now rejects a mutable free-text/routing/evidence option
when its value is missing or begins with `--`. Its optional diagnostic label
keeps reason options saying `需要理由` and other values saying `需要值`. Text
containing `--` after the first character is unchanged. Structured, enumerated,
date, integer, existence-checked, or canonical-identity values retain their
existing validators.

No production checkout, task closeout record, service, or write-once path was
modified. The shared repository refs were read-only, so this work lives in an
isolated local clone/branch and must be applied by Anya only after reviewer
approval.

## AC1: before / fixed / mutant

Reproducer: `evidence/76ff/closeout-flag-repro.sh <fatq-cli.sh>`.

Baseline (`a52651b`, production source read-only):

```text
CLI_OUTPUT=[fatq-cli] closeout OK: closeout-flag-repro state=closed by=anya
EXIT_CODE=0
CLOSEOUT_JSON={"state":"closed","host_effect_policy":"required_for_commits","host_effect":"none","no_host_effect":{"reason":"--live-check","by":"anya","ts":"2026-08-30T09:10:29+08:00"}}
```

The requested `live_check` is absent and its flag became the persisted reason.

Fixed:

```text
CLI_OUTPUT=[fatq-cli] ERROR: closeout: --no-host-effect 需要理由
EXIT_CODE=2
CLOSEOUT_JSON={"state":"pending","host_effect_policy":"required_for_commits"}
```

Mutant (both closeout guard calls deleted from the fixed file):

```text
CLI_OUTPUT=[fatq-cli] closeout OK: closeout-flag-repro state=closed by=anya
EXIT_CODE=0
CLOSEOUT_JSON={"state":"closed","host_effect_policy":"required_for_commits","host_effect":"none","no_host_effect":{"reason":"--live-check","by":"anya","ts":"2026-08-30T09:22:17+08:00"}}
```

Thus the test boundary distinguishes fixed from the guard-removed mutant.

## AC2 and AC3: positive calibration first

`CLOSEOUT30` intentionally executes these in order:

```text
EVIDENCE CLOSEOUT30_CALIBRATION_EXIT=0
EVIDENCE CLOSEOUT30_CALIBRATION_JSON={"state":"closed","host_effect_policy":"required_for_commits","host_effect":"none","no_host_effect":{"reason":"本單是純文件交付","by":"anya","ts":"2026-08-30T09:16:49+08:00"}}
EVIDENCE CLOSEOUT30_BOUNDARY_EXIT=0
EVIDENCE CLOSEOUT30_BOUNDARY_JSON.reason=本單無部署效果 -- 純文件交付
EVIDENCE CLOSEOUT30_NOHOST_EXIT=2 OUTPUT=[fatq-cli] ERROR: closeout: --no-host-effect 需要理由
EVIDENCE CLOSEOUT30_UNVERIFIED_EXIT=2 OUTPUT=[fatq-cli] ERROR: closeout: --unverified 需要理由
```

The test also hashes each rejected fixture before/after and requires exact
equality.

## Reject round 1: same-shape fixed / baseline / mutant

Bella correctly found that the first inventory used the wrong safety test:
"not reason evidence" does not prevent a parser from consuming a flag. The
revised reproducer is
`evidence/76ff/same-shape-flag-repro.sh <fatq-cli.sh>`.

Baseline `a52651b` and a final guard-removed mutant both exit 0 and persist the
swallowed option token:

```text
REASSIGN exit=0 assigned="--reason"
COMMENT exit=0 history[-1].text="--as"
ATTACH_FILE exit=0 attachments[0].file="--mime"
ATTACH_NAME exit=0 attachments[0].name="--mime"
ATTACH_MIME exit=0 attachments[0].mime="--size"
APPROVAL_EVIDENCE exit=0 history[-1].evidence="--reason" reason=""
```

The fixed CLI returns exit 2 for all six and leaves each fixture byte-for-byte
unchanged:

```text
reassign: --to 需要值
comment: --text 需要值
attach: --file 需要值
attach: --name 需要值
attach: --mime 需要值
approval approve: --evidence 需要值
```

`ARGBOUND1` calibrates a legal reassign target and a comment containing embedded
`--` before its reject probes. It then hashes every rejected mutation fixture,
checks all ten guarded create free-text/routing options, and covers all six
reproducer shapes above. Removing the new calls restores the baseline corrupt
writes, so the mutant is meaningful.

## AC4: complete `foo="$2"; shift 2` inventory

Line numbers refer to this delivery commit's `shared/bin/fatq-cli.sh`.

| Command | Options | Classification |
|---|---|---|
| `cmd_create` | all 21 value options (1100-1153) | Guarded because only free text/non-strict conversion: `--title`, `--goal`, `--background`, `--context`, `--review_focus`, `--assigned`, `--reviewer`, `--priority`, `--fast_track`, `--slug`; reason-guarded: `--no-live-verify`. Safe by existing validation: JSON arrays `--deliverables`, `--acceptance_criteria`, `--out_of_scope`, `--verify_commands`, `--live_verify_commands`, `--skills`, `--graduated_invariant` at 1189-1229; `--workflow` at 1201-1204; `--project_id` must resolve an existing project at 1164-1168; `--deliver_to` must canonicalize to a configured identity at 1183-1186. `ARGBOUND1` executes every guarded create site. |
| `cmd_cancel` | `--reason` (1773-1776) | Guarded; trim validation remains. |
| `cmd_verdict` | `--reason`, `--issue_type`, `--ts` (2001-2006) | Reason guarded. `issue_type` is enumerated later; external `ts` is always rejected. |
| `cmd_reassign` | `--to` (2104-2107) | Guarded after the exact exit-0 corruption was reproduced. Explicit empty-string clearing still works because only leading `--` or a missing argv is rejected. |
| `cmd_comment` | `--text` (2306-2309) | Guarded after the exact evidence-loss write was reproduced. Embedded `--` remains accepted by `ARGBOUND1`. |
| `cmd_attach` | `--file`, `--name`, `--mime`, `--size` (2383-2395) | All three strings are guarded: actual baseline runs persisted `--mime`, `--mime`, and `--size` respectively. `--size` is safe via integer validation at 2405. The filename character class alone was not sufficient because it accepts hyphens. |
| `cmd_hold` | `--until` (2477) | Safe: `now`/`--clear` handling or `date -d` parsing at 2500-2507 rejects option tokens. |
| `cmd_set_live_verify` | `--value`, `--reason` (2577-2580) | Reason guarded; value must be a non-empty command array at 2592 onward. |
| `cmd_closeout` | `--deploy-evidence`, `--live-check`, `--unverified`, `--no-host-effect`, `--state` (2913-2923) | Both reasons guarded. State enum at 2939-2942; deploy JSON at 2964-2982; live JSON immediately after. Structured values cannot silently pass a flag. |
| `cmd_update_field` | `--value` (3420) | Safe: JSON string/array validation plus field allowlist at 3430-3440. |
| `cmd_approval_request` | `--domain`, `--expires`, `--reason` (3630-3634) | Reason guarded; domain enum at 3641-3644 and expiry parser reject option tokens. |
| `cmd_approval_verdict` | `--evidence`, `--reason` (3741-3747) | Both guarded. Actual baseline approved with `evidence="--reason"` and dropped the real text; fixed and mutant tests cover it. |
| `cmd_query` | `--task-id`, `--state`, `--assigned` (4066-4068) | Read-only filters with no task/history/evidence mutation. They cannot produce the acceptance criterion's silent corrupt write; no grammar change was made. |
| `cmd_force_mv` | `--reason` (4152-4154) | Audit reason guarded. |

There are 25 guarded call sites total: the original nine reason categories,
ten create free-text/routing fields, `reassign --to`, `comment --text`, three
attachment string fields, and approval `--evidence`.

## AC5: write-once and evidence checks unchanged

`git diff --unified=0 a52651b..HEAD -- shared/bin/fatq-cli.sh` plus the R1 diff
contains only the shared parser guard and parser call sites. There is no hunk in
`cmd_closeout` after argument parsing, no hunk in `cmd_set_live_verify`'s
`closeout.state == closed` refusal, no hunk in the `deploy_evidence` /
`live_check` write-once checks, and no hunk in `verified_by` validation. No route
for modifying a closed closeout was added.

## AC6: regression

```text
COMMAND=bash shared/tests/fatq-cli-test.sh
EXIT_CODE=0
[fatq-cli-test] RESULT: 189 pass, 0 fail (of 189)
[fatq-cli-test] All cases passed ✅
```

## AC7: production read-only scan

Command: `evidence/76ff/scan-leading-reasons.sh
/home/oldrabbit/.claude-bots/tasks`. It scans direct JSON files under each
top-level tasks directory, which includes task states/quarantines while
excluding nested `work/` clone contents.

```text
MATCH task_id=20260828-0128-a91b-spec-review-entrance-v2-review field=no_host_effect reason=--live-check file=/home/oldrabbit/.claude-bots/tasks/done/20260828-0128-a91b-spec-review-entrance-v2-review.json
TOTAL_JSON_FILES=940
TOTAL_TASK_JSON=807
TOTAL_WITH_CLOSEOUT=408
LEADING_REASON_MATCHES=1
```

The sole match is the disclosed a91b incident; it was not modified.

## Formal verifier

```text
COMMAND=/home/oldrabbit/.claude-bots/shared/bin/fatq-verify.sh /home/oldrabbit/.claude-bots/tasks/in_progress/20260830-0903-76ff-closeout-flag-eats-next-flag-silently.json
EXIT_CODE=0
PASS [1/1] command #1 (exit 0 == expected 0)
[fatq-verify] RESULT: 1 pass, 0 fail (of 1)
[fatq-verify] All gates passed ✅
```

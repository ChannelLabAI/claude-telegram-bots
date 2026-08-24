# Gate corpus Phase 1: G09 removed, G12 advisory

Phase 1 implements the owner's reversible risk choice; it does **not** claim
that `caught=0` proves either gate never intercepted anything. Successful
automatic interceptions were historically silent, so the corpus cannot see
them. The policy changes which failures may block a transition while retaining
the original 36 case records unchanged.

## Single-point policy and rollback

`shared/lib/fatq-gate-policy.sh` is the only default policy point:

- `FATQ_G09_BLOCKING=0`: reviewer approval does not automatically execute or
  block on registered `verify_commands`. Direct `fatq-verify.sh` use remains
  available. Set the value to `1` to restore the original approval gate.
- `FATQ_G12_BLOCKING=0`: every configured `live_verify_commands` entry still
  runs. Its expected/actual exit, bounded stdout/stderr samples, byte counts,
  truncation flags and hashes are persisted in
  `closeout.host_effect_proof`. A failed result is `result: "fail"` and does not
  prevent `closeout.state: "closed"`. Set the value to `1` to restore blocking.

The focused fixture `shared/tests/tierc-phase1.test.sh` proves both default
behaviors and both rollback values. Its G09 positive control runs a registered
command that prints `g09-positive-control` and exits 9: mode 0 approves without
executing it, while mode 1 executes it, returns CLI exit 5, and leaves the task
in review. Its G12 negative probe prints to both streams and exits 7: mode 0
closes with durable `result=fail` evidence, while mode 1 returns CLI exit 4 and
leaves closeout pending.

Complete focused-fixture output (exit code `0`):

```text
--- G09 disabled approval output ---
[fatq-cli] NOTICE: G09 verifier blocking is disabled by policy; reviewer approval proceeds without automatic fatq-verify execution
[fatq-cli] verdict approve OK: g09-disabled review/ -> done/
--- G09 restored positive-control output ---
[fatq-cli] ERROR: verdict approve: verify gate 未過（fatq-verify.sh exit 1），任一 fail 直接攔下不進 approve
[fatq-verify] Running 1 verify command(s)...
  ❌ FAIL [1/1] command #1 (exit 9 != expected 0)

────────────────────────────────────
[fatq-verify] RESULT: 0 pass, 1 fail (of 1)
[fatq-verify] FAILED gates:
  • [1] command #1 — got exit 9, expected 0; stdout_bytes=0 stdout_truncated=false; stderr_bytes=21 stderr_truncated=false
    stdout (first 8192 bytes):

    stderr (first 8192 bytes):
g09-positive-control
--- G12 advisory failed-probe closeout output ---
[fatq-cli] live_verify_commands[0] diagnostic (stdout first 8192 bytes; truncated=false):
probe-failed

[fatq-cli] live_verify_commands[0] diagnostic (stderr first 8192 bytes; truncated=false):
probe-detail

[fatq-cli] WARNING: G12 advisory probe failed; failure evidence will be persisted and closeout may continue
[fatq-cli] closeout OK: g12-advisory state=closed by=deploy-pipeline
--- G12 restored blocking output ---
[fatq-cli] live_verify_commands[0] diagnostic (stdout first 8192 bytes; truncated=false):
probe-failed

[fatq-cli] live_verify_commands[0] diagnostic (stderr first 8192 bytes; truncated=false):
probe-detail

[fatq-cli] ERROR: closeout: 主機生效探針失敗：至少一條 live_verify_commands 未達預期 exit code
tierc phase1 tests PASS (G09 disabled/restored; G12 advisory evidence/restored blocking)
```

## Scorecard before

Command: `/home/oldrabbit/.claude-bots/shared/bin/gate-corpus-report.sh`

Exit code: `0`

```text
Gate corpus scorecard (cases=36)
GATE	caught	missed	false_block	exclusive
G01	0	0	0	0
G02	0	0	0	0
G03	0	0	0	0
G04	0	0	0	0
G05	0	2	0	0
G06	0	3	0	0
G07	0	0	0	0
G08	0	0	0	0
G09	0	1	2	0
G10	28	0	0	28
G11	0	2	0	0
G12	0	2	2	0

Zero-score gates (caught=0):
G01,G02,G03,G04,G05,G06,G07,G08,G09,G11,G12
No-exclusive gates (exclusive=0):
G01,G02,G03,G04,G05,G06,G07,G08,G09,G11,G12
```

## Scorecard after

Command: `shared/bin/gate-corpus-report.sh`

Exit code: `0`

```text
Gate corpus scorecard (cases=36)
GATE	caught	missed	false_block	exclusive	mode
G01	0	0	0	0	blocking
G02	0	0	0	0	blocking
G03	0	0	0	0	blocking
G04	0	0	0	0	blocking
G05	0	2	0	0	blocking
G06	0	3	0	0	blocking
G07	0	0	0	0	blocking
G08	0	0	0	0	blocking
G09	0	1	0	0	disabled
G10	28	0	0	28	blocking
G11	0	2	0	0	blocking
G12	0	2	0	0	advisory

Zero-score gates (caught=0):
G01,G02,G03,G04,G05,G06,G07,G08,G09,G11,G12
No-exclusive gates (exclusive=0):
G01,G02,G03,G04,G05,G06,G07,G08,G09,G11,G12
```

The `missed` column deliberately remains historical exposure rather than being
erased by a policy switch. The `false_block` column is mode-aware because a
disabled/advisory gate can no longer block. This makes both G09 and G12 zero
without rewriting `cases.jsonl` or pretending their historical misses vanished.

## Case-by-case comparison

Only the four false-block cases change operational classification:

- F001 and F004: G12 still runs and records a failure, but advisory mode cannot
  block closeout; their G12 `false_block` debit changes from counted to zero.
- F002 and F003: G09 is absent from automatic approval, so its `false_block`
  debit changes from counted to zero. Registered commands remain runnable
  directly, but cannot strand the review transition by default.

All other case classifications and raw records are unchanged:

- C001-C028 remain `caught`, with G10 as the sole recorded catcher in every
  case. In particular C008, C010, C013 and C021 still credit G10, not G09/G12.
- M001-M004 remain `missed`. M001/M003 retain G12 exposure and M004 retains G09
  exposure so the risk is visible rather than rewritten away.

Thus all 36 cases are accounted for: 4 policy-result changes and 32 unchanged
case classifications. `selection-check.sh` continues to reproduce the same
28+4+4 selection, and the corpus file itself is byte-unchanged.

## Risk relocation

### G09

The blocking responsibility moves to **G10 independent reviewer QA**. The
concrete mechanism is the existing reviewer-only `verdict approve/reject`
transition: the assigned builder cannot self-approve, and the reviewer may run
the still-available `fatq-verify.sh` plus adversarial checks before issuing the
verdict. The corpus records G10 as 28/28 caught and exclusive for all 28 caught
cases. This is evidence of historical coverage, not proof of future completeness.

Risk retained: because G09 no longer auto-runs registered commands during
approval, an omitted reviewer replay can approve a defect that the old command
might have exposed. Re-enabling `FATQ_G09_BLOCKING=1` restores that exact
automatic gate without rewriting verifier logic.

### G12

No gate takes over post-deploy blocking: **沒有人接**. G10 ends before deploy
and cannot prevent a deployment that is broken only after host apply or restart.

The concrete remaining discovery mechanism is G12 itself in advisory mode:
the closeout command directly executes every `live_verify_commands` argv and
writes `closeout.host_effect_proof`, including `result=fail`, actual exit codes,
bounded stdout/stderr and hashes. This makes a failure inspectable in the closed
task, but no existing mechanism automatically intercepts or rolls back the bad
deployment. The fixture demonstrates that asymmetry explicitly. A future
rollback to `FATQ_G12_BLOCKING=1` restores blocking for later closeouts; it
cannot repair a bad deployment that already passed while advisory.

No daemon, cron entry or long-running layer was added. G10 and G01-G08/G11
behavior are untouched.

## Regression results

- `shared/tests/patrol-scan.test.sh`: 5 pass, 0 fail; exit 0.
- `shared/tests/patrol-scan-safety.test.sh`: 8 pass, 0 fail; exit 0.
- `shared/tests/gate-corpus/report-test.sh`: PASS; exit 0.
- `shared/tests/gate-corpus/selection-check.sh`: 28 deterministic caught + 4
  mandatory missed + 4 false_block; exit 0.
- `bash shared/tests/fatq-cli-test.sh`: 186 pass, 0 fail; exit 0. This legacy
  matrix explicitly uses rollback mode for its old blocking assertions; the
  Phase 1 fixture above owns default-mode behavior.

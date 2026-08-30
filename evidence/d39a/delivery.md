# d39a delivery evidence

## Outcome

- `shared/hooks/l25-trigger-loader.sh` now preserves the per-session state on a
  repeated `SessionStart`, uses a per-session file lock for atomic check/mark,
  and records both first injections and deduplicated attempts.
- `shared/bin/l25-load-audit.sh` validates and aggregates the JSONL log. Default
  (and `--sort count`) order is descending actual load count.
- No `block-*.md` content is changed.
- The production checkout and services were not modified. The repository
  worktree helper could not create a ref in this sandbox, so implementation is
  in an isolated clone on branch `agent/anna/d39a-l25-load-audit`.

## JSONL format

One line is emitted for each eligible first load or same-session dedup hit:

| Field | Type | Meaning |
| --- | --- | --- |
| `ts` | string | ISO-8601 event time |
| `session_id` | string | sanitized session identity used as the dedup boundary |
| `bot` | string | bot directory identity |
| `event` | string | `SessionStart` or `UserPromptSubmit` |
| `block` | string | `block-*.md` filename |
| `bytes` | integer | complete source file bytes |
| `context_bytes` | integer | injected body bytes after frontmatter removal |
| `first_in_session` | boolean | true only when this session first loads the block |
| `injected` | boolean | whether additional context was emitted |

The actual seven-row fixture log is `evidence/d39a/l25-trigger.jsonl`; the first
five rows are also printed verbatim in `evidence/d39a/test-output.txt`.

## Discrimination evidence

The exact pre-change hook is reproduced by `evidence/d39a/baseline-repro.sh`.
Two `SessionStart` calls with the same `session_id` both contain
`BASELINE_DUPLICATE_CONTEXT`; output and exit are in
`evidence/d39a/baseline-repro.txt` and `evidence/d39a/exit-codes.txt`.

The fixed fixture separately proves:

1. first dynamic trigger emits `FIRST_DYNAMIC_CONTEXT`;
2. the second same-session trigger emits no output and logs
   `first_in_session=false`;
3. a repeated same-session `SessionStart` also emits no output;
4. two concurrent same-session triggers produce one injection and one dedup;
5. a new session's first trigger emits `FIRST_DYNAMIC_CONTEXT` again.

The repository contained no existing L2.5 loader-specific regression test.
`shared/tests/l25-trigger-loader-test.sh` therefore exercises both existing
event output shapes plus the new observability and boundary behavior.

## Audit output

Command:

```text
shared/bin/l25-load-audit.sh --log evidence/d39a/l25-trigger.jsonl --sort count
```

Actual output (`evidence/d39a/audit-run.txt`):

```text
block	loads	cumulative_bytes	dedup_hits	dedup_saved_bytes	attempts
block-daily-cron.md	3	303	2	202	5
block-high.md	1	97	1	97	2
```

Recorded exits:

```text
BASELINE_EXIT=0
FIXED_TEST_EXIT=0
AUDIT_EXIT=0
```

`bash -n` for the hook, audit, and test scripts also exits 0. `shellcheck` is
not installed in this runtime.

## Maintainer handoff

After reviewer approval, Anya or another authorized maintainer should apply the
exported patch to a clean branch, run `shared/tests/l25-trigger-loader-test.sh`,
and deploy the hook through the normal reviewed rollout. No restart or live
production mutation was performed by Anna.

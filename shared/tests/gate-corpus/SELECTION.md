# Selection rule

Snapshot cutoff: `2026-08-23T17:13:51+08:00`, the creation time of FATQ 7015.

The corpus has three strata:

1. **Caught (28):** scan core FATQ state directories, retain tasks created no
   later than the cutoff with at least one `history.action=verdict_reject` whose
   `issue_type=execution_error`, sort by `(created_at, task_id)` descending, and
   take 28.  No prose keyword or author judgment chooses this stratum.
2. **Missed (4):** the four incidents mandated by the task: e172 false green,
   0a58 setup masking, e172 half-effective closeout, and Gate C multiline
   truncation.  Their task histories are the sources.
3. **False block (4):** the documented live-probe opt-out deadlocks (d4e7 and
   e74b), the malformed task-authored verifier schema (9673), and the long
   submit-verifier builder deadlock (c735).

Run from any checkout:

```bash
FATQ_TASK_ROOT=/home/oldrabbit/.claude-bots/tasks \
  shared/tests/gate-corpus/selection-check.sh
```

The check recomputes stratum 1 and verifies that every unique source reference
in all strata resolves to exactly one real FATQ task file.  Source-content and
gate classification remain reviewer work; existence alone is not treated as
proof that the description is correct.

# ffe9 delivery evidence

## Outcome

The dry-run path no longer replaces `generate_report()`'s persisted
`stale_candidates WHERE status='pending'` count with the length of the current
detection list. The fixture deliberately contains two persisted pending rows
and one currently detected cold radar row, so the two values discriminate the
fixed code from the old tautology.

## AC1, AC2, and AC4: real CLI fixture

Command shape:

```text
python3 shared/scripts/stale_knowledge_check.py --dry-run --db <isolated-fixture>/memory.db
```

Independent SQL before the run:

```text
BEFORE status counts:
status   count
-------  -----
pending  2

DIRECT pending query:
pending_total
-------------
2
```

Actual CLI JSON and exit:

```json
{
  "cold_count": 1,
  "contradiction_count": 0,
  "pending_total": 2,
  "sample_cold": [
    "detected-cold"
  ],
  "archived_count": 0
}
```

```text
CLI_EXIT=0
AFTER status counts:
status   count
-------  -----
pending  2
```

The fixture schema already included every migration column. The dry-run log
reported that candidate writes and report posting were skipped. The complete
`stale_candidates` status distribution was identical before and after.

## AC3: regression and mutant discrimination

Fixed targeted test:

```text
.                                                                        [100%]
1 passed in 0.07s
GREEN_EXIT=0
```

In a separate task-local mutant copy, restoring the exact old line
`report["pending_total"] = len(all_candidates)` makes the same test fail:

```text
>       assert report["pending_total"] == actual_pending == 2
E       assert 1 == 2
1 failed in 0.33s
MUTANT_EXIT=1
```

Full fixed test file and syntax checks:

```text
python3 -m pytest -q shared/scripts/tests/test_stale_knowledge_check.py
.........................                                                [100%]
25 passed in 0.86s

python3 -m py_compile shared/scripts/stale_knowledge_check.py shared/scripts/tests/test_stale_knowledge_check.py
exit 0

git diff --check
exit 0
```

## AC5: path boundary

The implementation diff removes one assignment inside `if dry_run:`. The
non-dry-run branch and all write/reconciliation/archive/report-delivery calls
are unchanged. Both paths still begin with `generate_report(conn)`, which
queries the persisted cold, contradiction, and total pending counts. Only
dry-run replaces `cold_count`, `contradiction_count`, and `sample_cold` with
the current read-only scan results; it now preserves the independently queried
persisted `pending_total`. Non-dry-run preserves the entire generated report.

## AC6: `cold_count` assessment

`cold_count` does not have the same defect. Its dry-run meaning is the number
of radar rows detected cold by the current scan, so deriving it from
`cold_candidates` is intentional. The regression fixture demonstrates that
this current-scan value can be `1` while the persisted pending queue is `2`.
Outside dry-run, `cold_count` continues to come from this independent SQL:

```sql
SELECT COUNT(*)
FROM stale_candidates
WHERE reason='cold' AND status='pending';
```

No production checkout, production DB, service, relay, cron, or notification
was modified or invoked.

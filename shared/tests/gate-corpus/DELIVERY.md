# Gate corpus Phase 0 findings

This is measurement only.  No gate behavior, queue task, closeout field, hook,
CI path, deployment path, or blocking mechanism is changed.

The corpus contains 36 real-record cases: 28 caught, 4 missed, and 4 false
blocks.  `selection-check.sh` reconstructs the caught stratum and resolves all
source task IDs.  `report-test.sh` also deletes `description` from C001 and
requires the report to fail with both `C001` and `description` in diagnostics.

## Zero-score or no-exclusive gates

Only G10 (independent reviewer QA) receives caught credit in this snapshot: all
28 caught cases are recorded as reviewer rejects.  The corpus does not award an
earlier gate merely because that gate should have caught the defect.

- Zero caught score: G01-G09, G11-G12.
- No exclusive caught case: G01-G09, G11-G12.
- G09 has two false blocks and one missed case.
- G12 has two false blocks and two missed cases.
- G05 and G06 have the highest missed counts among pre-review checks because
  the e172/0a58 records demonstrate green fixtures without the production
  failure condition.

These numbers are a baseline, not a Phase 1 recommendation to remove a gate.

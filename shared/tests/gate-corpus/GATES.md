# Gate corpus scoring vocabulary

This corpus normalizes the current delivery chain into twelve measurable gate
families.  The names describe where evidence is evaluated; they do not claim
that the implementation is one twelve-function program.

| ID | Gate family | Evidence boundary |
|---|---|---|
| G01 | spec contract | goal, AC, deliverables, out-of-scope and later spec drift |
| G02 | search pre-read | reject history and MemOcean search before implementation |
| G03 | scope/diff | changed-file and out-of-scope review |
| G04 | schema/static | JSON/schema/lint/static source checks |
| G05 | unit/fixture | checked-in automated behavior fixtures |
| G06 | negative control | deliberately broken input must make the check fail |
| G07 | build/syntax | compiler, build and syntax checks |
| G08 | isolated apply | clean clone, frozen-base and patch-apply checks |
| G09 | FATQ verifier | `fatq-verify.sh` execution of registered verify commands |
| G10 | reviewer QA | independent reviewer inspection and adversarial replay |
| G11 | approved host apply | approval-to-deployment provenance and complete multi-repo apply |
| G12 | live closeout | post-deploy probe, restart/effect evidence and closeout state |

Phase 1 enforcement policy is read from
`shared/lib/fatq-gate-policy.sh`. G09 is disabled in the automatic review
transition and G12 is advisory: its live probes still execute and persist
bounded success or failure evidence, but a failed probe no longer blocks
`closeout.state=closed`. Both blocking behaviors have a one-value rollback.

Scoring is deliberately asymmetric:

- `caught`: credit only gates listed in `caught_by`; do not infer credit from
  `expected_gates`.
- `missed`: debit every gate listed in `expected_gates`.
- `false_block`: debit every gate listed in `blocked_by`.
- `exclusive`: a caught case whose `caught_by` contains exactly one gate.

# FATQ 353b delivery

## Scope

- `missing_registration` now compares each discovered bot directory against the roster `state_dir` list through the existing alias matcher.
- `known-aliases.json` registers `keeper` ↔ `diana`, with reason and `added_at`.
- `roster-patrol-alias-audit.sh` defaults to the same production root as `roster-patrol.sh`, reports `checked=<N>`, fails closed at zero observations, and exits non-zero if an alerting `missing_registration` key still matches a registered alias endpoint.
- No production checkout, service, cron, relay, whitelist, patrol-scan logic, or team-config data was changed.

## AC2 true-positive calibration first

The first emitted case in `fixed-test.txt` is `AC2_TRUE_POSITIVE_FIRST`. A fixture directory named `truly-unregistered` contains `CLAUDE.md`, is absent from team-config and active pods, and is absent from aliases. It remains `known:false` and alerting before any suppression result is trusted.

Command:

```bash
bash shared/tests/roster-patrol-alias-test.sh
```

Result: PASS. The same run also creates one `missing_directory` and one `pod_unregistered` fixture and proves their complete issue objects are byte-identical between the old self-compare mutant and the fixed implementation.

## AC1 before and after on the same current host inputs

Both runs used the current read-only production `team-config.json`, `bots/`, and `pod-system/pods/`, wrote only under this task clone, set `ROSTER_PATROL_DRY_RUN=1`, and used the same timestamp.

- Before (`baseline-report/baseline.json`): `alerting=1`, `known=0`; Diana is `known:false`.
- After (`fixed-report/fixed.json`): `alerting=0`, `known=1`; Diana is `known:true`, `known_reason="Diana uses keeper as her runtime state_dir"`, `known_added_at="2026-08-30"`.

The corresponding complete JSON and Markdown reports are committed under those two directories. Command stdout is in `baseline-command.txt` and `fixed-command.txt`.

## AC3 both halves are necessary

`fixed-test.txt` contains the real issue objects and counts:

- `AC3_DATA_ONLY_STILL_ALERTS`: the old self-compare mutant plus the Diana alias leaves Diana `known:false` and alerting.
- `AC3_CODE_ONLY_STILL_ALERTS`: fixed code plus an empty alias file leaves Diana `known:false` and alerting.
- `AC1_FIXED_AND_AC2_RECHECK`: only fixed code plus alias data marks Diana known, while `truly-unregistered` remains alerting.
- `AUDIT_REJECTS_ALIAS_LEAK`: the audit exits 1 and identifies Diana against the old mutant.
- `AUDIT_REJECTS_ZERO_CHECKED`: the audit reports `checked=0` and exits 1 rather than passing without an observation target.
- `AUDIT_ACCEPTS_FIXED_REPORT`: the audit exits 0 against the fixed implementation.

## R1 audit gate discrimination

The reject identified that the original audit derived `ROOT` from its clone location. Because `bots/diana` is untracked, the literal gate had no Diana observation target and passed the old core. R1 makes the default exactly `/home/oldrabbit/.claude-bots`, while retaining `ROSTER_PATROL_ROOT` fixture overrides.

Two detached worktrees reproduced the reviewer setup. The old audit at `c0e2f0f` and the pre-fix core at `a02e170` were compared with the R1 audit, without a root override:

```text
old audit + old core: PASS, exit 0, 18 alerting / 0 known (empty-observation false pass)
R1 audit + old core: checked=1, Diana alias leak printed, exit 1
R1 audit + fixed core: checked=1, PASS, exit 0, 0 alerting / 1 known
```

The captured result is `GATE_DISCRIMINATION old_audit_mutant=0 new_audit_mutant=1 new_audit_fixed=0` in `gate-discrimination.txt`. This proves the registered command now distinguishes the regression it gates.

## AC4 and AC6 scope proof

```bash
git diff -- shared/team-config.json shared/loops/patrol-scan.sh
```

Result: empty (`ac4-ac6-out-of-scope.diff`, 0 bytes). Diana was not added to any whitelist and `team-config.json` remains untouched; its current host `state_dir` remains `keeper`. `implementation.diff` records the initial implementation; the R1 commit changes only the audit, its test, and evidence.

## AC5 report comparison

The complete current-host reports are `baseline-report/baseline.json` and `fixed-report/fixed.json`. Current host inputs contain no `missing_directory` or `pod_unregistered` issues before or after; extracted arrays compare with exit 0 in `ac5-other-branches.diff`.

The stronger fixture in `fixed-test.txt` creates one issue in each branch and compares their complete issue objects between old and fixed implementations. It emits `AC5_OTHER_BRANCHES_UNCHANGED` only after `diff -u` exits 0.

## Verification and rollout

Builder-side checks:

```bash
bash -n shared/loops/roster-patrol/roster-patrol.sh shared/loops/roster-patrol/roster-patrol-alias-audit.sh shared/tests/roster-patrol-alias-test.sh
bash shared/tests/roster-patrol-alias-test.sh
bash shared/loops/roster-patrol/roster-patrol-alias-audit.sh
git diff --check
```

Formal verifier result: 1/1 PASS (`formal-verify.txt`). The maintainer may apply the reviewed commit only after approval and then run the same no-argument audit on the production checkout; no builder-side host apply or service restart is authorized.

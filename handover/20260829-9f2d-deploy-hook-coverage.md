# 9f2d deploy-hook coverage delivery

## Read-only production observation

Observed at 2026-08-29T09:2x+08:00 before any production mutation:

- `.claude-bots`: `{"task_id":"20260829-0016-93eb-rejected-state-cancel-dispatch-asymmetry","commit":"421f5ecaad7869c5d043c9fa8a4d51e4875c7990","approved_by":"yitang","ts":"2026-08-28T22:05:49Z"}`
- `infra`: `{"task_id":"20260808-1301-3d1a-relay-origin-inventory-completeness","commit":"c98262a074546f889a88a5bd3fa5c7b36a53658f","approved_by":"bella","ts":"2026-08-08T08:19:53Z"}`
- `pod-system`: `{"task_id":"20260808-1301-3d1a-relay-origin-inventory-completeness","commit":"89db3e120d810a63e24d44f4ae8c474bf9627819","approved_by":"bella","ts":"2026-08-08T08:19:42Z"}`
- `shared/memocean-mcp`: `{"task_id":"20260803-0227-c28c-deploy-sh-pep668-user-branch-untested","commit":"d71c2bc32eac2bfad60a7a6f78417011db202c20","approved_by":"bella","ts":"2026-08-02T18:42:47Z"}`

The four tokens were deliberately **not cleared during builder delivery** and
no production hook was installed. Production red lines require reviewer
approval first. After approval, an authorized maintainer runs
`bash shared/bin/deploy-hook-rollout.sh --apply`; its timestamped evidence file
captures every token before clearing any, confirms all four absent, and only
then installs the four hooks. The hard phase barrier is fixture-tested.

## No-op before/after

Pre-fix throwaway fixture, actual output, exit 0, token remained present:

```text
[fatq-deploy-gate] GATE PASS task=t-noop approved_by=yitang target=de944837152d399e7366ea63b98d8e85b8fbc4a4 — merging into /tmp/9f2d-prefix.mj6GFy/repo
Already up to date.
[fatq-deploy-gate] DEPLOYED task=t-noop commit=de944837152d399e7366ea63b98d8e85b8fbc4a4 approved_by=yitang repo=/tmp/9f2d-prefix.mj6GFy/repo
```

Post-fix fixture output is printed by `deploy-hook-coverage-test.sh`: it exits
0, contains `NO-OP ... reason=already-up-to-date`, removes the invocation's
token, and asserts `grep -c DEPLOYED == 0` separately for combined invocation
output and `fatq-deploy.log`. `NO-OP` and `DEPLOYED` therefore cannot coexist in
that invocation or its log entries.

## Security invariants

This change does not broaden anyone's deployment permission, add a bypass, or
weaken the existing `tasks/done` and `verdict_approve` checks. The existing
break-glass behavior is unchanged. Under the production FATQ root, an off-list
repo is refused before token creation. Fixture roots remain available solely
for isolated tests.

The coverage audit is expected to remain red on production until the approved
host rollout. It reports each missing/non-executable hook and exits nonzero.

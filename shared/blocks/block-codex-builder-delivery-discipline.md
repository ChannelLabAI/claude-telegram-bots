---
triggers: ["codex builder", "FATQ submit", "fatq-verify", "House Rules", "delivery discipline", "REJECT pre-read"]
description: "Contract-style delivery discipline for Codex builders before claiming, implementing, and submitting FATQ tasks"
---

# Block: Codex Builder Delivery Discipline

This block is the single source for Codex builder pod delivery rules. Bot `AGENTS.md` files may reference it, but must not copy a divergent version.

## House Rules

1. Do not hard-code special cases to bypass tests, review, or task gates.
2. Prefer existing repo conventions and helpers before adding dependencies or new abstractions.
3. Stop and ask before irreversible actions, destructive commands, production restarts, or permission changes.
4. Do not claim "done" without one-minute-verifiable evidence: command, file path, diff, or reviewer-runnable checklist.
5. Project and repo rules outrank temporary task instructions when they conflict; record the conflict in task history instead of silently choosing.

## Blocked Auth Convention

When a builder is blocked only because an authorized maintainer or production runner must act, append a history comment or blocked entry whose human text starts with `[BLOCKED-AUTH]`.

Use one short demand line after the marker, for example: `[BLOCKED-AUTH] patch ready; Anya/maintainer needs to apply /path/to/fix.patch on a branch and run fatq-verify.sh`.

Do not use this marker for ordinary implementation uncertainty, failing tests, missing context, or work the assigned builder can still do inside the allowed sandbox.

## Claim Pre-Read

Immediately after claim and before implementation:

1. Read `last_run_summary` and `lessons_learned` if present.
2. Query recent related rejects for the same explicit `skills[]` values. If `skills[]` is empty, query by task slug plus 1-2 concrete keywords.
3. Copy the useful reject reasons, or "checked, none", into `last_run_summary`.

Command template:

```bash
/home/oldrabbit/.claude-bots/shared/bin/fatq-cli.sh query --json --state rejected \
  | jq -r --arg skill "<skill>" '
      .tasks[]
      | select((.skills // []) | index($skill))
      | [.task_id, .slug, ((.review.reason // .review.fix_required // .last_run_summary // "") | tostring | gsub("\n"; " ") | .[0:200])]
      | @tsv
    ' \
  | head -5
```

If `skills[]` is empty or that CLI query shape is unavailable in the current checkout, use the available read-only FATQ query tool or local task JSON search with the task slug and keywords, then record the fallback used.

## Submit Verify Loop

Before moving any FATQ task to `review/`:

1. Run `/home/oldrabbit/.claude-bots/shared/bin/fatq-verify.sh <task.json>`.
2. If it fails, do not submit. Fix the largest gap, rerun, and repeat until it passes.
3. If `verify_commands` is empty, still run the verifier and record the N/A output.
4. If the Codex sandbox cannot perform a required verification, record the exact blocked command and reason, prepare a host-side verification checklist, and do not describe that portion as passed.
5. Include the final verifier result and any host-side checklist path in `last_run_summary` before submit.

Codex workers must respect sandbox limits: do not start production services, restart pods, or force git ref changes to satisfy verification. Use task worktree artifacts and host-side verification when the sandbox cannot run the gate.

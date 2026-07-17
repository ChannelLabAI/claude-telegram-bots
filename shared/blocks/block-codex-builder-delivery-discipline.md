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

## Relay Reply Convention

This applies only to relay messages that explicitly ask the headless Codex bot to answer back by relay. Examples include `回我 relay`, `回覆給 @xxx`, `relay 回報`, or equivalent wording from the sender. Do not treat every relay as requiring a relay reply.

When such an instruction is present, keep the normal owner-facing final reply and also write a return relay JSON under `/home/oldrabbit/.claude-bots/relay/`. The relay payload must use the sender's internal bot name as `recipient`, not the Telegram `@username`; this is the stable route before and after handle-routing fixes. Use `from_bot` as your own internal bot name, `text` as a conclusion summary of 500 characters or less, `ts` generated at write time, and write by `.tmp` then atomic `mv`.

Example:

```json
{
  "from_bot": "sancai",
  "recipient": "anya",
  "text": "已完成 relay 要求：補上 Codex builder 回程 relay 約定，驗證 symlink 完好；任務已送 review。",
  "ts": "2026-07-17T16:30:00+08:00"
}
```

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

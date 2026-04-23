# skill-loop-runtime v0.2

> **Disambiguation**: `shared/skill-loop-runtime/` (this directory) is the **canonical** runtime — security-reviewed by Bella (CR-20260408), merged by Eric.
> `shared/skills-loop/` is the earlier PoC (`skill_manager.py`) — superseded by this library, kept for reference.

Runtime layer over 三菜's `learned-skills/` schema. Ports Anna's PoC
(`done/24643`) and closes Bella's six security concerns from CR-20260408.

## What this is

A small library (`main.py`, stdlib-only) that lets a bot:

1. Record a `TaskTrace` after finishing a task.
2. Ask an LLM whether the trace deserves to become a reusable skill.
3. If yes, synthesize a draft skill and write it to `_drafts/{slug}/`
   as three markdown files (`SKILL.md`, `USAGE.md`, `EXAMPLE.md`) — the
   exact shape 三菜's schema specifies. No YAML frontmatter, no invented
   metadata fields.
4. At the start of the next task, search `approved/` for relevant skills
   and inject them into the system prompt.

The runtime NEVER writes to `approved/` or `_archive/`, NEVER mutates
`index.md`, and NEVER promotes drafts. Promotion is human-only.

## Architecture

```
  TaskTrace ──► _sanitize_text (a: input)
                     │
                     ▼
              _should_create_skill (LLM YES/NO)
                     │
                     ▼
              _generate_skill (LLM → JSON)
                     │
                     ▼
              _sanitize_text (b: LLM output) + _validate_slug
                     │
                     ▼
              _write_draft  ──► learned-skills/_drafts/{slug}/
                                     │
                                     ▼
                           (human review, manual mv)
                                     │
                                     ▼
                              learned-skills/approved/{slug}/
                                     │
                                     ▼
                     load_all_skills ──► search_skills
                                     │
                                     ▼
                     inject_context + _sanitize_text (c: re-injection)
                                     │
                                     ▼
                              bot system prompt
```

## Security model — how the 6 concerns are closed

| # | Concern | Fix |
|---|---------|-----|
| 1 | Prompt injection via trace fields / LLM output / re-injection | `_sanitize_text` applied at all three boundaries: input, LLM output, re-injection. Rejects 13 injection markers (case-insensitive), strips code fences, caps at 8 KB, rejects C0 control bytes. |
| 2 | Category allowlist / path traversal | 三菜's schema has NO `category` field, so the original allowlist concern collapses. We instead enforce `_validate_slug` (regex `^[a-z][a-z0-9-]{1,62}$`) before every path join, which blocks `../`, absolute paths, uppercase, and weird characters. |
| 3 | Review gate bypass | `_write_draft` is the only writer and hard-codes `_drafts/`. `promote_to_approved` always raises `PermissionError`. Runtime self-check at `__init__` asserts `_drafts/` and `approved/` exist and refuses to start otherwise. |
| 4 | `_llm()` crashes on missing CLI / timeout | `_llm` checks `shutil.which("claude")`, wraps `subprocess.run` in try/except, returns `None` on any failure. All callers treat `None` as "skip". |
| 5 | `_improve_skill` string-replace corruption | `_improve_skill` does a whole-file rewrite: LLM returns either `NO_CHANGE` or a full new SKILL.md, which is sanitized, re-parsed, re-rendered, and atomically written via `_write_draft`. Refuses to improve approved skills (raises `NotImplementedError`). |
| 6 | `usage_count` needed without violating schema | Lives in sidecar `usage.json` under the runtime dir, not in the skill markdown. Bumped atomically by `inject_context`. |

## Sidecar `usage.json`

三菜's schema forbids inventing markdown frontmatter, so usage telemetry
lives in `~/.claude-bots/shared/skill-loop-runtime/usage.json`:

```json
{
  "my-skill-slug": {
    "usage_count": 3,
    "version": 1,
    "last_used": "2026-04-07T12:34:56+00:00"
  }
}
```

**Known limitation**: the sidecar is written via tmp + `os.replace`
(atomic per-write) but is NOT concurrent-safe. Two bots writing at the
same time can clobber each other's counter increments. v0.3 will add a
file lock or move to SQLite.

## What is NOT done in v0.2

- Improving skills that already sit in `approved/` (human review of
  improvements isn't designed yet — `_improve_skill` raises
  `NotImplementedError` for that path).
- Concurrency safety on `usage.json`.
- Integration with `team-config.json` — waiting on Anna's ticket 2.
- Wiring into Anya's after-task hook — that's Bella's call, not this PR.

## Run tests

```
python -m pytest tests/ -v
```

Tests use `tmp_path` and never touch the real
`~/.claude-bots/shared/learned-skills/` tree.

## Credits

- Schema: 三菜 (done/24837)
- Original PoC runtime: Anna (done/24643)
- Security review (6 concerns): Bella (CR-20260408)
- v0.2 merged runtime: Eric

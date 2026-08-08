# Bot roster consistency inventory — 2026-08-08

Scope: role-definition directories under `bots/`, the authority roster in
`shared/config/bot-routing.yml`, and `BOT_MAP` in `shared/bin/fatq-dispatch.sh`.
The inventory deliberately treats either `CLAUDE.md` or `AGENTS.md` as a role
definition. Evidence command:

```bash
find bots -mindepth 2 -maxdepth 2 \( -name CLAUDE.md -o -name AGENTS.md \) -printf '%h/%f\n' | sort
```

## Result and responsibility

The identity map has one row for all 20 discovered directories. `sara` and
`spark` are included from their `AGENTS.md` files even though neither has a
`CLAUDE.md`; this is the regression the check protects.

| Source relationship | Finding | Owner / action |
| --- | --- | --- |
| `bots/` → identity map | No orphan after this change; a new role-definition directory without a map row is a check failure. | Bot creator updates the map and authority roster. |
| identity map → authority roster | No dead `roster_id` after this change. | Maintainer of `bot-routing.yml`. |
| identity map → dispatch | Eight directories intentionally have no `dispatch_key`: `buddy`, `elon`, `fengfeng`, `huizhang`, `keeper`, `panda`, `zhanglinghe`, `zhuchu`. | No change: these are assistants/company agent/strategist, not direct FATQ assignees. |
| dispatch → `bots/` | `ron-builder` and `星星人` are compatibility aliases for `eric` and `twinkle`, respectively. | Anya decides any future alias-removal task; do not alter production dispatch here. |

## Baseline gaps made explicit

Before this inventory, the routing sections had 8 entries: Anna, Sancai, Eric,
Bella, Yitang, KK, Twinkle, and Sara. Twelve actual role-definition directories
were consequently absent from the only readable roster: `anya`, `buddy`,
`elon`, `fengfeng`, `huizhang`, `keeper`, `orange`, `panda`, `spark`,
`stargazer`, `zhanglinghe`, `zhuchu`. They are now registered in `bot_roster`;
they are intentionally not all routed as Builder/Reviewer/Designer workers.

The legacy naming differences are also explicit in
`shared/config/bot-identity-map.yml`: `kk` ↔ `ron-reviewer` and `twinkle` ↔
`nicky-builder`; historical directory names for the assistant bots are notes,
not dispatch changes.

## Reviewer reproduction

```bash
bash shared/tests/bot-roster-consistency.sh
bash shared/tests/bot-roster-consistency-test.sh
```

The second command demonstrates both required red cases: removing Sara's map
row reports the `sara` orphan; changing Anna to a nonexistent `roster_id`
reports the dead pointer. It then exits successfully only because those failures
were expected assertions.

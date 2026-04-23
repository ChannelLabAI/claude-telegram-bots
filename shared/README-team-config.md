# team-config.json — Central Team Configuration

`~/.claude-bots/shared/team-config.json` is the single source of truth for all team settings that used to be scattered across multiple bot files.

## Why This Exists

On 2026-04-07, the Telegram main team group was upgraded to a supergroup, changing its `chat_id`. We had to update 6+ files manually. On the same day, Eric/KKKK joining the shared pool required 5+ changes. With this file, future changes require editing **one file only**.

## What It Contains

| Section | Contents |
|---------|----------|
| `owners` | 老兔/Ron/Nicky/菜姐/桃桃/川哥 + their Telegram user_ids |
| `assistants` | 5 special assistants (Anya/Panda/張凌赫/主廚/Elon) + their bots |
| `shared_pools.builder` | Anna, 三菜, Eric — with owner affinity |
| `shared_pools.reviewer` | Bella, 一湯, KKKK — with owner affinity |
| `shared_pools.designer` | 星星人 |
| `owner_preferences` | Which pool to use first for each owner |
| `groups` | All group chat_ids with labels |
| `dms` | All owner Telegram user_ids |

## How to Read It

### Shell (in start.sh or hooks)

```bash
MAIN_TEAM=$(~/.claude-bots/shared/scripts/team-config-get.sh groups.main_team.chat_id)
LT_DM=$(~/.claude-bots/shared/scripts/team-config-get.sh dms.lt)
```

### Python (in bot code)

```python
import sys
sys.path.insert(0, str(Path("~/.claude-bots/shared/lib").expanduser()))
from team_config import cfg

main_team = cfg.main_team_id          # "-1003634255226"
lt_dm = cfg.dm("lt")                  # "1050312492"
builders = cfg.builder_pool           # [{"name": "Anna", ...}, ...]
anna_username = cfg.bot_username("anna")  # "annadesu_bot"
```

### Direct jq (one-off)

```bash
jq '.groups.main_team.chat_id' ~/.claude-bots/shared/team-config.json
jq '[.shared_pools.builder[].name]' ~/.claude-bots/shared/team-config.json
```

## How to Update

### Adding a new shared pool member

1. Edit `shared_pools.builder` (or reviewer/designer) in `team-config.json`
2. Add their `name`, `bot_username`, `state_dir`, and `affinity`
3. Update `owner_preferences` if affinity changed
4. Run `bash shared/scripts/sync-team-config.sh --dry-run` to preview
5. Run without `--dry-run` to apply to all `access.json` files
6. Tell Anya to restart affected bots (they read config at startup)

### Changing a group chat_id (e.g., supergroup upgrade)

1. Update the relevant entry in `groups{}` in `team-config.json`
2. Run `bash shared/scripts/sync-team-config.sh` to propagate to all `access.json` files
3. Update `bots/CLAUDE.md` references manually (sync script doesn't touch CLAUDE.md)
4. Restart affected bots

### Adding a new owner

1. Add to `owners{}` with `name`, `user_id`, `role`
2. Add to `dms{}` with their `user_id`
3. Add to `owner_preferences{}` with their preferred builder/reviewer pools
4. Add their assistant to `assistants[]`

## Who Needs to Restart After a Change

| Change type | Who restarts |
|------------|--------------|
| Group chat_id | All bots that were in that group |
| Pool membership | The changed bot (it reads its own role from config) |
| Owner preferences | Anya + other dispatch-capable bots |
| DM/owner user_id | Only affects dmPolicy allowlists; update access.json separately |

## Known TODOs

- [ ] Confirm `bot_username` for 主廚 and Elon (currently `null`)
- [ ] Verify `lt_command` chat_id: might have upgraded to supergroup (currently `-5267778636`, possible new ID: `-1005267778636`)
- [ ] Wire `team_config.py` into Anya's dispatch logic (replace hardcoded pool lists)
- [ ] Add weekly cron lint: check for hardcoded chat_ids inconsistent with team-config.json

# roster-patrol

Read-only roster consistency patrol for ChannelLab bot identity drift.

It compares:

- `shared/team-config.json` assistants and shared pools
- `bots/*/CLAUDE.md` directories
- `pod-system/pods/*.json` bot entries
- `shared/team-config.json` `external_identities` coverage for referenced `*-gate` identities

The patrol writes only its own reports/logs under `logs/roster-patrol/` and alert relay files under `relay/`. It never edits roster, bot, or pod configuration.

## Cron

Install after review/deploy:

```bash
/home/oldrabbit/.claude-bots/shared/loops/roster-patrol/install-cron.sh
```

The cron entry is:

```cron
10 9 * * * PATH=/home/oldrabbit/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/flock -n /tmp/cron-roster-patrol.lock bash /home/oldrabbit/.claude-bots/shared/loops/roster-patrol/roster-patrol.sh >> /home/oldrabbit/.claude-bots/logs/roster-patrol/cron.log 2>&1
```

This uses the system crontab, so it survives process restarts and host reboots. It is intentionally not a `CronCreate` runtime schedule.

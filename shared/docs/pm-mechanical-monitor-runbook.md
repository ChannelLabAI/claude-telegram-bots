# pm-hub mechanical monitor trial

This is a two-week, alert-only trial. The three jobs remain owned by the
`oldrabbit` crontab. The monitor never runs a repair command and does not move
cron ownership to Diana.

After Bella approves both the root patch and the pm-hub heartbeat patch, Anya
may replace only the three existing command bodies with the status wrapper and
add the monitor line:

```cron
0 9 * * * /home/oldrabbit/.claude-bots/shared/scripts/pm-mechanical-run.sh pipeline -- python3 /home/oldrabbit/bin/pm-pipeline.py >> /home/oldrabbit/logs/pm-pipeline.log 2>&1
5 9 * * * /home/oldrabbit/.claude-bots/shared/scripts/pm-mechanical-run.sh render -- python3 /home/oldrabbit/pm-hub/render/render.py >> /home/oldrabbit/logs/pm-render.log 2>&1
*/3 * * * * /home/oldrabbit/.claude-bots/shared/scripts/pm-mechanical-run.sh reconcile -- python3 /home/oldrabbit/pm-hub/render/reconcile_lark.py >> /home/oldrabbit/logs/pm-reconcile.log 2>&1
*/3 * * * * /usr/local/bin/bun run /home/oldrabbit/.claude-bots/shared/scripts/pm-mechanical-monitor.ts >> /home/oldrabbit/logs/pm-mechanical-monitor.log 2>&1
```

Do not apply with text substitution alone: first compare the host's current
three entries and preserve their schedule, environment and redirections. Save
before/after `crontab -l` evidence proving the owner is unchanged.

Fault gate: use a temporary fixture state/relay directory or a reviewer-approved
single-run non-zero command. Confirm one relay enters `relay-diana/read/` and a
matching JSON enters `bots/diana/inbox/messages/`. Never disable a production
job merely to prove staleness.

At the end of 14 days, generate the decision report without changing state:

```bash
bun run /home/oldrabbit/.claude-bots/shared/scripts/pm-mechanical-monitor.ts --report
```

The report supplies check count, healthy rate and emitted-alert count. Old
Rabbit then decides in a separate task whether cron ownership should migrate.

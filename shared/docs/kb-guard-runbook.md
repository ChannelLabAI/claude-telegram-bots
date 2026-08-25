# KB Guard runbook

`kb-guard` watches the Bonk GEO and Transtar Lark Wiki trees without editing
them. K1/K4 are event driven by `kb-guard-watch.service`; K2/K3 run from the
daily crontab safety net. Every Lark content request in the guard is GET-only.

## Output boundary

- This component only detects drift and prints structured findings/suggestions.
  Daily cron and the event watcher append those results to the guard log.
- Delivery paths (Telegram, relay, inbox) and their severity routing are not
  decided here. They require a separately valid wake-path test and policy task.

## Commands

```bash
shared/bin/kb-guard.sh daily
shared/bin/kb-guard.sh watch
shared/bin/kb-guard.sh fetch --out /tmp/kb-snapshot.json
bash shared/tests/kb-guard-test.sh
```

The fixture HTTP map exists only for deterministic offline tests. Production
daily runs make real HEAD requests to configured pm-hub links and read raw Lark
blocks for attachment tokens.

## Safety

The guard never repairs links, creates nodes, edits pages, touches Bitable, or
writes KB content back to truth. A finding is evidence plus a suggestion for a
human steward. Do not add a Lark write method to this program.

# Diana groom dual track

The resident `relay-listener` watches `pm-hub/projects/*.md` and invokes the
event track. Every newly appended log entry becomes an existing `diana:task`
signal, is routed through `relay-diana`, and lands in the diana-chat disk inbox.
No new Diana signal type is introduced.

The independent cron safety net runs at 09:20, after the 09:00 pipeline. It
replays log additions from the last 24 hours and scans current project files.
The persistent entry fingerprint prevents the event and safety-net tracks from
processing the same input twice. A queued input is retried after one hour if it
was never applied.

`apply` is the write boundary. Diana supplies a complete candidate project
file. The guard refuses it unless all historical log entries remain an exact,
ordered prefix, exactly one traceable `[整理]` entry is appended, and a
structural section changes. The script commits only that project file with
author `diana <diana@local>`.

After Bella approves this task and its 6dd7 dependency, Anya runs:

```bash
/home/oldrabbit/.claude-bots/shared/bin/diana-groom.sh init
/home/oldrabbit/.claude-bots/shared/bin/install-diana-groom-cron.sh
```

Then reload/restart `keeper-diana.service` in an attended window and verify:

```bash
test -x /home/oldrabbit/.claude-bots/shared/bin/diana-groom.sh
crontab -l | grep -q diana-groom
```

`init` is intentionally mandatory before either track starts: it fingerprints
the existing history without sending it, preventing first-deploy backlog spam.

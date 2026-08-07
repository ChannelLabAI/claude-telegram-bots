# Tech radar feed filter

`shared/bin/tech-radar.py` reads the configured feeds, processes only items
newer than each source's GUID/time watermark, applies the readable topic rules,
and sends only matches to the existing Mattermost `#agent-comms` channel with
`@Anyachl_bot`. Mattermost was chosen because it is already used by scheduled
infra loops and gives Anya one visible triage queue; this adds no channel.

The watermark JSON stores only `guid` and `published_at`. Feed descriptions and
article bodies are neither fetched nor written. Non-matches are printed for the
current run and discarded. When an old watermark GUID has fallen outside the
feed and the oldest visible item is newer than that watermark, the script emits
and sends a `GAP` warning before advancing the watermark.

## Host run after QA approval

The registry entry stays `planned` until Anya installs the schedule. Suggested
daily host invocation (time chosen by the maintainer after checking cron load):

```bash
/home/oldrabbit/.claude-bots/shared/bin/tech-radar.py \
  --config /home/oldrabbit/.claude-bots/shared/config/tech-radar.json \
  --state /home/oldrabbit/.claude-bots/logs/tech-radar-watermark.json
```

The first approved host run intentionally evaluates the current visible feed.
Use `shared/tests/tech-radar-fixture.sh` for offline QA; its notifier is stubbed
at `shared/tests/fixtures/tech-radar/notify-stub.sh` and cannot post to
Mattermost.

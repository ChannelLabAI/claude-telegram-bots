# inotify-watch — ChannelLab FATQ（File-Atomic Task Queue）Watcher

Watches `~/.claude-bots/tasks/` with OS-level inotify events and injects a notification into the right bot's inbox the moment a task file lands, replacing per-bot cron polling with event-driven delivery.

## What it does

When a `.json` file appears in `tasks/pending/` or `tasks/rejected/`, the daemon reads its `assigned_to` field and writes a notification into `~/.claude-bots/bots/{bot}/inbox/messages/`. Files arriving in `tasks/review/` are always routed to Bella. The existing `inbox-inject.sh` PostToolUse hook picks up the notification on the next tool call, delivering it as a `<channel>` tag to the bot's Claude session.

## Start / Stop / Status

```bash
# Check status
systemctl --user status channellab-inotify-watch.service

# Start
systemctl --user start channellab-inotify-watch.service

# Stop
systemctl --user stop channellab-inotify-watch.service

# Restart
systemctl --user restart channellab-inotify-watch.service

# Enable autostart on login
systemctl --user enable channellab-inotify-watch.service

# Disable autostart
systemctl --user disable channellab-inotify-watch.service
```

## Screen fallback (no systemd user session)

If `systemctl --user` fails with "Failed to connect to bus: No such file or directory", use screen:

```bash
screen -dmS inotify-watch bash ~/.claude-bots/shared/inotify-watch.sh
# Check it's running:
screen -list | grep inotify
# Attach to inspect:
screen -r inotify-watch
# Detach: Ctrl+A, D
# Stop:
screen -S inotify-watch -X quit
```

## Log location

```
~/.claude-bots/logs/inotify-watch.log
```

Tail live:

```bash
tail -f ~/.claude-bots/logs/inotify-watch.log
```

## Adding a new bot

Edit the `BOT_STATE_DIR` associative array in `~/.claude-bots/shared/inotify-watch.sh`:

```bash
# Add both the assigned_to value used in task JSON and the state_dir name
["newbot"]="newbot-state-dir"
["newbot-state-dir"]="newbot-state-dir"   # passthrough alias (optional)
```

Then restart the daemon:

```bash
systemctl --user restart channellab-inotify-watch.service
```

No reload needed — the daemon reads the script at startup.

## Troubleshooting

### inotifywait not found

```bash
which inotifywait || sudo apt install inotify-tools
```

The script expects it at `/usr/bin/inotifywait`. If it's elsewhere, update the `INOTIFYWAIT=` line near the top of `inotify-watch.sh`.

### Inbox dir missing for a bot

The daemon will log a `WARN` and skip injection rather than crashing:

```
WARN: inbox dir not found for state_dir=somebot, skipping (file=...)
```

Create the directory to fix it:

```bash
mkdir -p ~/.claude-bots/bots/{bot-name}/inbox/messages
```

### JSON parse errors

If a task file is malformed, the daemon logs:

```
WARN: JSON parse error for /path/to/file.json, skipping
```

Inspect the file: `python3 -m json.tool /path/to/file.json`

### Unknown assigned_to value

```
WARN: unknown assigned_to='somevalue' in /path/to/file.json, skipping
```

Add the mapping to `BOT_STATE_DIR` in `inotify-watch.sh` and restart the service.

### Daemon died / not injecting

```bash
# Check service status and recent logs
systemctl --user status channellab-inotify-watch.service
tail -20 ~/.claude-bots/logs/inotify-watch.log

# Restart if needed
systemctl --user restart channellab-inotify-watch.service
```

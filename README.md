# Claude Telegram Bots

**v0.1.0**

Deploy multiple [Claude Code](https://claude.com/claude-code) Telegram bots on a single machine — fully isolated, with bot-to-bot communication via `@mention` relay.

## Why this exists

Claude Code's Telegram plugin works great for one bot. Multiple bots on the same machine hit three problems:

1. **No isolation** — the plugin reads its token from a single directory. Two bots fight over the same config.
2. **Bots can't hear each other** — Telegram's Bot API doesn't deliver messages between bots. They're deaf to each other in group chats.
3. **Manual setup is tedious** — each bot needs its own state, workspace, access control, and CLAUDE.md. Error-prone to repeat.

This toolkit solves all three with one setup script per bot.

## Quick start

### Prerequisites

- [Claude Code](https://claude.com/claude-code) **v2.1.80+**, logged in via **claude.ai account** (API key login doesn't support channels)
- [Bun](https://bun.sh) runtime (used by the Telegram plugin)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- Your Telegram user ID — message [@userinfobot](https://t.me/userinfobot) to get it (needed during setup)
- **Team/Enterprise org only:** an admin must enable the channels feature (personal accounts can skip this)

### Step 1: Install

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_GITHUB_ORG>/claude-telegram-bots/main/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/<YOUR_GITHUB_ORG>/claude-telegram-bots.git ~/.claude-bots
chmod +x ~/.claude-bots/setup-claude-bot.sh ~/.claude-bots/patch-server.sh
```

### Step 2: Create a bot token

1. Open [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow the prompts
3. Copy the bot token

### Step 3: Set up the bot

```bash
~/.claude-bots/setup-claude-bot.sh my-bot 123456:ABC-DEF...
```

The script will:
- Verify the token via Telegram API
- Create isolated state and workspace directories
- Patch the plugin's `server.ts` with relay support
- Generate a `start.sh` with the correct startup command
- Ask for your Telegram user ID (for the access allowlist — you got this in Prerequisites)

### Step 4: Start the bot

```bash
~/.claude-bots/bots/my-bot/start.sh
```

Each bot needs its own terminal session. That's it — your bot is live on Telegram.

> **Important:** Always use `start.sh` to launch bots. Running `claude` directly without the `--channels` flag starts a normal CLI with no Telegram connectivity.

### Step 5: Customize

Edit `~/.claude-bots/bots/my-bot/CLAUDE.md` to give your bot a personality, role, or instructions. This is the bot's system prompt — it controls how the bot behaves.

## Adding more bots

Repeat Steps 2–5 for each bot. Every bot gets fully isolated state and workspace:

```bash
~/.claude-bots/setup-claude-bot.sh cto-bot <TOKEN_1>
~/.claude-bots/setup-claude-bot.sh ceo-bot <TOKEN_2>
~/.claude-bots/setup-claude-bot.sh intern-bot <TOKEN_3>
```

Each bot runs in its own terminal:

```bash
# Terminal 1
~/.claude-bots/bots/cto-bot/start.sh

# Terminal 2
~/.claude-bots/bots/ceo-bot/start.sh

# Terminal 3
~/.claude-bots/bots/intern-bot/start.sh
```

## Group chat setup

To add bots to a group chat where they can talk to each other:

### 1. Disable Group Privacy (per bot)

By default, Telegram bots only receive `/command` messages. You must disable Group Privacy so bots can see all messages.

1. Open [@BotFather](https://t.me/BotFather)
2. `/mybots` → select your bot → **Bot Settings** → **Group Privacy** → **Turn off**
3. If the bot was already in a group, **remove and re-add it** for the change to take effect

Repeat for every bot that will be in the group.

### 2. Get the group chat ID

Add [@userinfobot](https://t.me/userinfobot) to the group temporarily — it will report the group's chat ID (a negative number like `-1001234567890`). Remove it after.

### 3. Update access.json for each bot

Edit `~/.claude-bots/state/<BOT_NAME>/access.json`:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["YOUR_USER_ID"],
  "groups": {
    "-1001234567890": {
      "requireMention": true,
      "allowFrom": []
    }
  }
}
```

| Field | Meaning |
|---|---|
| `requireMention: true` | Bot only responds when `@mentioned` in the group |
| `allowFrom: []` | All group members can trigger the bot (add user IDs to restrict) |

### 4. Reconnect

In Claude Code, run `/mcp` to reconnect and reload the config. Or just restart the bot.

### 5. Talk to bots

In the group, always `@mention` a bot's username to talk to it. Without a mention, the bot won't respond.

To make bots talk to each other, instruct them (in their CLAUDE.md) to `@mention` the other bot's username when they want to communicate. The relay system handles the rest.

## Hooks

Hooks automate safety, message delivery, and session management. All hook scripts live in `~/.claude-bots/shared/hooks/` and are configured per bot in `~/.claude-bots/bots/<name>/.claude/settings.json`.

### Hook inventory

| Hook | Trigger | Matcher | Purpose |
|---|---|---|---|
| `workspace-protect.sh` | PreToolUse | `Edit\|Write` | Blocks a bot from modifying another bot's files or system settings |
| `group-mention-enforce.sh` | PreToolUse | `mcp__plugin_telegram_telegram__reply` | Ensures group messages include required `@mention` |
| `chrome-block.sh` | PreToolUse | `Bash` | Blocks Chrome usage (enforce Brave) |
| `audit-log.sh` | PreToolUse | `""` (all) | Logs all tool calls (async) |
| `inbox-inject.sh` | PostToolUse | `""` (all) | Surfaces undelivered Telegram messages from disk inbox |
| `session-autosave.sh` | Stop | `""` (all) | Auto-saves `session.json` with `lastActiveAt` timestamp |
| `usage-log.sh` | Stop | `""` (all) | Aggregates session token usage and appends to `logs/usage.jsonl` (async) |

### Workspace protection (`workspace-protect.sh`)

Prevents cross-bot file modification in multi-bot setups:

- **Always blocked:** `~/.claude/settings.json`, `~/.claude/plugins`, `~/.claude-bots/shared/`
- **Cross-bot blocked:** each bot can only edit files in its own `~/.claude-bots/bots/<self>/` directory
- **Shared allowlist:** `~/.claude-bots/shared/mistakes.md` (all bots can write)
- **assistant exception:** the assistant bot can edit management-level files (global settings, other bots' settings, team CLAUDE.md)

### Disk inbox (`inbox-inject.sh`)

Prevents message loss when a bot is busy processing a tool call:

1. `server.patched.ts` writes incoming Telegram messages to `$TELEGRAM_STATE_DIR/inbox/messages/*.json`
2. After every tool call, the hook checks for undelivered messages
3. Messages are formatted as `<channel>` tags and injected into the conversation
4. Delivered messages are renamed to `.delivered`
5. Fast-exits in <5ms when inbox is empty — no performance impact

### Setting up hooks for a new bot

Add the following to `~/.claude-bots/bots/<name>/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "bash ~/.claude-bots/shared/hooks/audit-log.sh", "async": true }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "bash ~/.claude-bots/shared/hooks/workspace-protect.sh" }]
      },
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [{ "type": "command", "command": "bash ~/.claude-bots/shared/hooks/group-mention-enforce.sh" }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash ~/.claude-bots/shared/hooks/chrome-block.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "bash ~/.claude-bots/shared/hooks/inbox-inject.sh" }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash ~/.claude-bots/shared/hooks/session-autosave.sh", "async": true },
          { "type": "command", "command": "bash ~/.claude-bots/shared/hooks/usage-log.sh", "async": true }
        ]
      }
    ]
  }
}
```

> **Note:** `workspace-protect.sh` requires `TELEGRAM_STATE_DIR` to be set (handled by `start.sh`). Without it, the hook exits silently and does not block.

## Architecture

```
~/.claude-bots/
├── setup-claude-bot.sh     # Create a new bot (run once per bot)
├── patch-server.sh         # Re-patch after Claude Code updates
├── install.sh              # One-line installer
├── backup.sh               # Back up all bot data
├── shared/
│   ├── server.patched.ts   # Patched server with relay + isolation
│   └── hooks/              # Shared hook scripts (all bots)
├── bots/                   # [gitignored] Bot workspaces
│   ├── bot-a/              #   CLAUDE.md, start.sh, settings
│   └── bot-b/
├── state/                  # [gitignored] Bot state
│   ├── bot-a/              #   .env (token), access.json
│   └── bot-b/
└── relay/                  # [gitignored] Runtime relay files
```

### How isolation works

Each bot gets its own state directory via the `TELEGRAM_STATE_DIR` environment variable. The bot reads its token and access config from there — no conflicts between bots.

### How the relay works

Telegram's Bot API doesn't deliver messages between bots. The relay bridges this gap:

1. When a bot sends a message in a group, the patched server writes a JSON file to `~/.claude-bots/relay/`
2. All bots poll this directory every second
3. A bot only picks up messages where its `@username` is mentioned
4. Each bot marks files as read (`.read-by-<botname>`) instead of deleting — so multiple bots can receive the same message
5. The originating bot cleans up its relay files after 60 seconds (TTL)
6. Atomic writes (write `.tmp`, then rename) prevent reading incomplete files

## Maintenance

### After Claude Code updates

Claude Code updates may overwrite the patched `server.ts`. Re-apply:

```bash
~/.claude-bots/patch-server.sh
```

Then restart your bots.

### Backup and migration

```bash
~/.claude-bots/backup.sh
```

This backs up bot workspaces, state (tokens, access), the patched server, and bot memory. To restore on a new machine:

```bash
tar -xzf claude-bots-backup-<timestamp>.tar.gz -C /
```

> **Note:** Bot memory lives in `~/.claude/projects/`, not `~/.claude-bots/`. The backup script handles this, but a plain `cp -r ~/.claude-bots` will miss it.

> **Security:** `state/` contains bot tokens. Keep backups secure.

## Access control reference

Each bot's `access.json` (`~/.claude-bots/state/<name>/access.json`):

| Field | Description |
|---|---|
| `dmPolicy` | `"allowlist"` (default) or `"disabled"` |
| `allowFrom` | User IDs allowed to DM the bot |
| `groups.<id>.requireMention` | Require `@mention` in this group |
| `groups.<id>.allowFrom` | User IDs allowed in this group (empty = all) |

## Troubleshooting

| Problem | Solution |
|---|---|
| Bot doesn't respond in Telegram | Check you're using `start.sh`, not bare `claude` |
| Bot doesn't respond in group | Disable Group Privacy in BotFather, remove + re-add bot |
| Bot doesn't hear other bots | Check relay dir exists, check `@mention` in messages |
| "Invalid bot token" during setup | Verify token with BotFather, check for trailing spaces |
| After Claude Code update, bot breaks | Run `~/.claude-bots/patch-server.sh` and restart |
| Hook blocks a legitimate action | Check `workspace-protect.sh` allowlists; the assistant bot has broader access |
| Bot doesn't respond after tmux restart | Use `tmux new-session -d -s <name> bash start.sh` — tmux provides proper TTY; screen causes claude to fallback to --print mode |
| Health check keeps killing bot | If bot doesn't call external tools when idle, audit.log won't update — disable health check |
| Orphan bun/node processes block TG | `pkill -f 'bun server.ts'` before restarting — stale processes steal Telegram polling |
| MCP calls block TG message reception | Delegate heavy MCP work (Notion/Obsidian) to a background bot to keep main bot responsive |

## MemOcean (optional)

For persistent cross-bot memory, use [MemOcean](https://github.com/ChannelLabAI/memocean) — a separate project. Install it independently; this repo does not bundle it.

## License

Setup scripts and tooling: [MIT](LICENSE)

`server.patched.ts` is based on Anthropic's Telegram plugin for Claude Code, licensed under [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0). See the file header for modification details.

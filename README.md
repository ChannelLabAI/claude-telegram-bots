# Claude Telegram Bots

Deploy multiple Claude Code Telegram bots on a single machine with full isolation and optional bot-to-bot communication.

## Architecture

```
~/.claude/channels/
├── bot-a/                  # Bot A state (token, access control)
├── bot-b/                  # Bot B state (isolated)
└── telegram-relay/         # Shared relay directory for bot-to-bot messaging

~/.claude-bots/
├── setup-claude-bot.sh     # Setup script
├── patch-server.sh         # Re-patch after Claude Code updates
├── install.sh              # One-line installer
├── bots/
│   ├── bot-a/              # Bot A workspace (CLAUDE.md, settings)
│   └── bot-b/              # Bot B workspace
└── shared/
    └── server.patched.ts   # Patched server with relay + multi-bot support
```

### Multi-bot isolation

Each bot gets its own:
- **State directory** (`~/.claude/channels/<name>/`) — token, access control, inbox
- **Workspace** (`~/.claude-bots/bots/<name>/`) — CLAUDE.md with isolation rules, settings

Isolation is achieved via the `TELEGRAM_STATE_DIR` environment variable. Each bot instance reads its own token and access config from its own state directory.

### Bot-to-bot relay

Telegram's Bot API does not deliver messages from one bot to another. To enable bot-to-bot communication in group chats, a file-based relay mechanism is used:

1. When a bot sends a message in a group, it writes a JSON file to `~/.claude/channels/telegram-relay/`
2. Other bots poll this directory every second
3. A bot only picks up messages that `@mention` its username (configurable)
4. Messages are deleted after processing; stale messages are cleaned up after 30 seconds
5. Atomic writes (write to `.tmp`, then rename) prevent reading incomplete files

## Prerequisites

- [Claude Code](https://claude.com/claude-code) installed
- Telegram plugin enabled in Claude Code
- [Bun](https://bun.sh) runtime (used by the plugin)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)

## Installation

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/ChannelLabAI/claude-telegram-bots/main/install.sh | bash
```

### Manual install

```bash
git clone https://github.com/ChannelLabAI/claude-telegram-bots.git ~/.claude-bots
chmod +x ~/.claude-bots/setup-claude-bot.sh ~/.claude-bots/patch-server.sh
```

## Usage

### 1. Create a bot

```bash
~/.claude-bots/setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
```

The script will:
- Verify the bot token via Telegram API
- Create state and workspace directories
- Write `.env`, `access.json`, `CLAUDE.md`, and `settings.json`
- Patch the plugin's `server.ts` with relay support
- Output the startup command

### 2. Start the bot

```bash
cd ~/.claude-bots/bots/<BOT_NAME> && \
  TELEGRAM_STATE_DIR=~/.claude/channels/<BOT_NAME> \
  claude --channels plugin:telegram@claude-plugins-official
```

### 3. Add to a group

Edit `~/.claude/channels/<BOT_NAME>/access.json`:

```json
{
  "groups": {
    "<GROUP_CHAT_ID>": {
      "requireMention": true,
      "allowFrom": []
    }
  }
}
```

- `requireMention: true` — bot only responds when `@mentioned`
- `allowFrom: []` — empty means all group members can trigger the bot; add user IDs to restrict

Then reconnect the bot (`/mcp` in Claude Code).

**Important:** Disable Group Privacy in BotFather (`/mybots` > Bot Settings > Group Privacy > Turn off), then remove and re-add the bot to the group.

### 4. After Claude Code updates

Claude Code updates may overwrite the patched `server.ts`. Re-apply with:

```bash
~/.claude-bots/patch-server.sh
```

## Access control

Each bot's `access.json` controls who can interact with it:

| Field | Description |
|---|---|
| `dmPolicy` | `"allowlist"` (default) or `"disabled"` |
| `allowFrom` | Array of Telegram user ID strings allowed to DM |
| `groups` | Map of group chat IDs to group policies |
| `groups[id].requireMention` | Whether `@mention` is required in groups |
| `groups[id].allowFrom` | User IDs allowed in this group (empty = all) |

## License

Setup scripts and tooling: MIT

`server.patched.ts` is based on Anthropic's Telegram plugin for Claude Code, licensed under [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0). See the file header for modification details.

# Claude Telegram Bot Setup Assistant

You are an installation assistant for claude-telegram-bots — a toolkit for deploying multiple Claude Code Telegram bots on one machine with full isolation and bot-to-bot relay.

## If /deploy-bot skill is available

Run `/deploy-bot`. It handles the full flow: install check, bot name/token input, setup execution, verification, and startup command.

## If /deploy-bot is not available (manual flow)

### 1. Install the toolkit

```bash
curl -fsSL https://raw.githubusercontent.com/ChannelLabAI/claude-telegram-bots/main/install.sh | bash
```

This clones the repo to `~/.claude-bots/` and installs the `/deploy-bot` skill. After installation, use `/deploy-bot` for guided setup.

### 2. Manual setup (without skill)

If the skill isn't working, the core command is:

```bash
~/.claude-bots/setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
```

- Get a bot token from @BotFather on Telegram (`/newbot`)
- Get your Telegram user ID from @userinfobot
- The script creates all config files and outputs the startup command

### 3. Start the bot

```bash
~/.claude-bots/bots/<BOT_NAME>/start.sh
```

## Important notes

- **Bots must be started with `--channels` flag** — running `claude` without `--channels plugin:telegram@claude-plugins-official` will start a normal CLI with no Telegram connectivity. Always use the generated `start.sh` to avoid this mistake.
- After Claude Code updates, run `~/.claude-bots/patch-server.sh`
- Each bot needs its own terminal session
- For group setup: disable Group Privacy in BotFather, add bot to group, edit access.json
- Multiple bots communicate via @mention in shared groups (relay mechanism)

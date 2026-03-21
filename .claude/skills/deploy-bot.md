---
name: deploy-bot
description: Guide the user through deploying a new Claude Telegram bot
allowed-tools: Bash, Read, Write, Edit, Glob, AskUserQuestion
---

# Deploy Bot

You are guiding the user through deploying a new Claude Code Telegram bot. Follow each step carefully and confirm success before moving on.

## Step 1: Check installation

Check if `~/.claude-bots/setup-claude-bot.sh` exists.

If not, run:
```bash
curl -fsSL https://raw.githubusercontent.com/ChannelLabAI/claude-telegram-bots/main/install.sh | bash
```

## Step 2: Collect information

Ask the user for:
1. **Bot name** — a short identifier like `anna`, `kai`, `helper`. Lowercase, no spaces.
2. **Bot token** — from @BotFather on Telegram. If they don't have one, guide them:
   - Open Telegram → find @BotFather → send `/newbot` → follow prompts → copy the token

## Step 3: Run setup

Execute:
```bash
~/.claude-bots/setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
```

The script will interactively ask for the user's Telegram user ID. If they don't know it, tell them to message @userinfobot on Telegram.

## Step 4: Verify

Confirm these files were created:
- `~/.claude/channels/<BOT_NAME>/.env`
- `~/.claude/channels/<BOT_NAME>/access.json`
- `~/.claude-bots/bots/<BOT_NAME>/CLAUDE.md`

If any are missing, investigate and fix.

## Step 5: Output startup command

Tell the user:

```
To start your bot, run:

cd ~/.claude-bots/bots/<BOT_NAME> && TELEGRAM_STATE_DIR=~/.claude/channels/<BOT_NAME> claude --channels plugin:telegram@claude-plugins-official
```

## Step 6: Optional group setup

Ask if they want the bot in a Telegram group. If yes:

1. Tell them to disable Group Privacy in BotFather (`/mybots` > Bot Settings > Group Privacy > Turn off)
2. Add the bot to the group
3. Get the group's chat ID (they can forward a group message to @userinfobot or use other methods)
4. Edit `~/.claude/channels/<BOT_NAME>/access.json`:
```json
{
  "groups": {
    "<CHAT_ID>": {
      "requireMention": true,
      "allowFrom": []
    }
  }
}
```
5. Reconnect with `/mcp`

## Reminders

- After Claude Code updates, run `~/.claude-bots/patch-server.sh` to re-apply relay support
- Each bot needs its own terminal session
- In groups, the bot only responds when @mentioned (configurable)

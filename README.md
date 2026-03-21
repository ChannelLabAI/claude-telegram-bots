# Claude Telegram Bots

Deploy multiple Claude Code Telegram bots on a single machine with full isolation and optional bot-to-bot communication.

在同一台機器上部署多個 Claude Code Telegram bot，完整隔離，支援 bot 之間互相溝通。

---

## Why this exists / 為什麼做這個

Claude Code's Telegram plugin works great for a single bot. But if you want to run multiple bots on the same machine — say, a CTO bot and a CEO bot in the same group chat — you hit three problems:

1. **No multi-bot isolation.** The plugin reads its token from a single hardcoded directory. Running two bots means they fight over the same config.
2. **Bots can't see each other.** Telegram's Bot API doesn't deliver messages from one bot to another. Your bots are deaf to each other in group chats.
3. **Manual setup is tedious.** Each bot needs its own state directory, access control, workspace, and CLAUDE.md with isolation rules. Doing this by hand every time is error-prone.

This repo solves all three:
- `TELEGRAM_STATE_DIR` env var isolates each bot's token and access config
- A file-based relay lets bots communicate via `@mention` in shared groups
- A setup script automates the entire process — input bot name and token, get a running bot

---

Claude Code 的 Telegram plugin 單一 bot 用起來沒問題。但如果你想在同一台機器跑多個 bot——比如一個 CTO bot 和一個 CEO bot 在同一個群組——會遇到三個問題：

1. **沒有多 bot 隔離。** Plugin 從固定目錄讀 token，兩個 bot 會搶同一份設定。
2. **Bot 之間互相看不到。** Telegram Bot API 不會把一個 bot 的訊息送給另一個 bot。你的 bot 們在群組裡是聾的。
3. **手動設定很煩。** 每個 bot 都要獨立的 state 目錄、access control、工作區、CLAUDE.md 隔離規則。每次手動搞容易出錯。

這個 repo 解決這三個問題：
- `TELEGRAM_STATE_DIR` 環境變數隔離每個 bot 的 token 和 access 設定
- 檔案系統 relay 讓 bot 之間透過 `@mention` 互相溝通
- Setup 腳本自動化整個流程——輸入 bot 名稱和 token，就能跑

---

## Architecture / 架構

```
~/.claude-bots/
├── setup-claude-bot.sh     # Setup script
├── patch-server.sh         # Re-patch after Claude Code updates
├── install.sh              # One-line installer
├── state/
│   ├── bot-a/              # Bot A state (token, access control)
│   └── bot-b/              # Bot B state (isolated)
├── relay/                  # Shared relay for bot-to-bot messaging
├── bots/
│   ├── bot-a/              # Bot A workspace (CLAUDE.md, settings)
│   └── bot-b/              # Bot B workspace
└── shared/
    └── server.patched.ts   # Patched server with relay + multi-bot support
```

### Multi-bot isolation / 多 Bot 隔離

Each bot gets its own:
- **State directory** (`~/.claude-bots/state/<name>/`) — token, access control, inbox
- **Workspace** (`~/.claude-bots/bots/<name>/`) — CLAUDE.md with isolation rules, settings

Isolation is achieved via the `TELEGRAM_STATE_DIR` environment variable. Each bot instance reads its own token and access config from its own state directory.

每個 bot 有自己的：
- **State 目錄**（`~/.claude-bots/state/<名稱>/`）— token、access control、inbox
- **工作區**（`~/.claude-bots/bots/<名稱>/`）— CLAUDE.md 隔離規則、settings

透過 `TELEGRAM_STATE_DIR` 環境變數實現隔離。每個 bot 讀自己目錄的 token 和 access 設定。

### Bot-to-bot relay / Bot 間中繼

Telegram's Bot API does not deliver messages from one bot to another. To enable bot-to-bot communication in group chats, a file-based relay mechanism is used:

1. When a bot sends a message in a group, it writes a JSON file to `~/.claude/channels/telegram-relay/`
2. Other bots poll this directory every second
3. A bot only picks up messages that `@mention` its username
4. Messages are deleted after processing; stale messages are cleaned up after 30 seconds
5. Atomic writes (write to `.tmp`, then rename) prevent reading incomplete files

Telegram Bot API 不會把 bot 的訊息送給其他 bot。為了讓 bot 在群組裡互相溝通，用檔案系統 relay：

1. Bot 在群組發訊息時，同時寫一個 JSON 檔到 `~/.claude/channels/telegram-relay/`
2. 其他 bot 每秒輪詢這個目錄
3. 只有被 `@mention` 的 bot 會收到訊息
4. 處理完的訊息立刻刪除，30 秒後的過期訊息自動清理
5. 用 atomic write（先寫 `.tmp` 再 rename）避免讀到不完整的檔案

## Prerequisites / 前置需求

- [Claude Code](https://claude.com/claude-code) **v2.1.80+**
- Logged in via **claude.ai account** (Console / API key login is not supported for channels)
- Telegram plugin enabled in Claude Code
- [Bun](https://bun.sh) runtime (used by the plugin)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- If using a **Team/Enterprise org**, an admin must enable the channels feature

**Note on --channels flag:** Bots must be started with `claude --channels plugin:telegram@claude-plugins-official`. Adding the plugin to `.mcp.json` alone is not enough — the bot will not receive Telegram messages without the `--channels` flag. The generated `start.sh` handles this automatically.

**Security:** Telegram messages are untrusted input. Always configure `access.json` with a proper allowlist — do not leave `allowFrom` empty in production. See [Access control](#access-control--存取控制) below.

---

- [Claude Code](https://claude.com/claude-code) **v2.1.80+**
- 必須用 **claude.ai 帳號**登入（Console / API key 不支援 channels 功能）
- Telegram plugin 已啟用
- [Bun](https://bun.sh) runtime
- 一個 Telegram bot token（從 [@BotFather](https://t.me/BotFather) 取得）
- **Team/Enterprise org** 需要管理員開啟 channels 功能

**--channels 旗標：** Bot 必須用 `claude --channels` 啟動，只加 `.mcp.json` 不夠，bot 收不到 Telegram 訊息。`start.sh` 會自動處理。

**安全提醒：** Telegram 訊息是不受信任的輸入。務必在 `access.json` 設好 allowlist，不要在正式環境留空 `allowFrom`。

## Installation / 安裝

### One-line install / 一行安裝

```bash
curl -fsSL https://raw.githubusercontent.com/ChannelLabAI/claude-telegram-bots/main/install.sh | bash
```

### Manual install / 手動安裝

```bash
git clone https://github.com/ChannelLabAI/claude-telegram-bots.git ~/.claude-bots
chmod +x ~/.claude-bots/setup-claude-bot.sh ~/.claude-bots/patch-server.sh
```

## Usage / 使用方法

### 1. Create a bot / 建立 bot

```bash
~/.claude-bots/setup-claude-bot.sh <BOT_NAME> <BOT_TOKEN>
```

The script will:
- Verify the bot token via Telegram API
- Create state and workspace directories
- Write `.env`, `access.json`, `CLAUDE.md`, and `settings.json`
- Patch the plugin's `server.ts` with relay support
- Output the startup command

腳本會：
- 透過 Telegram API 驗證 bot token
- 建立 state 和工作區目錄
- 寫入 `.env`、`access.json`、`CLAUDE.md`、`settings.json`
- 把 plugin 的 `server.ts` 替換成帶 relay 支援的版本
- 輸出啟動指令

### 2. Start the bot / 啟動 bot

```bash
~/.claude-bots/bots/<BOT_NAME>/start.sh
```

The setup script generates a `start.sh` in each bot's workspace that handles `cd` and `TELEGRAM_STATE_DIR` automatically.

Setup 腳本會在每個 bot 的工作區生成 `start.sh`，自動處理目錄切換和環境變數。

### 3. Add to a group / 加入群組

**Step 1: Disable Group Privacy in BotFather**

By default, bots only receive messages that start with `/`. You must disable Group Privacy so the bot receives all messages (required for `@mention` detection).

1. Open [@BotFather](https://t.me/BotFather)
2. Send `/mybots` → select your bot
3. Go to **Bot Settings** → **Group Privacy** → **Turn off**
4. Remove the bot from any groups it's already in, then re-add it

**步驟 1：在 BotFather 關閉 Group Privacy**

預設情況下 bot 只會收到 `/` 開頭的訊息。必須關閉 Group Privacy，bot 才能收到所有訊息（`@mention` 偵測需要這個）。

1. 開啟 [@BotFather](https://t.me/BotFather)
2. 發送 `/mybots` → 選擇你的 bot
3. 進入 **Bot Settings** → **Group Privacy** → **Turn off**
4. 把 bot 從群組移除再重新加回去

---

**Step 2: Get the group chat ID**

Add [@userinfobot](https://t.me/userinfobot) to the group temporarily — it will report the group's chat ID (a negative number like `-1001234567890`).

**步驟 2：取得群組 chat ID**

把 [@userinfobot](https://t.me/userinfobot) 暫時加進群組——它會回報群組的 chat ID（負數，類似 `-1001234567890`）。

---

**Step 3: Update access.json**

Edit `~/.claude-bots/state/<BOT_NAME>/access.json`:

編輯 `~/.claude-bots/state/<BOT_NAME>/access.json`：

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

- `requireMention: true` — bot only responds when `@mentioned` in the group / bot 只在群組裡被 @ 時才回應
- `allowFrom: []` — empty means all group members can trigger; add user IDs to restrict / 空陣列代表所有成員都能觸發，加 user ID 可以限制

---

**Step 4: Reconnect**

Reconnect the bot (`/mcp` in Claude Code) to reload the config.

在 Claude Code 裡 `/mcp` 重連，重新載入設定。

---

**Step 5: Mention the bot**

In the group, always `@mention` the bot's username to send it a message. Without a mention, the bot will not respond even with Group Privacy disabled.

**步驟 5：@ 提及 bot**

在群組裡發訊息給 bot，永遠要 `@mention` 它的 username。沒有 mention，即使已關閉 Group Privacy，bot 也不會回應。

### 4. Backup and migration / 備份與遷移

Before upgrading or migrating to a new machine, run:

升級或遷移到新機器前，先跑：

```bash
~/.claude-bots/backup.sh
```

This backs up everything needed to restore your bots:

這會備份還原 bot 所需的所有東西：

| What | Path |
|---|---|
| Bot workspaces (CLAUDE.md, settings) | `~/.claude-bots/bots/` |
| Bot state (tokens, access.json) | `~/.claude-bots/state/` |
| Patched server | `~/.claude-bots/shared/server.patched.ts` |
| Bot memory | `~/.claude/projects/*claude-bots*/` |

**Important:** Bot memory lives in `~/.claude/projects/` with paths derived from the workspace absolute path. It is **not** inside `~/.claude-bots/` and will not be preserved by simply copying that directory.

**重要：** Bot 記憶存在 `~/.claude/projects/`，路徑由工作區絕對路徑衍生。它**不在** `~/.claude-bots/` 裡，單純複製那個目錄不會保留記憶。

To restore on a new machine:

在新機器還原：

```bash
tar -xzf claude-bots-backup-<timestamp>.tar.gz -C /
```

> `state/` contains bot tokens — keep your backup secure.
>
> `state/` 包含 bot token，請妥善保管備份檔。

### 5. After Claude Code updates / Claude Code 更新後

Claude Code updates may overwrite the patched `server.ts`. Re-apply with:

Claude Code 更新可能會覆蓋 patch 過的 `server.ts`。重新套用：

```bash
~/.claude-bots/patch-server.sh
```

## Access control / 存取控制

Each bot's `access.json` controls who can interact with it:

每個 bot 的 `access.json` 控制誰能跟它互動：

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

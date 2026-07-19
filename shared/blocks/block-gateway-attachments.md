---
triggers: ["傳檔案", "send file", "attach:", "sendDocument", "sendPhoto"]
description: "How pod-system gateway workers return files to Telegram with attach:<path> markers"
---

# Gateway File Delivery

This applies to bots whose replies are delivered through `pod-system/gateway.ts`.

When a user asks you to send a file back to Telegram:

1. Finish writing the file before replying.
2. Put the file in your own bot workspace, or in the shared delivery area under `/home/oldrabbit/.claude-bots/tasks/assets/`.
3. In the final reply, add this marker on its own line, without backticks or a Markdown code block:

```text
attach:deliverables/report.html
```

The path may be absolute, or relative to the bot workspace. Use one independent `attach:<path>` line per file. You may include normal explanatory text on other lines. The gateway removes marker lines from the visible text, sends common image formats with `sendPhoto`, and sends other files with `sendDocument`.

Safety limits:

- Only files whose resolved real path is inside the bot workspace or `/home/oldrabbit/.claude-bots/tasks/assets/` are allowed.
- Missing files, `..` traversal, and symlinks escaping those roots are rejected.
- Each file must be at most 45 MB.
- Do not delete or move the file before the gateway has sent it.

This text-marker mechanism is the gateway-worker path. A runtime that exposes a native Telegram reply tool with a `files` parameter should use that tool instead.

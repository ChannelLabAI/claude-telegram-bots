#!/usr/bin/env bash
# bot-crons-prompt.sh <bot_name>
#
# Emits the cron-init instruction block that should be injected into a bot's
# boot relay prompt. Reads the spec from shared/lib/bot-crons.yml.
#
# Exits 0 with empty stdout if the bot has no cron spec — caller should then
# skip injection. Exits non-zero on parse error.

set -euo pipefail
BOT="${1:-}"
[[ -n "$BOT" ]] || { echo "usage: bot-crons-prompt.sh <bot_name>" >&2; exit 2; }

YML="$HOME/.claude-bots/shared/lib/bot-crons.yml"
[[ -f "$YML" ]] || { echo "missing $YML" >&2; exit 3; }

python3 - "$BOT" "$YML" <<'PYEOF'
import sys, json
bot, yml = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    print("python3 PyYAML missing", file=sys.stderr); sys.exit(4)

with open(yml) as f:
    data = yaml.safe_load(f) or {}

jobs = data.get(bot) or []
if not jobs:
    sys.exit(0)

lines = [
    "",
    "",
    "---",
    f"【啟動 cron 初始化】CronCreate 是 session-scope，重啟後會消失。請立即透過 CronCreate 建立下列 {len(jobs)} 個 recurring 觸發器，建完之後繼續正常 wake-up 流程：",
    "",
]
for i, j in enumerate(jobs, 1):
    cron = j.get("cron", "")
    prompt = (j.get("prompt", "") or "").replace("\n", " ").strip()
    recurring = "true" if j.get("recurring", True) else "false"
    lines.append(f"{i}. CronCreate(cron: \"{cron}\", recurring: {recurring}, prompt: {json.dumps(prompt, ensure_ascii=False)})")

lines += [
    "",
    "建完用 CronList 確認數量正確。若 CronCreate 失敗，記到 session.json.notes。",
    "---",
]
print("\n".join(lines))
PYEOF

#!/usr/bin/env bash
# morning-todo-all.sh
# 每天早上 8:57 CST → relay 給所有特助，各自讀自己主人的日誌總結.md
# Created: 2026-05-03
VAULT_BASE="$HOME/Documents/Obsidian Vault - "
RELAY_DIR="$HOME/.claude-bots/relay"
TASK_ROOT="${MORNING_TODO_TASK_ROOT:-$HOME/.claude-bots/tasks}"
ANYA_DB="${MORNING_TODO_ANYA_DB:-$HOME/.claude-bots/pod-system/pods-db/gateway-assist-anya.db}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# 格式: bot_handle|vault_dir|journal_filename|owner_chat_id|owner_name
BOTS=(
  "Anyachl_bot|OldRabbit|日誌總結.md|1050312492|老兔"
  "Ron0001_bot|Ron|日誌總結.md|5288537361|Ron"
  "ZhangLingheAI_bot|Nicky|日誌總結.md|7132373174|Nicky"
  "CarrotAAA_bot|carrot|日誌總結.md|2114307569|菜姐"
  "chltao_bot|桃桃|日誌總結.md|8201149279|桃桃"
  "fanfan608bot|Lilai|日誌總結.md|8199138899|Lilai"
  "Wes_buddy_bot|Wes|日誌總結.md|1342168974|Wes"
  "netero33_bot|33|日誌總結.md|2106884013|33"
)

for BOT_ENTRY in "${BOTS[@]}"; do
  IFS='|' read -r BOT_HANDLE VAULT_DIR JOURNAL_FILE OWNER_ID OWNER_NAME <<< "$BOT_ENTRY"
  VAULT="${VAULT_BASE}${VAULT_DIR}/00Daily/${JOURNAL_FILE}"
  STATS=""

  # Only 老兔's live morning brief is in this task's scope.  The aligner makes
  # conservative, atomic updates before this branch reads the focus list.  Its
  # failure must not prevent the independent relays for the other seven bots.
  if [ "$BOT_HANDLE" = "Anyachl_bot" ] && [ -f "$VAULT" ]; then
    if ALIGN_JSON=$(python3 "$SCRIPT_DIR/morning-todo-align.py" --vault "$VAULT" --tasks-root "$TASK_ROOT" --db "$ANYA_DB" 2>>"$SCRIPT_DIR/morning-todo-all.log"); then
      if ALIGN_FIELDS=$(python3 -c '
import json, sys
data = json.load(sys.stdin)
print("\t".join(str(data[key]) for key in ("checked", "closed", "pending")))
' <<<"$ALIGN_JSON"); then
        IFS=$'\t' read -r CHECKED CLOSED PENDING <<<"$ALIGN_FIELDS"
        STATS="清單對齊：核對 ${CHECKED} 項、自動結案 ${CLOSED} 項、待核 ${PENDING} 項。"
      fi
    fi
  fi

  if [ -f "$VAULT" ]; then
    TASKS=$(VAULT_PATH="$VAULT" python3 -c "
import sys, os
vault = os.environ['VAULT_PATH']
content = open(vault, encoding='utf-8').read()
start = content.find('### 進行中')
if start == -1:
    print('（找不到進行中任務）')
    sys.exit()
end = content.find('### ', start + 1)
section = content[start:end] if end != -1 else content[start:]
lines = [l.strip() for l in section.splitlines() if '🟡' in l]
print('\n'.join(lines) if lines else '（目前無進行中任務）')
")
  else
    TASKS="（日誌總結 未建立，請協助 ${OWNER_NAME} 建立 ${VAULT_DIR}/00Daily/${JOURNAL_FILE}）"
  fi

  MSG="@${BOT_HANDLE} 早安提醒：請整理以下進行中焦點任務，挑出今天最需要關注的（3-5 項），用 TG 私訊 ${OWNER_NAME}（chat_id: ${OWNER_ID}）。格式簡潔，不要貼原文。

${TASKS}"
  if [ -n "$STATS" ]; then
    MSG+=$'\n\n'"$STATS"
  fi

  MSG_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$MSG")
  RELAY_FILE="$RELAY_DIR/$(date +%s%3N)-morning-${BOT_HANDLE}.json"
  mkdir -p "$RELAY_DIR"
  printf '{"from_bot":"system","chat_id":"self","text":%s,"message_id":0,"ts":"%s"}\n' "$MSG_JSON" "$TS" > "${RELAY_FILE}.tmp"
  mv "${RELAY_FILE}.tmp" "$RELAY_FILE"
  echo "[$(date)] morning relay → @${BOT_HANDLE}"
  sleep 0.05
done

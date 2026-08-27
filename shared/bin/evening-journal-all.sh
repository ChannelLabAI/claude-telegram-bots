#!/usr/bin/env bash
# Durable 18:03 trigger for Anya's evening journal workflow.
set -euo pipefail

RELAY_DIR="${RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

MSG='owner_dm
chat_id: 1050312492
@Anyachl_bot 用 background agent（sonnet，maxTurns=30）執行今日 Daily Note 下半段補寫：整理今天對話記錄，歸納主要貢獻和時間線，補寫 Compiled Truth + Timeline + 今日 Pearl。將 Compiled Truth prepend 進 WorkJournal.md。掃 FATQ tasks 整理今日完成/未完成事項。TG 私訊老兔（chat_id: 1050312492）：今日收工日誌摘要。如果今天老兔主動回報的完成事項不到 2 件，額外問有沒有要記錄的。'

MSG_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$MSG")"
mkdir -p "$RELAY_DIR"
RELAY_FILE="$RELAY_DIR/$(date +%s%3N)-evening-Anyachl_bot.json"
printf '{"from_bot":"system","chat_id":"self","text":%s,"message_id":0,"ts":"%s"}\n' \
  "$MSG_JSON" "$TS" > "${RELAY_FILE}.tmp"
mv "${RELAY_FILE}.tmp" "$RELAY_FILE"

echo "[$(date)] evening journal relay -> @Anyachl_bot"

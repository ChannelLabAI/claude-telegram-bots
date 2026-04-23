#!/usr/bin/env bash
# tg-daily-ingest.sh — Daily TG message ingest to Ocean/原檔海床
# Cron: 0 15 * * *  (15:00 UTC = 23:00 UTC+8)

set -a; source ~/.claude-bots/shared/.env 2>/dev/null || true; set +a
python3 ~/.claude-bots/shared/scripts/tg_daily_ingest.py >> ~/.claude-bots/logs/tg-ingest.log 2>&1

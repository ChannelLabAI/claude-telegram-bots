#!/usr/bin/env bash
# tg-daily-ingest.sh — Daily TG message ingest to Ocean/原檔海床
# Cron: 0 15 * * *  (15:00 UTC = 23:00 UTC+8)

set -a; source ~/.claude-bots/shared/scripts/load-secrets.sh 2>/dev/null || true; set +a
if python3 ~/.claude-bots/shared/scripts/tg_daily_ingest.py >> ~/.claude-bots/logs/tg-ingest.log 2>&1; then
  # P0 health monitoring: write heartbeat on success (ISO 8601 UTC, sqlite3 CLI unavailable)
  python3 -c "
import sqlite3, datetime
conn = sqlite3.connect('$HOME/.claude-bots/memory.db')
conn.execute(\"INSERT OR REPLACE INTO heartbeats (component, last_ok_at, last_status, last_error, consecutive_failures) VALUES ('tg_ingest', ?, 'ok', NULL, 0)\", (datetime.datetime.utcnow().isoformat() + 'Z',))
conn.commit(); conn.close()
" 2>/dev/null || true
fi

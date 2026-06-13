#!/usr/bin/env bash
# diana-ingest-push.sh — Push diana:ingest signal to relay on assistant Stop
#
# Usage (from settings.json Stop hook, async):
#   {"type":"command","command":"bash ~/.claude-bots/shared/hooks/diana-ingest-push.sh","async":true}
#
# Design: async + fail-open — any error exits silently (never blocks Stop)
# Slugs: read from existing seabed/radar rows (NO LLM calls — cost redline)

set -e
trap '' ERR  # fail-open: swallow all errors

RELAY_DIR="${HOME}/.claude-bots/relay-diana"
DB_PATH="${HOME}/.claude-bots/memory.db"
BOT_NAME="${TELEGRAM_STATE_DIR##*/}"  # derive bot name from env

mkdir -p "$RELAY_DIR" 2>/dev/null || true

# Get recent radar slugs (pure SQL, no LLM)
SLUGS=$(python3 -c "
import sqlite3, json, sys
try:
    conn = sqlite3.connect('${DB_PATH}')
    rows = conn.execute(
        'SELECT slug FROM radar ORDER BY rowid DESC LIMIT 5'
    ).fetchall()
    conn.close()
    print(json.dumps([r[0] for r in rows if r[0]]))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]")

TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
FILENAME="${RELAY_DIR}/$(date +%s%3N 2>/dev/null || date +%s)000-diana-ingest.json"

# Write signal (atomic rename)
python3 -c "
import json, os
signal = {
    'from_bot': '${BOT_NAME}',
    'chat_id': 'diana',
    'text': 'diana:ingest',
    'slug': ${SLUGS},
    'message_id': 0,
    'ts': '${TS}'
}
tmp = '${FILENAME}.tmp'
with open(tmp, 'w') as f:
    json.dump(signal, f)
    f.write('\n')
os.rename(tmp, '${FILENAME}')
" 2>/dev/null || true

exit 0

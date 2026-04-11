#!/usr/bin/env bash
# Install Dream Cycle system crontab entry
set -e

PYTHON_BIN="/home/oldrabbit/.claude-bots/shared/venv/bin/python"
# Fallback to system python3 if venv doesn't exist
if [ ! -f "$PYTHON_BIN" ]; then
    PYTHON_BIN="/usr/bin/python3"
fi
PYTHON="$PYTHON_BIN"
SCRIPT="/home/oldrabbit/.claude-bots/shared/scripts/dream_cycle.py"
LOG="/home/oldrabbit/.claude-bots/logs/dream-cycle.log"
PYTHONPATH="/home/oldrabbit/.claude-bots/shared"
SHARED_DIR="/home/oldrabbit/.claude-bots/shared"
LOG_DIR="/home/oldrabbit/.claude-bots/logs"
DB_PATH="$SHARED_DIR/../memory.db"

# Check if entry already exists
if crontab -l 2>/dev/null | grep -q "dream_cycle.py"; then
    echo "Dream Cycle cron already installed."
else
    CRON_ENTRY="0 19 * * * PYTHONPATH=$PYTHONPATH $PYTHON $SCRIPT --mode=live >> $LOG 2>&1"
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "Dream Cycle cron installed: $CRON_ENTRY"
fi

# Stale knowledge check — weekly Sunday 02:00 UTC+8 = Saturday 18:00 UTC
if crontab -l 2>/dev/null | grep -q "stale_knowledge_check.py"; then
    echo "Stale knowledge check cron already installed."
else
    STALE_ENTRY="0 18 * * 6 PYTHONPATH=${SHARED_DIR} ${PYTHON_BIN} ${SHARED_DIR}/scripts/stale_knowledge_check.py --db ${DB_PATH} >> ${LOG_DIR}/stale-check.log 2>&1"
    (crontab -l 2>/dev/null; echo "$STALE_ENTRY") | crontab -
    echo "Stale knowledge check cron installed: $STALE_ENTRY"
fi

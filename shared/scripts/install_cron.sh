#!/usr/bin/env bash
# Install Dream Cycle system crontab entry
set -e

PYTHON="/home/oldrabbit/.claude-bots/shared/venv/bin/python"
# Fallback to system python3 if venv doesn't exist
if [ ! -f "$PYTHON" ]; then
    PYTHON="/usr/bin/python3"
fi
SCRIPT="/home/oldrabbit/.claude-bots/shared/scripts/dream_cycle.py"
LOG="/home/oldrabbit/.claude-bots/logs/dream-cycle.log"
PYTHONPATH="/home/oldrabbit/.claude-bots/shared"

# Check if entry already exists
if crontab -l 2>/dev/null | grep -q "dream_cycle.py"; then
    echo "Dream Cycle cron already installed."
    exit 0
fi

CRON_ENTRY="0 19 * * * PYTHONPATH=$PYTHONPATH $PYTHON $SCRIPT --mode=live >> $LOG 2>&1"

(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
echo "Dream Cycle cron installed: $CRON_ENTRY"

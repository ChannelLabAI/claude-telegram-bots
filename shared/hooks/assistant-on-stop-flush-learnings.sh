#!/usr/bin/env bash
# anya-on-stop-flush-learnings.sh — Stop hook: flush task learnings to fts5
#
# Triggered on Claude Code "Stop" event for Anya's session.
# Scans ~/.claude-bots/tasks/done/ for tasks that have a "learnings" field
# but have not yet been ingested into the fts5 search index.
# If any are found, blocks Claude from stopping and instructs it to run
# the fts5-ingest hook on those task files.
#
# "Not yet ingested" is tracked via a sidecar flag file:
#   ~/.claude-bots/state/anya/fts5_ingested/<task-id>
# Absence of the flag = not ingested. Hook creates the flag after instructing Claude.
#
# Dead-loop prevention: stop_hook_active=true on second stop → guard exits cleanly.
#
# Install in ~/.claude-bots/bots/anya/.claude/settings.json alongside
# anya-on-stop-save-session.sh (both in the Stop hooks array).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stop_hook_lib.sh
source "$SCRIPT_DIR/lib/stop_hook_lib.sh"

# MUST be first: dead-loop guard. Reads stdin into $STOP_HOOK_LIB_INPUT.
guard_stop_hook_active

# Only trigger for Anya sessions
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ "$BOT_NAME" != "anya" ]]; then
    echo "{}"
    exit 0
fi

DONE_DIR="$HOME/.claude-bots/tasks/done"
INGESTED_DIR="$HOME/.claude-bots/state/anya/fts5_ingested"
FAILED_DIR="$HOME/.claude-bots/logs/learnings-ingest-failed"
mkdir -p "$INGESTED_DIR" "$FAILED_DIR"

# Scan done tasks for learnings not yet ingested
PENDING_INGEST=()
if [[ -d "$DONE_DIR" ]]; then
    while IFS= read -r -d '' task_file; do
        task_id=$(python3 -c "
import json, sys, os
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    # Accept 'id' field or derive from filename
    tid = d.get('id') or os.path.basename(sys.argv[1]).replace('.json','')
    has_learnings = bool(d.get('learnings') or d.get('learning'))
    print(tid if has_learnings else '')
except:
    print('')
" "$task_file" 2>/dev/null)

        if [[ -n "$task_id" ]] && [[ ! -f "$INGESTED_DIR/$task_id" ]]; then
            PENDING_INGEST+=("$task_file")
            # NOTE: Do NOT mark as ingested here. The flag is set only after
            # fts5-ingest.sh succeeds (exit 0) to prevent data loss on failure.
        fi
    done < <(find "$DONE_DIR" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
fi

# Also pick up retry queue: failed tasks from logs/learnings-ingest-failed/
# Only retry if fail_count < 5 and not yet ingested
RETRY_INGEST=()
if [[ -d "$FAILED_DIR" ]]; then
    while IFS= read -r -d '' fail_file; do
        # fail files: YYYYMMDD-HHmmss-{task_id}.json
        fname=$(basename "$fail_file")
        # extract task_id: strip timestamp prefix (YYYYMMDD-HHmmss-)
        task_id=$(echo "$fname" | sed 's/^[0-9]\{8\}-[0-9]\{6\}-//' | sed 's/\.json$//')
        if [[ -z "$task_id" ]]; then continue; fi
        if [[ -f "$INGESTED_DIR/$task_id" ]]; then continue; fi  # already ingested
        # Check fail count
        fail_count_file="$FAILED_DIR/$task_id.fail_count"
        fail_count=0
        if [[ -f "$fail_count_file" ]]; then
            fail_count=$(cat "$fail_count_file" 2>/dev/null || echo 0)
        fi
        if [[ "$fail_count" -ge 5 ]]; then
            echo "ALERT: task $task_id has failed ingest 5+ times — manual intervention needed" >&2
            continue
        fi
        # Add to retry queue if not already in PENDING_INGEST
        already=false
        for p in "${PENDING_INGEST[@]+"${PENDING_INGEST[@]}"}"; do
            if [[ "$p" == "$fail_file" ]]; then already=true; break; fi
        done
        if ! $already; then
            RETRY_INGEST+=("$fail_file")
        fi
    done < <(find "$FAILED_DIR" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
fi

ALL_INGEST=()
[[ ${#PENDING_INGEST[@]} -gt 0 ]] && ALL_INGEST+=("${PENDING_INGEST[@]}")
[[ ${#RETRY_INGEST[@]} -gt 0 ]] && ALL_INGEST+=("${RETRY_INGEST[@]}")

if [[ ${#ALL_INGEST[@]} -eq 0 ]]; then
    echo "{}"
    exit 0
fi

# Build file list for the reason message
FILE_LIST=$(printf '%s\n' "${ALL_INGEST[@]}" | head -10)
COUNT=${#ALL_INGEST[@]}

export STOP_HOOK_ACTIVE=1

emit_block_reason "Before stopping, run fts5-ingest on $COUNT done task(s) that have learnings not yet indexed. Files to ingest:
$FILE_LIST

For EACH file, run:
  bash ~/.claude-bots/shared/hooks/fts5-ingest.sh <task_file>

After each successful ingest (exit code 0):
  touch ~/.claude-bots/state/anya/fts5_ingested/<task_id>

On failure (non-zero exit):
  Copy the task JSON to ~/.claude-bots/logs/learnings-ingest-failed/\$(date +%Y%m%d-%H%M%S)-<task_id>.json
  Count failures in ~/.claude-bots/logs/learnings-ingest-failed/<task_id>.fail_count
  If fail count >= 5, print ALERT to stderr: 'ALERT: task <task_id> has failed ingest 5+ times'

Do not call any Telegram tools."

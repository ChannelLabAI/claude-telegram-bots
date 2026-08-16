#!/usr/bin/env bash
# inotify-watch.sh — ChannelLab FATQ（File-Atomic Task Queue）watcher daemon
# Watches ~/.claude-bots/tasks/ with inotifywait and runs task-arrival side
# effects that have not moved to the FATQ dispatcher.
#
# FATQ task notifications are delivered by fatq-dispatch through gateway relay.
# This watcher must not write duplicate task notifications to state/*/inbox.
#
# Usage: bash ~/.claude-bots/shared/inotify-watch.sh
# Or via systemd: systemctl --user start channellab-inotify-watch.service

set -uo pipefail

TASKS_DIR="${HOME}/.claude-bots/tasks"
# INBOX_DIR removed — inbox system decommissioned 2026-04-16
STATE_DIR_ROOT="${HOME}/.claude-bots/state"
LOG_FILE="${HOME}/.claude-bots/logs/inotify-watch.log"
INOTIFYWAIT="/usr/bin/inotifywait"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# FATQ_TASK_NOTIFICATION_RETIRED (2026-08-17): task dispatch is authoritative in
# fatq-dispatch and reaches Claude/Codex workers through gateway relay.  The old
# state/<bot>/inbox/messages writer had no matching pod reader and grew without
# bound, so task arrivals are intentionally log-only here.  Do not restore a
# state inbox write; keep unrelated task-arrival side effects below intact.
log_task_notification_retired() {
  local filename="$1"
  local assigned_to="$2"
  local queue="$3"
  log "INFO: task notification handled by fatq-dispatch gateway relay; no state inbox write (file=${filename}, queue=${queue}, assigned_to=${assigned_to})"
}

route_and_inject() {
  local full_path="$1"
  local filename
  filename=$(basename "$full_path")
  local queue
  queue=$(basename "$(dirname "$full_path")")

  # Determine routing
  local assigned_to=""

  if [[ "$queue" == "review" || "$queue" == "spec_review" || "$queue" == "design_review" ]]; then
    # Review queues are handled by the dispatcher and canonical reviewer routing.
    assigned_to="$queue"
  elif [[ "$queue" == "design" ]]; then
    # Design tasks are handled by the dispatcher and canonical designer routing.
    assigned_to="design"
  elif [[ "$queue" == "pending" || "$queue" == "rejected" || "$queue" == "in_progress" ]]; then
    # FATQ v1 uses assigned; keep assigned_to as a legacy fallback.
    assigned_to=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('assigned') or d.get('assigned_to', ''))
except Exception as e:
    print('')
    import sys as _sys
    _sys.exit(1)
" "$full_path" 2>/dev/null) || {
      log "WARN: JSON parse error for ${full_path}, skipping"
      return 1
    }

    if [[ -z "$assigned_to" ]]; then
      log "WARN: no assigned_to field in ${full_path}, skipping"
      return 1
    fi

    # Pre-task search enrichment (MEMO-014):
    # For in_progress queue, run pre_task_search.py before notifications
    if [[ "$queue" == "in_progress" ]]; then
      local pre_search_script="${HOME}/.claude-bots/shared/scripts/pre_task_search.py"
      local venv_python="${HOME}/.claude-bots/shared/venv/bin/python3"
      local py_bin
      if [[ -x "$venv_python" ]]; then
        py_bin="$venv_python"
      else
        py_bin="python3"
      fi
      if [[ -f "$pre_search_script" ]]; then
        timeout 20 "$py_bin" "$pre_search_script" "$full_path" 2>/dev/null || true
        log "INFO: pre_task_search ran for ${full_path} (queue=in_progress)"
      fi
    fi

  else
    # Not a watched queue (e.g. in_progress, done, wont_do) — ignore
    return 0
  fi

  log_task_notification_retired "$filename" "$assigned_to" "$queue"
}

# ---------------------------------------------------------------------------
# Inbox handler: called when a new file appears in INBOX_DIR
# ---------------------------------------------------------------------------
inject_inbox_notification() {
  local full_path="$1"
  local filename
  filename=$(basename "$full_path")
  # Skip files inside _processed/ or _drafts/ (any depth) to avoid loops
  case "$full_path" in
    */_processed/*|*/_drafts/*)
      return 0 ;;
  esac

  # Skip hidden files
  case "$filename" in
    .*) return 0 ;;
  esac

  # Get file extension
  local ext="${filename##*.}"
  if [[ "$ext" == "$filename" ]]; then
    ext="unknown"
  fi

  # Human-readable size
  local size_human="unknown"
  if [[ -f "$full_path" ]]; then
    size_human=$(du -sh "$full_path" 2>/dev/null | cut -f1 || echo "unknown")
  fi

  local inbox_dir="${STATE_DIR_ROOT}/anya/inbox/messages"
  if [[ ! -d "$inbox_dir" ]]; then
    log "WARN: Anya inbox dir not found at ${inbox_dir}, skipping (file=${filename})"
    return 1
  fi

  local ts
  ts=$(date +%s%3N)
  local out_file="${inbox_dir}/${ts}-inbox-notify.json"
  local tmp_file="${out_file}.tmp"

  NOTIFY_FILENAME="$filename" \
  NOTIFY_FULL_PATH="$full_path" \
  NOTIFY_SIZE="$size_human" \
  NOTIFY_EXT="$ext" \
  python3 - <<'PYEOF' > "$tmp_file"
import json, os
data = {
    "method": "notifications/claude/channel",
    "params": {
        "content": f"📥 新 inbox 檔：{os.environ['NOTIFY_FILENAME']} ({os.environ['NOTIFY_SIZE']}) — Sorter pipeline 請處理",
        "meta": {
            "source": "inotify-inbox-watcher",
            "event": "inbox_file_arrived",
            "file_path": os.environ["NOTIFY_FULL_PATH"],
            "filename": os.environ["NOTIFY_FILENAME"],
            "file_type": os.environ["NOTIFY_EXT"]
        }
    }
}
print(json.dumps(data))
PYEOF

  mv "$tmp_file" "$out_file"
  log "INFO: inbox notify injected → anya/inbox/messages/$(basename "$out_file") (file=${filename}, ext=${ext}, size=${size_human})"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
log "INFO: inotify-watch daemon starting (v0.3), watching ${TASKS_DIR} (inbox removed 2026-04-16)"

if [[ ! -x "$INOTIFYWAIT" ]]; then
  log "ERROR: inotifywait not found at ${INOTIFYWAIT}"
  echo "ERROR: inotifywait not found at ${INOTIFYWAIT}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Initial scan: catch tasks that arrived while daemon was offline
# (covers VPS reboot + daemon/bot simultaneous offline edge case)
# ---------------------------------------------------------------------------
log "INFO: running initial scan for pre-existing queue files..."
_initial_scan_count=0
for _queue in pending spec_review design design_review rejected review; do
  _dir="${TASKS_DIR}/${_queue}"
  [[ -d "$_dir" ]] || continue
  for _f in "$_dir"/*.json; do
    [[ -f "$_f" ]] || continue
    route_and_inject "$_f"
    (( _initial_scan_count++ )) || true
  done
done
log "INFO: initial scan complete, processed ${_initial_scan_count} existing file(s)"

# Watch tasks dir AND inbox dir recursively for close_write and moved_to events
# inbox dir removed
"$INOTIFYWAIT" -m -r \
  -e close_write \
  -e moved_to \
  --format '%w%f' \
  "$TASKS_DIR" 2>/dev/null | while IFS= read -r full_path; do

  # Small defensive read delay — ensure file is fully written
  sleep 0.1

  # Route based on which directory the event came from
  case "$full_path" in
    *)
      # Tasks dir: skip non-JSON files and .tmp intermediates
      case "$full_path" in
        *.json) ;;
        *) continue ;;
      esac
      log "EVENT: detected ${full_path}"
      route_and_inject "$full_path" || true
      ;;
  esac
done

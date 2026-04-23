#!/usr/bin/env bash
# inotify-watch.sh — ChannelLab FATQ（File-Atomic Task Queue）watcher daemon
# Watches ~/.claude-bots/tasks/ with inotifywait and injects notifications
# into the appropriate bot's inbox when task files appear.
#
# Routing:
#   tasks/pending/    → read assigned_to → inject into that bot's inbox
#   tasks/rejected/   → read assigned_to → inject into that bot's inbox
#   tasks/in_progress/ → read assigned_to → inject into that bot's inbox
#   tasks/review/   → always inject into Bella's inbox
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
# Bot name → state_dir mapping
# Loaded dynamically from team-config.json (v0.2).
# Falls back to empty table if config not found.
# ---------------------------------------------------------------------------
TEAM_CONFIG="${HOME}/.claude-bots/shared/team-config.json"

declare -A BOT_STATE_DIR=()

_load_bot_mapping() {
  if [[ ! -f "$TEAM_CONFIG" ]]; then
    log "WARN: team-config.json not found at ${TEAM_CONFIG}, bot mapping empty"
    return
  fi
  # Extract all state_dirs from assistants + shared_pools using python3
  # Each entry: "name_lower state_dir" and "state_dir state_dir" (both-way lookup)
  while IFS=$'\t' read -r key val; do
    [[ -n "$key" && -n "$val" ]] && BOT_STATE_DIR["$key"]="$val"
  done < <(python3 - "$TEAM_CONFIG" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
entries = []
def add(name, state_dir):
    if name and state_dir:
        entries.append((name.lower(), state_dir))
        entries.append((state_dir.lower(), state_dir))
        entries.append((state_dir, state_dir))  # exact case
for a in cfg.get("assistants", []):
    add(a.get("name",""), a.get("state_dir",""))
for pool in cfg.get("shared_pools", {}).values():
    if isinstance(pool, list):
        for m in pool:
            add(m.get("name",""), m.get("state_dir",""))
seen = set()
for k, v in entries:
    if k not in seen:
        print(f"{k}\t{v}")
        seen.add(k)
PYEOF
)
  log "INFO: loaded ${#BOT_STATE_DIR[@]} bot mappings from team-config.json"
}

_load_bot_mapping

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

inject_notification() {
  local state_dir="$1"
  local filename="$2"
  local full_path="$3"
  local assigned_to="$4"
  local queue="$5"

  local inbox_dir="${STATE_DIR_ROOT}/${state_dir}/inbox/messages"

  if [[ ! -d "$inbox_dir" ]]; then
    if ! mkdir -p "$inbox_dir" 2>/dev/null; then
      log "ERROR: failed to mkdir inbox for state_dir=${state_dir}, skipping (file=${filename})"
      return 1
    fi
    log "INFO: auto-created inbox dir ${inbox_dir}"
  fi

  local ts
  ts=$(date +%s%3N)
  local out_file="${inbox_dir}/${ts}-task-notify.json"
  local tmp_file="${out_file}.tmp"

  # Build content string based on queue type
  local content
  if [[ "$queue" == "review" ]]; then
    content="新 Review 任務：${filename} (assigned_to: ${assigned_to})"
  elif [[ "$queue" == "rejected" ]]; then
    content="任務被退回修改：${filename} (assigned_to: ${assigned_to})"
  elif [[ "$queue" == "spec_review" ]]; then
    content="新 Spec 審查：${filename}（assigned_to: ${assigned_to}）"
  elif [[ "$queue" == "design" ]]; then
    content="新設計任務：${filename}（assigned_to: ${assigned_to}）"
  elif [[ "$queue" == "design_review" ]]; then
    content="新設計稿審查：${filename}（assigned_to: ${assigned_to}）"
  else
    content="新任務通知：${filename} (assigned_to: ${assigned_to})"
  fi

  # Write notification JSON (matches inbox-inject.sh expected format)
  # Pass values as env vars to avoid shell quoting issues in heredoc
  NOTIFY_CONTENT="$content" \
  NOTIFY_TASK_FILE="$full_path" \
  NOTIFY_ASSIGNED_TO="$assigned_to" \
  NOTIFY_QUEUE="$queue" \
  python3 - <<'PYEOF' > "$tmp_file"
import json, os
data = {
    "method": "notifications/claude/channel",
    "params": {
        "content": os.environ["NOTIFY_CONTENT"],
        "meta": {
            "source": "inotify-task-watcher",
            "event": "task_queued",
            "task_file": os.environ["NOTIFY_TASK_FILE"],
            "assigned_to": os.environ["NOTIFY_ASSIGNED_TO"],
            "queue": os.environ["NOTIFY_QUEUE"]
        }
    }
}
print(json.dumps(data))
PYEOF

  mv "$tmp_file" "$out_file"
  log "INFO: injected notification → ${state_dir}/inbox/messages/$(basename "$out_file") (queue=${queue}, assigned_to=${assigned_to})"
}

route_and_inject() {
  local full_path="$1"
  local filename
  filename=$(basename "$full_path")
  local queue
  queue=$(basename "$(dirname "$full_path")")

  # Determine routing
  local assigned_to=""
  local state_dir=""

  if [[ "$queue" == "review" || "$queue" == "spec_review" || "$queue" == "design_review" ]]; then
    # Always route review/spec_review/design_review tasks to Bella
    assigned_to="$queue"
    state_dir="Bella"
  elif [[ "$queue" == "design" ]]; then
    # Design tasks always go to 星星人 (nicky-builder)
    assigned_to="design"
    state_dir="nicky-builder"
  elif [[ "$queue" == "pending" || "$queue" == "rejected" || "$queue" == "in_progress" ]]; then
    # Parse assigned_to from task JSON
    assigned_to=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('assigned_to', ''))
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

    # If assigned_to == "pool", broadcast to all shared pool members
    if [[ "$assigned_to" == "pool" ]]; then
      while IFS=$'\t' read -r bot_name bot_state_dir; do
        [[ -n "$bot_state_dir" ]] && inject_notification "$bot_state_dir" "$filename" "$full_path" "$assigned_to" "$queue"
      done < <(python3 - "$TEAM_CONFIG" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
for pool in cfg.get("shared_pools", {}).values():
    if isinstance(pool, list):
        for m in pool:
            name = m.get("name","").lower()
            state_dir = m.get("state_dir","")
            if name and state_dir:
                print(f"{name}\t{state_dir}")
PYEOF
)
      return 0
    fi

    # Look up state_dir
    state_dir="${BOT_STATE_DIR[$assigned_to]:-}"
    if [[ -z "$state_dir" ]]; then
      log "WARN: unknown assigned_to='${assigned_to}' in ${full_path}, skipping"
      return 1
    fi
  else
    # Not a watched queue (e.g. in_progress, done, wont_do) — ignore
    return 0
  fi

  inject_notification "$state_dir" "$filename" "$full_path" "$assigned_to" "$queue"
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

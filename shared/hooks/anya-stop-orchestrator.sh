#!/usr/bin/env bash
# anya-stop-orchestrator.sh — Single orchestrator for all Anya Stop hooks
#
# Replaces the 3 separate Stop hooks that previously ran concurrently and
# raced on session.json writes:
#   1. session-autosave.sh       (async, wrote session.json)
#   2. anya-on-stop-save-session.sh (sync, wrote session.json, blocked)
#   3. anya-on-stop-flush-learnings.sh (sync, wrote session.json, blocked)
#
# Fix: collapse to a single orchestrator with a file-based marker that
# prevents concurrent re-entry (env vars don't propagate to sibling processes).
#
# Lock dir:    ~/.claude-bots/state/anya/.stop_hook_active.lock  (atomic mkdir)
# Inside:      "info" file with "<pid>:<epoch_seconds>"
# Fresh = <30s old AND pid still running. Stale = >30s OR pid dead.
#
# Dead-loop prevention: also honours Claude Code's stop_hook_active field in
# stdin JSON (via stop_hook_lib.sh guard_stop_hook_active).
#
# ─────────────────────────────────────────────────────────────────────────────
# INSTALL (Anya settings.json change required — workspace-protect blocks direct
# edits to settings.json, so Anya must make this change manually):
#
#   Replace the entire "Stop" section in
#   ~/.claude-bots/bots/anya/.claude/settings.json with:
#
#     "Stop": [
#       {
#         "matcher": "",
#         "hooks": [
#           {
#             "type": "command",
#             "command": "bash ~/.claude-bots/shared/hooks/anya-stop-orchestrator.sh",
#             "timeout": 30
#           }
#         ]
#       }
#     ]
#
#   Remove the three old entries:
#     - session-autosave.sh (async)
#     - anya-on-stop-save-session.sh
#     - anya-on-stop-flush-learnings.sh
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stop_hook_lib.sh
source "$SCRIPT_DIR/lib/stop_hook_lib.sh"

# ── Step 1: Claude Code's native dead-loop guard (stdin JSON) ─────────────────
# guard_stop_hook_active reads stdin → stores in $STOP_HOOK_LIB_INPUT
# If stop_hook_active=true or STOP_HOOK_ACTIVE env=1, exits 0 immediately.
guard_stop_hook_active

# ── Step 2: File-based atomic lock guard (race-condition fix) ─────────────────
# guard_stop_hook_file_marker uses mkdir for atomicity. On success it acquires
# the lock, writes pid+epoch into the lock dir, and installs an EXIT trap to
# clean up automatically. On failure (fresh live lock held by a sibling), it
# returns 1.
mkdir -p "$HOME/.claude-bots/state/anya"

if ! guard_stop_hook_file_marker "anya"; then
    # Fresh lock held by a sibling hook instance — skip silently
    echo "{}"
    exit 0
fi
# Lock is now held by this process; EXIT trap handles cleanup automatically.

# ── Step 4: Only run for Anya sessions ───────────────────────────────────────
BOT_NAME=$(basename "${TELEGRAM_STATE_DIR:-}")
if [[ "$BOT_NAME" != "anya" ]]; then
    echo "{}"
    exit 0
fi

# ── Step 5: session-autosave logic (was async session-autosave.sh) ────────────
# Update lastActiveAt + memoryCheckNeeded in session.json (best-effort, no block)
SESSION_FILE="$HOME/.claude-bots/state/anya/session.json"
if [[ -f "$SESSION_FILE" ]]; then
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    TMP=$(mktemp)
    if python3 -c "
import json, sys
with open('$SESSION_FILE') as f:
    s = json.load(f)
s['lastActiveAt'] = '$TIMESTAMP'
s['memoryCheckNeeded'] = True
with open('$TMP', 'w') as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
" 2>/dev/null; then
        mv "$TMP" "$SESSION_FILE"
    else
        rm -f "$TMP"
    fi
fi

# ── Step 6: exit early if no session file ────────────────────────────────────
if [[ ! -f "$SESSION_FILE" ]]; then
    echo "{}"
    exit 0
fi

# ── Step 7: flush-learnings check (was anya-on-stop-flush-learnings.sh) ───────
# Scan done tasks for learnings not yet ingested into fts5.
DONE_DIR="$HOME/.claude-bots/tasks/done"
INGESTED_DIR="$HOME/.claude-bots/state/anya/fts5_ingested"
mkdir -p "$INGESTED_DIR"

PENDING_INGEST=()
if [[ -d "$DONE_DIR" ]]; then
    while IFS= read -r -d '' task_file; do
        task_id=$(python3 -c "
import json, sys, os
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    tid = d.get('id') or os.path.basename(sys.argv[1]).replace('.json','')
    has_learnings = bool(d.get('learnings') or d.get('learning'))
    print(tid if has_learnings else '')
except:
    print('')
" "$task_file" 2>/dev/null)

        if [[ -n "$task_id" ]] && [[ ! -f "$INGESTED_DIR/$task_id" ]]; then
            PENDING_INGEST+=("$task_file")
            touch "$INGESTED_DIR/$task_id"
        fi
    done < <(find "$DONE_DIR" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
fi

# ── Step 8: Only block if there are pending learnings to ingest ──────────────
# Optimization (老兔 2026-04-10 批准): bash already updated lastActiveAt in Step 5.
# No need to block Claude for session.json updates every turn — saves ~2-3K
# token per stop. Only block when there's actual work (pending learnings).

# ── Step 9: Pearl draft generation (background, non-blocking) ─────────────────
bash ~/.claude-bots/shared/hooks/anya-on-stop-pearl-draft.sh &

if [[ ${#PENDING_INGEST[@]} -gt 0 ]]; then
    FILE_LIST=$(printf '%s\n' "${PENDING_INGEST[@]}" | head -10)
    COUNT=${#PENDING_INGEST[@]}
    REASON="Run fts5-ingest on $COUNT done task(s) that have learnings not yet indexed. Files to ingest:
$FILE_LIST
Run: bash ~/.claude-bots/shared/hooks/fts5-ingest.sh on each file, or batch ingest if supported.

Do not call any Telegram tools."
    emit_block_reason "$REASON"
else
    # No pending work — let Claude stop without blocking
    echo "{}"
    exit 0
fi

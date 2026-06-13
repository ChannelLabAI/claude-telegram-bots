#!/usr/bin/env bash
# shared/lib/bot-rescue-lib.sh — Shared orphan-cleanup and crash-loop detection
#
# Source this file to get two functions:
#   count_recent_restarts <bot_name>
#   cleanup_orphan_plugins <bot_name> [--dry-run]
#
# Used by: scripts/bot-watchdog.sh  AND  ~/.claude/skills/bot-rescue/SKILL.md

BOTS_ROOT="${BOTS_ROOT:-$HOME/.claude-bots/bots}"
_BOT_RESCUE_LOG="${_BOT_RESCUE_LOG:-$HOME/.claude-bots/logs/bot-watchdog.log}"
_CRASH_WINDOW_MINS="${_CRASH_WINDOW_MINS:-60}"

# Count how many times <bot> has been restarted in the last _CRASH_WINDOW_MINS minutes.
count_recent_restarts() {
  local bot="$1"
  local since
  since=$(date -u -d "${_CRASH_WINDOW_MINS} minutes ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
         || date -u -v-${_CRASH_WINDOW_MINS}M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
  [[ -z "$since" ]] && echo 0 && return
  grep "RESTART $bot" "$_BOT_RESCUE_LOG" 2>/dev/null \
    | awk -v since="$since" 'substr($1,2,20) >= since {count++} END {print count+0}'
}

# Find orphan bun telegram-plugin processes (parent claude is dead) for <bot>.
#   --dry-run  : print "ORPHAN: bun PID <pid> (parent <ppid> dead)" lines, do not kill
#   (default)  : kill -TERM each orphan, log count to _BOT_RESCUE_LOG
#
# Identity is bound via TELEGRAM_STATE_DIR in the *parent* claude process's /proc environ,
# not by fragile pgrep cmdline matching — consistent with shared/bin/bot-status.
cleanup_orphan_plugins() {
  local bot="$1"
  local dry_run=false
  [[ "${2:-}" == "--dry-run" ]] && dry_run=true

  local state_dir="$BOTS_ROOT/$bot"
  local killed=0

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local ppid
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" ]] && continue

    if ! kill -0 "$ppid" 2>/dev/null; then
      # Parent claude process is dead — this bun proc is an orphan
      if $dry_run; then
        echo "ORPHAN: bun PID $pid (parent $ppid dead)"
      else
        kill -TERM "$pid" 2>/dev/null && killed=$((killed + 1))
      fi
    else
      # Parent alive — verify it belongs to THIS bot via TELEGRAM_STATE_DIR in environ
      local sd
      sd=$(tr '\0' '\n' < "/proc/$ppid/environ" 2>/dev/null \
           | grep '^TELEGRAM_STATE_DIR=' | head -1 | cut -d= -f2-) || true
      # If it belongs to a different bot (or unreadable), leave it alone
      if [[ "$sd" == "$state_dir" ]]; then
        # Our bot's parent is alive — not an orphan
        :
      fi
      # else: different bot's proc or unreadable environ — skip (best-effort)
    fi
  done < <(pgrep -f "bun.*telegram.*start" 2>/dev/null)

  if ! $dry_run && [[ $killed -gt 0 ]]; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] cleanup: killed $killed orphan plugin procs for $bot" \
      >> "$_BOT_RESCUE_LOG"
  fi
}

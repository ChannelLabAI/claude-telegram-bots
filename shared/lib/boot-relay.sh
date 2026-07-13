#!/usr/bin/env bash
# boot-relay.sh - session-scoped boot relay helper for persistent Claude bots.
#
# Source this from start.sh, then call:
#   send_boot_relay "$BOT_NAME" "$BOT_USERNAME" "$CLAUDE_PID" "$RELAY_DIR"
#
# The cron-init block is session-scoped. It should be sent once for a newly
# created Claude session, but not every time the surrounding process or gateway
# wakes/restarts while the same session transcript is still active.

set -u

boot_relay_project_dir() {
  local bot_name="$1"
  printf '%s/.claude/projects/-home-oldrabbit--claude-bots-bots-%s\n' "$HOME" "$bot_name"
}

boot_relay_session_key() {
  local bot_name="$1"
  local claude_pid="${2:-}"
  local project_dir transcript

  project_dir="$(boot_relay_project_dir "$bot_name")"
  transcript=""
  if [[ -d "$project_dir" ]]; then
    transcript="$(find "$project_dir" -maxdepth 1 -type f -name '*.jsonl' \
      -printf '%T@\t%f\n' 2>/dev/null | sort -nr | head -1 | cut -f2-)"
  fi

  if [[ -n "$transcript" ]]; then
    printf 'transcript:%s\n' "${transcript%.jsonl}"
    return 0
  fi

  if [[ -n "$claude_pid" ]] && kill -0 "$claude_pid" 2>/dev/null; then
    local stat_key
    stat_key="$(ps -o lstart= -p "$claude_pid" 2>/dev/null | sed 's/^ *//;s/  */ /g')"
    if [[ -n "$stat_key" ]]; then
      printf 'pid:%s:%s\n' "$claude_pid" "$stat_key"
      return 0
    fi
  fi

  printf 'unknown:%s\n' "$(date +%s)"
}

boot_relay_text() {
  local bot_name="$1"
  local bot_username="$2"
  local include_cron="${3:-1}"
  local text cron_block

  text="@${bot_username} 啟動自我檢視"
  if [[ "$include_cron" == "1" ]]; then
    cron_block="$("$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh" "$bot_name" 2>/dev/null || true)"
    if [[ -n "$cron_block" ]]; then
      text="${text}${cron_block}"
    fi
  fi
  printf '%s\n' "$text"
}

boot_relay_mark_sent() {
  local stamp_file="$1"
  local tmp="${stamp_file}.tmp.$$"
  shift
  mkdir -p "$(dirname "$stamp_file")"
  printf '%s\n' "$@" > "$tmp"
  mv "$tmp" "$stamp_file"
}

send_boot_relay() {
  local bot_name="$1"
  local bot_username="$2"
  local claude_pid="$3"
  local relay_dir="$4"
  local state_dir="${5:-$HOME/.claude-bots/bots/$bot_name}"
  local session_key stamp_dir stamp_file include_cron relay_file text_json

  session_key="$(boot_relay_session_key "$bot_name" "$claude_pid")"
  stamp_dir="$state_dir/.boot-relay"
  stamp_file="$stamp_dir/cron-init.sent"
  include_cron=1

  if [[ -f "$stamp_file" ]] && grep -Fxq "$session_key" "$stamp_file" 2>/dev/null; then
    include_cron=0
  fi

  relay_file="$relay_dir/boot-${bot_name}-$$.json"
  text_json="$(boot_relay_text "$bot_name" "$bot_username" "$include_cron" \
    | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n"), ensure_ascii=False))')"

  mkdir -p "$relay_dir"
  cat > "${relay_file}.tmp" <<EOF
{"from_bot":"system","chat_id":"self","text":${text_json},"message_id":0,"ts":"$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S.000+08:00')"}
EOF
  mv "${relay_file}.tmp" "$relay_file"

  if [[ "$include_cron" == "1" ]]; then
    boot_relay_mark_sent "$stamp_file" "$session_key" "sent_at=$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S%z')" "relay_file=$(basename "$relay_file")"
  fi

  if [[ "${BOOT_RELAY_KEEP_FILES:-0}" != "1" ]]; then
    sleep "${BOOT_RELAY_CLEANUP_SECONDS:-30}"
    rm -f "$relay_file" "${relay_file}.read-by-${bot_username}"
  fi
}

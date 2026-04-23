#!/usr/bin/env bash
# save_session_on_kill.sh — sourced by bot start.sh files
# Call: save_session_on_kill "$SESSION_FILE" "$CLAUDE_PID"

save_session_on_kill() {
  local session_file="$1"
  local claude_pid="$2"

  # Kill claude child first so it doesn't interfere
  if [[ -n "$claude_pid" ]] && kill -0 "$claude_pid" 2>/dev/null; then
    kill "$claude_pid" 2>/dev/null
  fi

  # Atomic update of session.json
  if [[ -f "$session_file" ]]; then
    local tmp
    tmp=$(mktemp)
    python3 - "$session_file" "$tmp" <<'PYEOF'
import json, sys, datetime
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as f:
        s = json.load(f)
    s['lastActiveAt'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    s['in_flight'] = []
    with open(dst, 'w') as f:
        json.dump(s, f, ensure_ascii=False, indent=2)
except Exception as e:
    sys.exit(1)
PYEOF
    if [[ $? -eq 0 && -s "$tmp" ]]; then
      mv "$tmp" "$session_file"
    else
      rm -f "$tmp"
    fi
  fi

  exit 0
}

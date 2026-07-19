#!/usr/bin/env bash
# pod-start-guard.sh - prevent pod-managed bots from legacy tmux/manual starts.

set -u

pod_start_guard_repo_root() {
  printf '%s\n' "${POD_START_GUARD_REPO_ROOT:-$HOME/.claude-bots}"
}

pod_start_guard_pod_for_bot() {
  local bot_name="$1"
  local repo_root
  repo_root="$(pod_start_guard_repo_root)"

  python3 - "$repo_root" "$bot_name" <<'PY'
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
bot_name = sys.argv[2]
pods_dir = repo / "pod-system" / "pods"
if not pods_dir.is_dir():
    raise SystemExit(0)

for path in sorted(pods_dir.glob("*.json")):
    try:
        data = json.loads(path.read_text())
    except Exception:
        continue
    for bot in data.get("bots", []) or []:
        if isinstance(bot, dict) and bot.get("name") == bot_name:
            print(path.stem)
            raise SystemExit(0)
PY
}

pod_start_guard_has_tmux_ancestor() {
  local proc_dir="${POD_START_GUARD_PROC_DIR:-/proc}"
  local pid="${POD_START_GUARD_PARENT_PID:-$PPID}"
  local depth=0
  local comm ppid status

  while [[ -n "$pid" && "$pid" != "0" && $depth -lt 32 ]]; do
    comm=""
    [[ -r "$proc_dir/$pid/comm" ]] && comm="$(<"$proc_dir/$pid/comm")"
    if [[ "$comm" == tmux* ]]; then
      return 0
    fi

    status="$proc_dir/$pid/status"
    if [[ ! -r "$status" ]]; then
      break
    fi
    ppid="$(awk '/^PPid:/ {print $2; exit}' "$status" 2>/dev/null || true)"
    [[ -z "$ppid" || "$ppid" == "$pid" ]] && break
    pid="$ppid"
    depth=$((depth + 1))
  done

  return 1
}

enforce_pod_start_guard() {
  local bot_name="$1"
  local pod_name
  pod_name="$(pod_start_guard_pod_for_bot "$bot_name" 2>/dev/null || true)"

  [[ -z "$pod_name" ]] && return 0

  if pod_start_guard_has_tmux_ancestor; then
    {
      printf 'ERROR: %s is managed by pod %s and must not be started through legacy tmux/manual start.sh.\n' "$bot_name" "$pod_name"
      printf 'Use: systemctl --user restart pod@%s\n' "$pod_name"
    } >&2
    return 1
  fi

  return 0
}

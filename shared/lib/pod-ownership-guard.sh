#!/usr/bin/env bash
# Refuse legacy tmux startup when a bot is owned by an active pod unit.

set -u

BOT_NAME="${1:-}"
ROOT="${CLAUDE_BOTS_ROOT:-$HOME/.claude-bots}"
PODS_DIR="$ROOT/pod-system/pods"

if [[ -z "$BOT_NAME" ]]; then
  echo "pod-ownership-guard: bot name required" >&2
  exit 2
fi

# Fail open when pod infrastructure is unavailable; this preserves legacy
# recovery for hosts that have not migrated to gateway pods.
if [[ ! -d "$PODS_DIR" ]] || ! command -v jq >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
  exit 0
fi

for config in "$PODS_DIR"/*.json; do
  [[ -f "$config" ]] || continue
  if ! jq -e --arg bot "$BOT_NAME" '.bots[]? | select(.name == $bot)' "$config" >/dev/null 2>&1; then
    continue
  fi

  pod_name=$(jq -r '.podName // empty' "$config" 2>/dev/null)
  [[ -n "$pod_name" ]] || continue
  if systemctl --user is-active --quiet "pod@${pod_name}.service"; then
    echo "REFUSE legacy startup: bot '$BOT_NAME' is owned by active pod@${pod_name}.service" >&2
    exit 1
  fi
done

exit 0

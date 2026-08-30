#!/usr/bin/env bash
set -u

# Human restarts must enter here. The unit separately calls
# --record-systemd-start so boot/crash/direct starts remain auditable without
# being mistaken for a second human operator.

umask 077

readonly SERVICE="mvp-server.service"
readonly DEFAULT_REPO="/home/oldrabbit/.claude-bots/mvp"
readonly DEFAULT_LOG="/home/oldrabbit/.claude-bots/logs/mvp-restart-guard.jsonl"
readonly DEFAULT_STATE="${XDG_RUNTIME_DIR:-/run/user/$(timeout 5s id -u)}/mvp-restart-guard.state"

TEST_MODE="${MVP_RESTART_TEST_MODE:-0}"
REPO="${MVP_RESTART_REPO:-$DEFAULT_REPO}"
LOG_FILE="${MVP_RESTART_LOG_FILE:-$DEFAULT_LOG}"
STATE_FILE="${MVP_RESTART_STATE_FILE:-$DEFAULT_STATE}"
PENDING_FILE="${MVP_RESTART_PENDING_FILE:-${STATE_FILE}.pending}"
WINDOW_SEC="${MVP_RESTART_WINDOW_SEC:-300}"
SYSTEMCTL_BIN="${MVP_RESTART_SYSTEMCTL_BIN:-/usr/bin/systemctl}"
SYSTEMCTL_TIMEOUT="${MVP_RESTART_SYSTEMCTL_TIMEOUT:-45}"
WALL_BIN="${MVP_RESTART_WALL_BIN:-/usr/bin/wall}"

if [[ "$TEST_MODE" != "1" ]]; then
  REPO="$DEFAULT_REPO"
  LOG_FILE="$DEFAULT_LOG"
  STATE_FILE="$DEFAULT_STATE"
  PENDING_FILE="${DEFAULT_STATE}.pending"
  WINDOW_SEC=300
  SYSTEMCTL_BIN="/usr/bin/systemctl"
  SYSTEMCTL_TIMEOUT=45
  WALL_BIN="/usr/bin/wall"
fi

case "$WINDOW_SEC:$SYSTEMCTL_TIMEOUT" in
  *[!0-9:]*|:*|*:) printf 'mvp-restart-guard: invalid numeric setting\n' >&2; exit 2 ;;
esac

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

now_epoch() {
  if [[ "$TEST_MODE" == "1" && -n "${MVP_RESTART_NOW_EPOCH:-}" ]]; then
    printf '%s\n' "$MVP_RESTART_NOW_EPOCH"
  else
    timeout 5s date +%s
  fi
}

iso_for_epoch() {
  timeout 5s date -u -d "@$1" +'%Y-%m-%dT%H:%M:%SZ'
}

git_head() {
  local head
  if head=$(timeout 5s git -C "$REPO" rev-parse HEAD 2>/dev/null) &&
     [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$head"
  else
    printf 'unknown\n'
  fi
}

append_event() {
  local ts="$1" kind="$2" actor="$3" head="$4" conflict="$5" detail="$6"
  local parent=${LOG_FILE%/*}
  [[ "$parent" == "$LOG_FILE" ]] && parent=.
  if ! timeout 5s mkdir -p "$parent"; then
    printf 'mvp-restart-guard: cannot create log directory: %s\n' "$parent" >&2
    return 1
  fi
  printf '{"ts":"%s","event":"%s","service":"%s","actor":"%s","git_head":"%s","conflict":%s,"detail":"%s"}\n' \
    "$(json_escape "$ts")" "$(json_escape "$kind")" "$SERVICE" \
    "$(json_escape "$actor")" "$(json_escape "$head")" "$conflict" \
    "$(json_escape "$detail")" >>"$LOG_FILE"
}

warn_proceed() {
  printf 'WARNING: %s; restart/lifecycle action will proceed without that coordination record\n' "$1" >&2
}

record_systemd_start() {
  local epoch ts head actor
  epoch=$(now_epoch) || exit 2
  ts=$(iso_for_epoch "$epoch") || exit 2
  head=$(git_head)
  actor="systemd:${INVOCATION_ID:-unknown}"
  append_event "$ts" "systemd_start" "$actor" "$head" false \
    "automatic recovery and direct starts are audit-only; human conflict state unchanged" || \
    warn_proceed "cannot append systemd-start audit event"
  printf 'mvp-restart-guard: recorded systemd start actor=%s head=%s\n' "$actor" "$head"
}

record_systemd_stop() {
  local epoch ts head result actor state_parent lock_file
  local pending_epoch= pending_actor= pending_head=
  epoch=$(now_epoch) || exit 2
  ts=$(iso_for_epoch "$epoch") || exit 2
  head=$(git_head)
  result="${SERVICE_RESULT:-unknown}"
  actor="systemd:${INVOCATION_ID:-unknown}"

  # systemd supplies SERVICE_RESULT to ExecStopPost. A crash/kill is an
  # automatic lifecycle event, not a human coordination event.
  if [[ "$result" != "success" ]]; then
    append_event "$ts" "systemd_stop" "$actor" "$head" false \
      "automatic stop service_result=$result; human conflict state unchanged" || \
      warn_proceed "cannot append automatic-stop audit event"
    printf 'mvp-restart-guard: recorded automatic stop result=%s\n' "$result"
    return
  fi

  state_parent=${STATE_FILE%/*}
  [[ "$state_parent" == "$STATE_FILE" ]] && state_parent=.
  timeout 5s mkdir -p "$state_parent" || exit 2
  lock_file="${STATE_FILE}.lock"
  exec 8>"$lock_file" || exit 2
  timeout 7s flock -w 5 8 || { printf 'mvp-restart-guard: stop-hook lock unavailable\n' >&2; exit 2; }

  if [[ -r "$PENDING_FILE" ]]; then
    IFS=$'\t' read -r pending_epoch pending_actor pending_head <"$PENDING_FILE" || true
  fi
  if [[ "$pending_epoch" =~ ^[0-9]+$ ]] && (( epoch >= pending_epoch && epoch - pending_epoch <= 120 )); then
    timeout 5s rm -f "$PENDING_FILE" || exit 2
    append_event "$ts" "coordinated_human_stop" "${pending_actor:-unknown}" \
      "${pending_head:-$head}" false "guard token consumed service_result=success"
    printf 'mvp-restart-guard: coordinated stop token consumed actor=%s\n' "${pending_actor:-unknown}"
  else
    local state_tmp="${STATE_FILE}.tmp.$$"
    timeout 5s rm -f "$PENDING_FILE" || exit 2
    printf '%s\t%s\t%s\n' "$epoch" "uncoordinated-systemctl" "$head" >"$state_tmp" || exit 2
    timeout 5s mv "$state_tmp" "$STATE_FILE" || exit 2
    append_event "$ts" "uncoordinated_human_stop" "$actor" "$head" true \
      "no current guard token service_result=success; warning broadcast with wall"
    printf 'WARNING: uncoordinated manual stop/restart of %s; use mvp-restart-guard.sh (actor=%s head=%s)\n' \
      "$SERVICE" "$actor" "$head" |
      timeout 5s "$WALL_BIN" || printf 'mvp-restart-guard: wall warning failed\n' >&2
  fi
  exec 8>&-
}

if [[ "${1:-}" == "--record-systemd-start" ]]; then
  [[ $# -eq 1 ]] || { printf 'usage: %s [--record-systemd-start]\n' "$0" >&2; exit 2; }
  record_systemd_start
  exit 0
fi
if [[ "${1:-}" == "--record-systemd-stop" ]]; then
  [[ $# -eq 1 ]] || { printf 'usage: %s [--record-systemd-start|--record-systemd-stop]\n' "$0" >&2; exit 2; }
  record_systemd_stop
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'usage: %s [--record-systemd-start|--record-systemd-stop]\n' "$0" >&2; exit 2; }

epoch=$(now_epoch) || exit 2
[[ "$epoch" =~ ^[0-9]+$ ]] || { printf 'mvp-restart-guard: invalid current epoch\n' >&2; exit 2; }
ts=$(iso_for_epoch "$epoch") || exit 2
head=$(git_head)
actor="${MVP_RESTART_ACTOR:-${SUDO_USER:-}}"
if [[ -z "$actor" ]]; then
  actor=$(timeout 5s id -un) || actor=unknown
fi
tty_name=$(timeout 5s tty 2>/dev/null) || tty_name=no-tty

state_parent=${STATE_FILE%/*}
[[ "$state_parent" == "$STATE_FILE" ]] && state_parent=.
coordination_ready=true
if ! timeout 5s mkdir -p "$state_parent"; then
  warn_proceed "cannot create restart state directory $state_parent"
  coordination_ready=false
fi

lock_file="${STATE_FILE}.lock"
if [[ "$coordination_ready" == "true" ]] && ! exec 9>"$lock_file"; then
  warn_proceed "cannot open restart coordination lock $lock_file"
  coordination_ready=false
fi
if [[ "$coordination_ready" == "true" ]] && ! timeout 7s flock -w 5 9; then
  warn_proceed "restart coordination lock timed out"
  append_event "$ts" "human_restart_request" "$actor" "$head" true \
    "coordination_lock_timeout tty=$tty_name" || \
    warn_proceed "cannot append coordination-timeout audit event"
  exec 9>&-
elif [[ "$coordination_ready" == "true" ]]; then
  previous_epoch= previous_actor= previous_head=
  if [[ -r "$STATE_FILE" ]]; then
    IFS=$'\t' read -r previous_epoch previous_actor previous_head <"$STATE_FILE" || true
  fi

  conflict=false
  detail="tty=$tty_name"
  if [[ "$previous_epoch" =~ ^[0-9]+$ ]] && (( epoch >= previous_epoch )); then
    age=$((epoch - previous_epoch))
    if (( age <= WINDOW_SEC )); then
      conflict=true
      printf 'WARNING: second human restart within %ss (previous actor=%s age=%ss head=%s)\n' \
        "$WINDOW_SEC" "${previous_actor:-unknown}" "$age" "${previous_head:-unknown}" >&2
      detail="second_human_restart previous_actor=${previous_actor:-unknown} age_sec=$age previous_head=${previous_head:-unknown} tty=$tty_name"
    fi
  fi

  state_tmp="${STATE_FILE}.tmp.$$"
  if ! printf '%s\t%s\t%s\n' "$epoch" "$actor" "$head" >"$state_tmp" ||
     ! timeout 5s mv "$state_tmp" "$STATE_FILE"; then
    warn_proceed "cannot update restart coordination state $STATE_FILE"
  fi
  pending_tmp="${PENDING_FILE}.tmp.$$"
  if ! printf '%s\t%s\t%s\n' "$epoch" "$actor" "$head" >"$pending_tmp" ||
     ! timeout 5s mv "$pending_tmp" "$PENDING_FILE"; then
    warn_proceed "cannot write coordinated-stop token $PENDING_FILE"
  fi
  append_event "$ts" "human_restart_request" "$actor" "$head" "$conflict" "$detail" || \
    warn_proceed "cannot append human restart audit event"
  exec 9>&-
else
  append_event "$ts" "human_restart_request" "$actor" "$head" true \
    "coordination_state_unavailable tty=$tty_name" || \
    warn_proceed "cannot append coordination-bypass audit event"
fi

printf 'mvp-restart-guard: restarting %s actor=%s head=%s\n' "$SERVICE" "$actor" "$head"
timeout "${SYSTEMCTL_TIMEOUT}s" "$SYSTEMCTL_BIN" --user restart "$SERVICE"
restart_rc=$?
timeout 5s rm -f "$PENDING_FILE" || true
result_epoch=$(now_epoch) || result_epoch="$epoch"
result_ts=$(iso_for_epoch "$result_epoch") || result_ts="$ts"
append_event "$result_ts" "human_restart_result" "$actor" "$head" false "exit_code=$restart_rc" || \
  warn_proceed "cannot append restart-result audit event"
if (( restart_rc != 0 )); then
  printf 'mvp-restart-guard: restart failed exit=%s\n' "$restart_rc" >&2
fi
exit "$restart_rc"

#!/usr/bin/env bash
# pod-move.sh — move one bot between pod-system pods.
#
# Default mode is dry-run.  --execute requires --confirm=<bot>.
# Restart order is intentionally fixed: restart source first, then enable target.
# This avoids two pods polling the same Telegram token at the same time.

set -euo pipefail

ROOT_DIR="${POD_MOVE_ROOT:-/home/oldrabbit/.claude-bots}"
GATEWAY_DIR="${POD_MOVE_GATEWAY_DIR:-${ROOT_DIR}/pod-system}"
PODS_DIR="${POD_MOVE_PODS_DIR:-${GATEWAY_DIR}/pods}"
LOGS_DIR="${POD_MOVE_LOGS_DIR:-${ROOT_DIR}/logs}"
AUDIT_LOG="${POD_MOVE_AUDIT_LOG:-${LOGS_DIR}/pod-moves.jsonl}"
LOCK_FILE="${POD_MOVE_LOCK_FILE:-${ROOT_DIR}/shared/.pod-move.lock}"
POD_UNIT_PREFIX="${POD_UNIT_PREFIX:-pod@}"
HEARTBEAT_TEMPLATE="${POD_MOVE_HEARTBEAT_TEMPLATE:-${GATEWAY_DIR}/heartbeat-%s.txt}"
LOG_TEMPLATE="${POD_MOVE_LOG_TEMPLATE:-${GATEWAY_DIR}/gateway-%s.log}"
DB_PATH_TEMPLATE="${POD_MOVE_DB_PATH_TEMPLATE:-${GATEWAY_DIR}/pods-db/gateway-%s.db}"
SYSTEMCTL_CMD="${POD_MOVE_SYSTEMCTL_CMD:-systemctl --user}"
MM_POST_CMD="${POD_MOVE_MM_POST_CMD:-${ROOT_DIR}/shared/bin/mm_post}"
DRAIN_TIMEOUT_SEC="${POD_MOVE_DRAIN_TIMEOUT_SEC:-300}"
DRAIN_POLL_SEC="${POD_MOVE_DRAIN_POLL_SEC:-2}"
HEARTBEAT_MAX_AGE_SEC="${POD_MOVE_HEARTBEAT_MAX_AGE_SEC:-60}"
VERIFY_TIMEOUT_SEC="${POD_MOVE_VERIFY_TIMEOUT_SEC:-60}"
WHO="${POD_MOVE_WHO:-${USER:-unknown}}"

usage() {
  cat >&2 <<'USAGE'
Usage: pod-move.sh <bot> <target-pod> [--execute|--drain|--force] [--confirm=<bot>]

Default is dry-run. --execute mutates config and restarts pods only when
--confirm=<bot> exactly matches the bot being moved.
USAGE
  exit 2
}

die() {
  echo "pod-move: ERROR: $*" >&2
  exit 1
}

info() {
  echo "pod-move: $*" >&2
}

json_quote() {
  jq -Rn --arg v "$1" '$v'
}

now_iso() {
  date -Is
}

now_epoch() {
  date +%s
}

audit() {
  local result="$1" note="${2:-}" duration="${3:-0}"
  mkdir -p "$(dirname "$AUDIT_LOG")"
  jq -cn \
    --arg ts "$(now_iso)" \
    --arg who "$WHO" \
    --arg bot "${BOT:-}" \
    --arg from "${SOURCE_POD:-}" \
    --arg to "${TARGET_POD:-}" \
    --arg result "$result" \
    --arg note "$note" \
    --argjson duration "$duration" \
    '{ts:$ts,who:$who,bot:$bot,from:$from,to:$to,result:$result,duration_sec:$duration,note:$note}' \
    >>"$AUDIT_LOG"
}

notify() {
  local text="$1"
  if [[ -x "$MM_POST_CMD" ]]; then
    "$MM_POST_CMD" "$text" >/dev/null 2>&1 || true
  fi
}

unit_name() {
  printf '%s%s.service' "$POD_UNIT_PREFIX" "$1"
}

heartbeat_path() {
  printf "$HEARTBEAT_TEMPLATE" "$1"
}

log_path() {
  printf "$LOG_TEMPLATE" "$1"
}

db_path_for_pod() {
  local pod="$1" config
  config="$PODS_DIR/$pod.json"
  if [[ -f "$config" ]]; then
    jq -r '.dbPath // empty' "$config"
  else
    printf "$DB_PATH_TEMPLATE" "$pod"
  fi
}

pod_config() {
  printf '%s/%s.json' "$PODS_DIR" "$1"
}

validate_target_pod() {
  [[ "$TARGET_POD" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "invalid target pod name: $TARGET_POD"
}

require_tools() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
  command -v flock >/dev/null 2>&1 || missing+=("flock")
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
}

self_restart_guard() {
  [[ "${POD_MOVE_SKIP_SELF_CHECK:-0}" == "1" ]] && return 0
  command -v pstree >/dev/null 2>&1 || return 0
  local tree source_unit target_unit
  tree="$(pstree -s "$$" 2>/dev/null || true)"
  source_unit="$(unit_name "${SOURCE_POD:-}")"
  target_unit="$(unit_name "${TARGET_POD:-}")"
  if [[ -n "$SOURCE_POD" && "$tree" == *"$source_unit"* ]]; then
    die "refusing self-restart from inside $source_unit; run from outside the pod"
  fi
  if [[ -n "$TARGET_POD" && "$tree" == *"$target_unit"* ]]; then
    die "refusing self-restart from inside $target_unit; run from outside the pod"
  fi
}

find_source_pod() {
  local matches=()
  shopt -s nullglob
  local file pod count
  for file in "$PODS_DIR"/*.json; do
    [[ "$file" == *.bak* ]] && continue
    pod="$(basename "$file" .json)"
    count="$(jq --arg bot "$BOT" '[.bots[]? | select(.name == $bot)] | length' "$file")"
    if [[ "$count" -gt 0 ]]; then
      matches+=("$pod")
    fi
  done
  shopt -u nullglob

  if ((${#matches[@]} == 0)); then
    die "bot $BOT is not present in any pod config under $PODS_DIR"
  fi
  if ((${#matches[@]} > 1)); then
    die "bot $BOT appears in multiple pods: ${matches[*]}"
  fi
  SOURCE_POD="${matches[0]}"
}

running_task_count() {
  local pod="$1" db
  db="$(db_path_for_pod "$pod")"
  [[ -n "$db" && -f "$db" ]] || {
    echo 0
    return 0
  }
  sqlite3 "$db" "select count(*) from tasks where status='running' or (started_at is not null and finished_at is null);" 2>/dev/null || echo 0
}

ensure_no_running_or_drain() {
  local phase="$1" count start now
  start="$(now_epoch)"
  while true; do
    count="$(running_task_count "$SOURCE_POD")"
    count="${count//$'\n'/}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if [[ "$count" -eq 0 ]]; then
      return 0
    fi
    if [[ "$FORCE" == "1" ]]; then
      info "$phase: --force set; bypassing $count running task(s) in source pod $SOURCE_POD"
      return 0
    fi
    if [[ "$DRAIN" != "1" ]]; then
      die "$phase: source pod $SOURCE_POD has $count running task(s); use --drain to wait or --force to override"
    fi
    now="$(now_epoch)"
    if ((now - start >= DRAIN_TIMEOUT_SEC)); then
      die "$phase: timed out waiting for $count running task(s) in $SOURCE_POD"
    fi
    info "$phase: waiting for $count running task(s) in $SOURCE_POD"
    sleep "$DRAIN_POLL_SEC"
  done
}

print_plan() {
  cat <<PLAN
pod-move plan
  bot:        $BOT
  from:       $SOURCE_POD
  to:         $TARGET_POD
  mode:       $([[ "$EXECUTE" == "1" ]] && echo execute || echo dry-run)
  source unit: $(unit_name "$SOURCE_POD")
  target unit: $(unit_name "$TARGET_POD")
  source db:  $(db_path_for_pod "$SOURCE_POD")
  target db:  $(db_path_for_pod "$TARGET_POD")
  source heartbeat: $(heartbeat_path "$SOURCE_POD")
  target heartbeat: $(heartbeat_path "$TARGET_POD")
  source log: $(log_path "$SOURCE_POD")
  target log: $(log_path "$TARGET_POD")
  roster: shared/team-config.json is report-only and will not be changed
PLAN
}

backup_configs() {
  TS="$(date +%Y%m%dT%H%M%S)"
  SOURCE_CONFIG="$(pod_config "$SOURCE_POD")"
  TARGET_CONFIG="$(pod_config "$TARGET_POD")"
  SOURCE_BAK="${SOURCE_CONFIG}.bak-${TS}-podmove-${BOT}"
  TARGET_BAK="${TARGET_CONFIG}.bak-${TS}-podmove-${BOT}"
  cp "$SOURCE_CONFIG" "$SOURCE_BAK"
  if [[ -f "$TARGET_CONFIG" ]]; then
    cp "$TARGET_CONFIG" "$TARGET_BAK"
  else
    TARGET_WAS_MISSING=1
  fi
}

write_configs() {
  local bot_json tmp_source tmp_target target_db
  bot_json="$(jq -c --arg bot "$BOT" '.bots[] | select(.name == $bot)' "$SOURCE_CONFIG")"
  [[ -n "$bot_json" ]] || die "bot $BOT disappeared from $SOURCE_CONFIG"
  tmp_source="${SOURCE_CONFIG}.tmp-podmove-$$"
  tmp_target="${TARGET_CONFIG}.tmp-podmove-$$"

  jq --arg bot "$BOT" '.bots = ([.bots[]? | select(.name != $bot)])' "$SOURCE_CONFIG" >"$tmp_source"

  if [[ -f "$TARGET_CONFIG" ]]; then
    jq --argjson bot "$bot_json" '.bots = ((.bots // []) + [$bot])' "$TARGET_CONFIG" >"$tmp_target"
  else
    target_db="$(printf "$DB_PATH_TEMPLATE" "$TARGET_POD")"
    jq -n --arg pod "$TARGET_POD" --argjson bot "$bot_json" --arg db "$target_db" \
      '{
        podName:$pod,
        bots:[$bot],
        maxConcurrent:2,
        hotMax:2,
        hotIdleMs:14400000,
        workerTimeoutMs:600000,
        load1Ceiling:0,
        rotationThreshold:60,
        rotationOwnerActiveMin:30,
        dbPath:$db
      }' >"$tmp_target"
  fi

  mv "$tmp_source" "$SOURCE_CONFIG"
  mv "$tmp_target" "$TARGET_CONFIG"
}

run_systemctl() {
  local pod="${!#}" args=("${@:1:$#-1}")
  # shellcheck disable=SC2086
  $SYSTEMCTL_CMD "${args[@]}" "$(unit_name "$pod")"
}

restart_sequence() {
  # Source must be restarted first to release the Telegram token before target starts polling.
  run_systemctl restart "$SOURCE_POD" || return 1
  run_systemctl enable --now "$TARGET_POD" || return 2
}

stop_target_for_rollback() {
  run_systemctl stop "$TARGET_POD" || true
}

restore_backups() {
  cp "$SOURCE_BAK" "$SOURCE_CONFIG"
  if [[ "${TARGET_WAS_MISSING:-0}" == "1" ]]; then
    rm -f "$TARGET_CONFIG"
  else
    cp "$TARGET_BAK" "$TARGET_CONFIG"
  fi
}

heartbeat_fresh() {
  local pod="$1" file age now mtime
  file="$(heartbeat_path "$pod")"
  [[ -f "$file" ]] || return 1
  now="$(now_epoch)"
  mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
  age=$((now - mtime))
  ((age <= HEARTBEAT_MAX_AGE_SEC))
}

log_healthy_for_target() {
  local file
  file="$(log_path "$TARGET_POD")"
  [[ -f "$file" ]] || return 1
  grep -Eq "secrets loaded:.*(^|[^A-Za-z0-9_-])${BOT}([^A-Za-z0-9_-]|$)|bots=.*(^|[^A-Za-z0-9_-])${BOT}([^A-Za-z0-9_-]|$)" "$file" || return 1
  ! grep -Eiq 'getUpdates|409|Conflict' "$file"
}

systemctl_secondary_check() {
  local pod="$1"
  if ! run_systemctl is-active "$pod" >/dev/null 2>&1; then
    info "warning: systemctl active check unavailable or inactive for $(unit_name "$pod"); heartbeat remains primary"
  fi
  if ! run_systemctl is-enabled "$pod" >/dev/null 2>&1; then
    info "warning: systemctl enabled check unavailable or disabled for $(unit_name "$pod"); heartbeat remains primary"
  fi
}

verify_success() {
  local start now
  start="$(now_epoch)"
  while true; do
    if heartbeat_fresh "$SOURCE_POD" && heartbeat_fresh "$TARGET_POD" && log_healthy_for_target; then
      systemctl_secondary_check "$SOURCE_POD"
      systemctl_secondary_check "$TARGET_POD"
      return 0
    fi
    now="$(now_epoch)"
    ((now - start >= VERIFY_TIMEOUT_SEC)) && return 1
    sleep 2
  done
}

verify_source_after_rollback() {
  local start now
  start="$(now_epoch)"
  while true; do
    heartbeat_fresh "$SOURCE_POD" && return 0
    now="$(now_epoch)"
    ((now - start >= VERIFY_TIMEOUT_SEC)) && return 1
    sleep 2
  done
}

rollback_after_failure() {
  local reason="$1"
  info "execute failed: $reason; rolling back"
  stop_target_for_rollback
  restore_backups
  if run_systemctl restart "$SOURCE_POD" && verify_source_after_rollback; then
    audit "rollback" "$reason" "$(( $(now_epoch) - START_TS ))"
    notify "@laotu pod-move rollback: bot=$BOT from=$SOURCE_POD to=$TARGET_POD reason=$reason source restored"
    return 1
  fi
  audit "rollback_failed" "$reason; source did not recover after backup restore" "$(( $(now_epoch) - START_TS ))"
  notify "@laotu CRITICAL pod-move rollback failed: bot=$BOT source=$SOURCE_POD target=$TARGET_POD state=config restored from bak but source heartbeat not fresh; manual steps: inspect $(unit_name "$SOURCE_POD"), $(pod_config "$SOURCE_POD"), $(heartbeat_path "$SOURCE_POD")"
  return 1
}

execute_move() {
  [[ "$CONFIRM" == "$BOT" ]] || die "--execute requires --confirm=$BOT"
  self_restart_guard
  ensure_no_running_or_drain "execute-recheck"
  backup_configs
  write_configs
  restart_sequence || rollback_after_failure "restart sequence failed"
  verify_success || rollback_after_failure "post-move verification failed"
  audit "success" "moved" "$(( $(now_epoch) - START_TS ))"
  notify "pod-move success: $BOT $SOURCE_POD -> $TARGET_POD"
}

parse_args() {
  (($# >= 2)) || usage
  BOT="$1"
  TARGET_POD="$2"
  shift 2
  EXECUTE=0
  DRAIN=0
  FORCE=0
  CONFIRM=""
  while (($#)); do
    case "$1" in
      --execute) EXECUTE=1 ;;
      --drain) DRAIN=1 ;;
      --force) FORCE=1 ;;
      --confirm=*) CONFIRM="${1#--confirm=}" ;;
      *) usage ;;
    esac
    shift
  done
}

main() {
  START_TS="$(now_epoch)"
  parse_args "$@"
  require_tools
  validate_target_pod
  [[ "$BOT" == "anya" || "$BOT" == "diana" ]] && die "refusing to move protected bot: $BOT"

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another pod-move is already running"

  find_source_pod
  if [[ "$SOURCE_POD" == "$TARGET_POD" ]]; then
    print_plan
    audit "noop" "bot already in target pod" "$(( $(now_epoch) - START_TS ))"
    exit 0
  fi

  self_restart_guard
  ensure_no_running_or_drain "preflight"
  print_plan

  if [[ "$EXECUTE" != "1" ]]; then
    audit "dry_run" "no mutation" "$(( $(now_epoch) - START_TS ))"
    exit 0
  fi

  execute_move
}

main "$@"

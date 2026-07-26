#!/usr/bin/env bash
# long-task-manifest.sh — register and inspect restart-safe long-task leases.

set -uo pipefail

STATE_DIR="${LONG_TASK_STATE_DIR:-/home/oldrabbit/.claude-bots/shared/state/long-tasks}"
DEFAULT_STALE_AFTER="${LONG_TASK_STALE_AFTER_SECONDS:-300}"
NOW_EPOCH="${LONG_TASK_NOW_EPOCH:-}"

usage() {
  cat <<'EOF'
Usage:
  long-task-manifest.sh register --id ID --owner-bot BOT --pod POD --pid PID \
    --pgid PGID --expected-duration SECONDS --desc TEXT
  long-task-manifest.sh heartbeat --id ID
  long-task-manifest.sh clear --id ID
  long-task-manifest.sh list-active --pod POD [--stale-after SECONDS]
  long-task-manifest.sh has-active --pod POD [--stale-after SECONDS]

Manifests are JSON files under shared/state/long-tasks by default. Writes use a
same-directory temporary file plus atomic rename. A manifest is stale only when
its heartbeat_ts is older than --stale-after; file mtime is never consulted.

Environment for fixtures/operators:
  LONG_TASK_STATE_DIR              override state directory
  LONG_TASK_STALE_AFTER_SECONDS    default stale threshold (300)
  LONG_TASK_NOW_EPOCH              injected epoch clock (tests only)

has-active exits 0 when a live or malformed (fail-closed) manifest exists,
1 when none exists, and 2 on invalid input or an inspection failure.
EOF
}

die() {
  printf '[long-task-manifest] ERROR: %s\n' "$*" >&2
  exit 2
}

now_epoch() {
  if [[ -n "$NOW_EPOCH" ]]; then
    [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || die "LONG_TASK_NOW_EPOCH must be an epoch integer"
    printf '%s\n' "$NOW_EPOCH"
  else
    date +%s
  fi
}

iso_from_epoch() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || die "cannot format epoch: $1"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

valid_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
  [[ -d "$STATE_DIR" && -w "$STATE_DIR" ]] || die "state directory is not writable: $STATE_DIR"
}

manifest_path() {
  valid_name "$1" || die "invalid id: $1"
  printf '%s/%s.json\n' "$STATE_DIR" "$1"
}

with_id_lock() {
  local id="$1"; shift
  ensure_state_dir
  local lock_path="$STATE_DIR/.${id}.lock"
  (
    flock -x 9 || exit 2
    "$@"
  ) 9>"$lock_path"
}

atomic_json_write() {
  local target="$1" json="$2"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.long-task.XXXXXX")" || die "cannot create temporary manifest"
  if ! printf '%s\n' "$json" >"$tmp"; then
    rm -f -- "$tmp"
    die "cannot write temporary manifest"
  fi
  chmod 0644 "$tmp" || {
    rm -f -- "$tmp"
    die "cannot chmod temporary manifest"
  }
  if ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    die "cannot atomically install manifest"
  fi
}

register_locked() {
  local target="$1" id="$2" owner="$3" pod="$4" pid="$5" pgid="$6" expected="$7" desc="$8"
  [[ ! -e "$target" ]] || die "manifest already exists: $id"
  local epoch timestamp json
  epoch="$(now_epoch)"
  timestamp="$(iso_from_epoch "$epoch")"
  json="$(jq -cn \
    --arg schema_version "1" --arg id "$id" --arg owner_bot "$owner" --arg pod "$pod" \
    --argjson pid "$pid" --argjson pgid "$pgid" --arg started_at "$timestamp" \
    --argjson expected_duration "$expected" --arg desc "$desc" --arg heartbeat_ts "$timestamp" \
    '{schema_version:($schema_version|tonumber),id:$id,owner_bot:$owner_bot,pod:$pod,
      pid:$pid,pgid:$pgid,started_at:$started_at,expected_duration:$expected_duration,
      desc:$desc,heartbeat_ts:$heartbeat_ts}')" || die "cannot build manifest JSON"
  atomic_json_write "$target" "$json"
  printf '%s\n' "$target"
}

cmd_register() {
  local id="" owner="" pod="" pid="" pgid="" expected="" desc=""
  while (($#)); do
    case "$1" in
      --id) [[ $# -ge 2 ]] || die "--id needs a value"; id="$2"; shift 2 ;;
      --owner-bot) [[ $# -ge 2 ]] || die "--owner-bot needs a value"; owner="$2"; shift 2 ;;
      --pod) [[ $# -ge 2 ]] || die "--pod needs a value"; pod="$2"; shift 2 ;;
      --pid) [[ $# -ge 2 ]] || die "--pid needs a value"; pid="$2"; shift 2 ;;
      --pgid) [[ $# -ge 2 ]] || die "--pgid needs a value"; pgid="$2"; shift 2 ;;
      --expected-duration) [[ $# -ge 2 ]] || die "--expected-duration needs a value"; expected="$2"; shift 2 ;;
      --desc) [[ $# -ge 2 ]] || die "--desc needs a value"; desc="$2"; shift 2 ;;
      *) die "unknown register argument: $1" ;;
    esac
  done
  valid_name "$id" || die "register requires a valid --id"
  valid_name "$owner" || die "register requires a valid --owner-bot"
  valid_name "$pod" || die "register requires a valid --pod"
  valid_uint "$pid" && ((pid > 0)) || die "--pid must be a positive integer"
  valid_uint "$pgid" && ((pgid > 0)) || die "--pgid must be a positive integer"
  valid_uint "$expected" && ((expected > 0)) || die "--expected-duration must be positive seconds"
  [[ -n "$desc" && ${#desc} -le 500 ]] || die "--desc must contain 1..500 characters"
  local target
  ensure_state_dir
  target="$(manifest_path "$id")"
  with_id_lock "$id" register_locked "$target" "$id" "$owner" "$pod" "$pid" "$pgid" "$expected" "$desc"
}

heartbeat_locked() {
  local target="$1" id="$2"
  [[ -f "$target" ]] || die "manifest not found: $id"
  jq -e '
    type=="object" and (.id|type=="string") and (.heartbeat_ts|type=="string")
  ' "$target" >/dev/null 2>&1 || die "refusing to update malformed manifest: $id"
  local epoch timestamp json
  epoch="$(now_epoch)"
  timestamp="$(iso_from_epoch "$epoch")"
  json="$(jq -c --arg heartbeat_ts "$timestamp" '.heartbeat_ts=$heartbeat_ts' "$target")" \
    || die "cannot update manifest: $id"
  atomic_json_write "$target" "$json"
  printf '%s\n' "$target"
}

cmd_heartbeat() {
  local id=""
  while (($#)); do
    case "$1" in
      --id) [[ $# -ge 2 ]] || die "--id needs a value"; id="$2"; shift 2 ;;
      *) die "unknown heartbeat argument: $1" ;;
    esac
  done
  valid_name "$id" || die "heartbeat requires a valid --id"
  local target
  ensure_state_dir
  target="$(manifest_path "$id")"
  with_id_lock "$id" heartbeat_locked "$target" "$id"
}

clear_locked() {
  local target="$1" id="$2"
  [[ -f "$target" ]] || die "manifest not found: $id"
  rm -- "$target" || die "cannot clear manifest: $id"
}

cmd_clear() {
  local id=""
  while (($#)); do
    case "$1" in
      --id) [[ $# -ge 2 ]] || die "--id needs a value"; id="$2"; shift 2 ;;
      *) die "unknown clear argument: $1" ;;
    esac
  done
  valid_name "$id" || die "clear requires a valid --id"
  local target
  ensure_state_dir
  target="$(manifest_path "$id")"
  with_id_lock "$id" clear_locked "$target" "$id"
}

parse_list_args() {
  LIST_POD=""
  LIST_STALE_AFTER="$DEFAULT_STALE_AFTER"
  while (($#)); do
    case "$1" in
      --pod) [[ $# -ge 2 ]] || die "--pod needs a value"; LIST_POD="$2"; shift 2 ;;
      --stale-after) [[ $# -ge 2 ]] || die "--stale-after needs a value"; LIST_STALE_AFTER="$2"; shift 2 ;;
      *) die "unknown list argument: $1" ;;
    esac
  done
  valid_name "$LIST_POD" || die "a valid --pod is required"
  valid_uint "$LIST_STALE_AFTER" || die "--stale-after must be zero or more seconds"
}

active_json() {
  local pod="$1" stale_after="$2" epoch="$3"
  ensure_state_dir
  local output='[]' file record heartbeat heartbeat_epoch record_pod
  shopt -s nullglob
  for file in "$STATE_DIR"/*.json; do
    if ! record="$(jq -c . "$file" 2>/dev/null)"; then
      output="$(jq -c --arg path "$file" '. + [{invalid:true,path:$path,reason:"malformed_json"}]' <<<"$output")"
      continue
    fi
    record_pod="$(jq -r '.pod // empty' <<<"$record")"
    [[ "$record_pod" == "$pod" ]] || continue
    if ! jq -e '
      (.schema_version==1) and (.id|type=="string" and length>0)
      and (.owner_bot|type=="string" and length>0) and (.pod|type=="string" and length>0)
      and (.pid|type=="number") and (.pgid|type=="number")
      and (.started_at|type=="string") and (.expected_duration|type=="number")
      and (.desc|type=="string") and (.heartbeat_ts|type=="string")
    ' <<<"$record" >/dev/null 2>&1; then
      output="$(jq -c --argjson record "$record" '. + [($record + {invalid:true,reason:"invalid_schema"})]' <<<"$output")"
      continue
    fi
    heartbeat="$(jq -r '.heartbeat_ts' <<<"$record")"
    heartbeat_epoch="$(date -u -d "$heartbeat" +%s 2>/dev/null || true)"
    if [[ -z "$heartbeat_epoch" || ! "$heartbeat_epoch" =~ ^[0-9]+$ ]]; then
      output="$(jq -c --argjson record "$record" '. + [($record + {invalid:true,reason:"invalid_heartbeat_ts"})]' <<<"$output")"
      continue
    fi
    # A future heartbeat is active (clock skew fails closed). Equality at the
    # threshold is stale; only age < threshold remains active.
    if ((epoch < heartbeat_epoch || epoch - heartbeat_epoch < stale_after)); then
      output="$(jq -c --argjson record "$record" '. + [$record]' <<<"$output")"
    fi
  done
  printf '%s\n' "$output"
}

cmd_list_active() {
  parse_list_args "$@"
  active_json "$LIST_POD" "$LIST_STALE_AFTER" "$(now_epoch)"
}

cmd_has_active() {
  parse_list_args "$@"
  local result
  result="$(active_json "$LIST_POD" "$LIST_STALE_AFTER" "$(now_epoch)")" || exit 2
  jq -e 'length > 0' <<<"$result" >/dev/null 2>&1
}

main() {
  local command="${1:-}"
  [[ -n "$command" ]] || { usage >&2; exit 2; }
  shift || true
  case "$command" in
    register) cmd_register "$@" ;;
    heartbeat) cmd_heartbeat "$@" ;;
    clear) cmd_clear "$@" ;;
    list-active) cmd_list_active "$@" ;;
    has-active) cmd_has_active "$@" ;;
    --help|-h|help) usage ;;
    *) die "unknown command: $command (use --help)" ;;
  esac
}

main "$@"

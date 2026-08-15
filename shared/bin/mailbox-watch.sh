#!/usr/bin/env bash
# Relay new mac-bridge/to-vps mail to Anya with a durable first-start baseline.
set -euo pipefail

ROOT="${MAILBOX_ROOT:-/home/oldrabbit/.claude-bots}"
MAILBOX_DIR="${MAILBOX_TO_VPS_DIR:-$ROOT/shared/mac-bridge/to-vps}"
RELAY_DIR="${MAILBOX_RELAY_DIR:-$ROOT/relay}"
STATE_DIR="${MAILBOX_WATCH_STATE_DIR:-$ROOT/shared/mac-bridge/.mailbox-watch-state}"
HEALTH_HELPER="${MAILBOX_WATCH_HEALTH_HELPER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mailbox-watch-health.sh}"
POLL_SECONDS="${MAILBOX_WATCH_POLL_SECONDS:-30}"

for command_name in find flock grep inotifywait jq sha256sum sort stdbuf; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "mailbox-watch: missing command: $command_name" >&2
    exit 2
  }
done
[[ -d "$MAILBOX_DIR" ]] || { echo "mailbox-watch: missing mailbox directory: $MAILBOX_DIR" >&2; exit 2; }
[[ -x "$HEALTH_HELPER" ]] || { echo "mailbox-watch: health helper is not executable: $HEALTH_HELPER" >&2; exit 2; }
[[ "$POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "mailbox-watch: MAILBOX_WATCH_POLL_SECONDS must be a positive integer" >&2; exit 2; }

mkdir -p "$RELAY_DIR" "$STATE_DIR/events" "$STATE_DIR/processed"
exec 9>"$STATE_DIR/watcher.lock"
flock -n 9 || { echo "mailbox-watch: another watcher already owns $STATE_DIR/watcher.lock" >&2; exit 1; }

baseline="$STATE_DIR/baseline-v1.nul"
bootstrap_events="$STATE_DIR/bootstrap-events-v1.txt"
bootstrap_pid=""
bootstrap_ready=""

cleanup() {
  if [[ -n "$bootstrap_pid" ]]; then
    kill "$bootstrap_pid" >/dev/null 2>&1 || true
    wait "$bootstrap_pid" >/dev/null 2>&1 || true
  fi
  [[ -z "$bootstrap_ready" ]] || rm -f "$bootstrap_ready"
}
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

# On the very first start, arm inotify before freezing the baseline. Events
# observed while the snapshot is built remain in a durable journal and override
# baseline membership, so a file arriving during initialization is not lost.
initialize_baseline() {
  [[ -e "$baseline" ]] && return 0
  local baseline_tmp
  bootstrap_ready="$(mktemp "$STATE_DIR/.bootstrap-ready.XXXXXX")"
  touch "$bootstrap_events"
  LC_ALL=C stdbuf -oL inotifywait -m -e create -e moved_to --format '%f' "$MAILBOX_DIR" \
    >> "$bootstrap_events" 2> "$bootstrap_ready" &
  bootstrap_pid=$!
  for _ in $(seq 1 100); do
    grep -Fq 'Watches established.' "$bootstrap_ready" && break
    kill -0 "$bootstrap_pid" >/dev/null 2>&1 || {
      echo "mailbox-watch: bootstrap inotifywait exited before establishing its watch" >&2
      exit 1
    }
    sleep 0.02
  done
  grep -Fq 'Watches established.' "$bootstrap_ready" || {
    echo "mailbox-watch: bootstrap inotifywait did not become ready" >&2
    exit 1
  }

  baseline_tmp="$(mktemp "$STATE_DIR/.baseline.XXXXXX")"
  find "$MAILBOX_DIR" -maxdepth 1 -type f -name '*.md' -printf '%f\0' | LC_ALL=C sort -z > "$baseline_tmp"
  if ! ln "$baseline_tmp" "$baseline" 2>/dev/null; then
    [[ -e "$baseline" ]] || { echo "mailbox-watch: could not publish baseline" >&2; exit 1; }
  fi
  rm -f "$baseline_tmp"

  kill "$bootstrap_pid" >/dev/null 2>&1 || true
  wait "$bootstrap_pid" >/dev/null 2>&1 || true
  bootstrap_pid=""
  rm -f "$bootstrap_ready"
  bootstrap_ready=""
}

is_baseline_name() {
  LC_ALL=C grep -Fzxq -- "$1" "$baseline"
}

mark_processed() {
  mkdir "$STATE_DIR/processed/$1" 2>/dev/null || [[ -d "$STATE_DIR/processed/$1" ]]
}

process_name() {
  local name="$1" force="${2:-0}" key relay_name record record_tmp ts
  [[ "$name" == *.md ]] || return 0
  [[ "$name" != */* ]] || { echo "mailbox-watch: rejected unsafe event name: $name" >&2; return 0; }
  [[ -f "$MAILBOX_DIR/$name" ]] || return 0
  if [[ "$force" != 1 ]] && is_baseline_name "$name"; then
    return 0
  fi

  key="$(printf '%s' "$name" | sha256sum | awk '{print $1}')"
  [[ ! -d "$STATE_DIR/processed/$key" ]] || return 0
  relay_name="mailbox-message-$key.json"
  record="$STATE_DIR/events/$relay_name"

  if [[ ! -e "$record" ]]; then
    record_tmp="$(mktemp "$STATE_DIR/events/.mailbox-event.XXXXXX")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -cn --arg name "$name" --arg ts "$ts" '
      {
        from_bot:"mailbox-watch",
        chat_id:"self",
        recipient:"anya",
        text:("mac-bridge 新信："+$name+"（to-vps/），請讀取處理。"),
        message_id:0,
        ts:$ts
      }
    ' > "$record_tmp"
    if ! ln "$record_tmp" "$record" 2>/dev/null; then
      [[ -e "$record" ]] || { rm -f "$record_tmp"; echo "mailbox-watch: could not persist event $name" >&2; exit 1; }
    fi
    rm -f "$record_tmp"
  fi

  # A deterministic relay filename plus the persistent event record closes the
  # SIGKILL window: retry if publication did not happen; otherwise mark it once.
  if [[ ! -e "$RELAY_DIR/$relay_name" && ! -e "$RELAY_DIR/read/$relay_name" && ! -e "$RELAY_DIR/quarantine/$relay_name" ]]; then
    if ! ln "$record" "$RELAY_DIR/$relay_name" 2>/dev/null; then
      [[ -e "$RELAY_DIR/$relay_name" ]] || { echo "mailbox-watch: could not publish relay for $name" >&2; exit 1; }
    fi
  fi
  mark_processed "$key"
}

reconcile() {
  local name
  while IFS= read -r -d '' name; do
    process_name "$name" 0
  done < <(find "$MAILBOX_DIR" -maxdepth 1 -type f -name '*.md' -printf '%f\0')
}

initialize_baseline

# A previous first-start attempt may have died after journaling a create but
# before publishing it. Replaying this journal is harmless because process_name
# has a durable per-name key and deterministic relay filename.
if [[ -r "$bootstrap_events" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && process_name "$name" 1
  done < "$bootstrap_events"
fi

while true; do
  "$HEALTH_HELPER" heartbeat "$$"
  reconcile
  set +e
  event_name="$(LC_ALL=C inotifywait -q -t "$POLL_SECONDS" -e create -e moved_to --format '%f' "$MAILBOX_DIR")"
  inotify_rc=$?
  set -e
  case "$inotify_rc" in
    0) process_name "$event_name" 1 ;;
    2) ;; # timeout: refresh heartbeat and reconcile any event-arm gap
    *) echo "mailbox-watch: inotifywait failed with exit $inotify_rc" >&2; exit "$inotify_rc" ;;
  esac
done

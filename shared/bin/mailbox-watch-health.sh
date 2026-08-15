#!/usr/bin/env bash
# Persist mailbox-watch liveness and surface unexpected exits to Anya.
set -euo pipefail

ROOT="${MAILBOX_ROOT:-/home/oldrabbit/.claude-bots}"
STATE_DIR="${MAILBOX_WATCH_STATE_DIR:-$ROOT/shared/mac-bridge/.mailbox-watch-state}"
HEALTH_FILE="${MAILBOX_WATCH_HEALTH_FILE:-$ROOT/logs/mailbox-watch-health.json}"
RELAY_DIR="${MAILBOX_RELAY_DIR:-$ROOT/relay}"
ACTION="${1:-}"

for command_name in flock jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "mailbox-watch-health: missing command: $command_name" >&2
    exit 2
  }
done

mkdir -p "$STATE_DIR" "$(dirname "$HEALTH_FILE")" "$RELAY_DIR"
exec 9>"$STATE_DIR/health.lock"
flock 9

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_epoch="$(date +%s)"
previous='{}'
if jq -e 'type == "object"' "$HEALTH_FILE" >/dev/null 2>&1; then
  previous="$(<"$HEALTH_FILE")"
fi

write_health() {
  local payload="$1" tmp
  tmp="$(mktemp "$(dirname "$HEALTH_FILE")/.mailbox-watch-health.XXXXXX")"
  printf '%s\n' "$payload" > "$tmp"
  mv -f "$tmp" "$HEALTH_FILE"
}

case "$ACTION" in
  heartbeat)
    pid="${2:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || {
      echo "mailbox-watch-health: heartbeat requires a numeric pid" >&2
      exit 2
    }
    payload="$(jq -cn \
      --argjson old "$previous" --arg ts "$now_iso" --argjson epoch "$now_epoch" --argjson pid "$pid" '
        ($old + {
          schema:"mailbox-watch-health/v1",
          status:"healthy",
          pid:$pid,
          last_heartbeat_at:$ts,
          last_heartbeat_epoch:$epoch
        })
      ')"
    write_health "$payload"
    ;;
  stopped)
    service_result="${2:-unknown}"
    exit_code="${3:-unknown}"
    exit_status="${4:-unknown}"
    failure="$(jq -cn \
      --arg ts "$now_iso" --argjson epoch "$now_epoch" \
      --arg result "$service_result" --arg code "$exit_code" --arg status "$exit_status" \
      '{at:$ts,epoch:$epoch,service_result:$result,exit_code:$code,exit_status:$status}')"
    payload="$(jq -cn --argjson old "$previous" --argjson failure "$failure" '
      ($old + {
        schema:"mailbox-watch-health/v1",
        status:"unhealthy",
        last_failure:$failure
      })
    ')"

    if [[ "$service_result" != "success" ]]; then
      alert_name="mailbox-health-${now_epoch}-$$.json"
      alert_path="$RELAY_DIR/$alert_name"
      alert_tmp="$(mktemp "$RELAY_DIR/.mailbox-health.XXXXXX")"
      jq -cn \
        --arg ts "$now_iso" --arg result "$service_result" \
        --arg code "$exit_code" --arg status "$exit_status" '
          {
            from_bot:"mailbox-watch",
            chat_id:"self",
            recipient:"anya",
            text:("mailbox-watch 異常停止：service_result="+$result+", exit_code="+$code+", exit_status="+$status+"。systemd 會自動重啟，請檢查 mailbox-watch.service 與 health state。"),
            message_id:0,
            ts:$ts
          }
        ' > "$alert_tmp"
      mv -f "$alert_tmp" "$alert_path"
      payload="$(jq -cn --argjson state "$payload" --arg alert "$alert_name" '$state + {last_alert_file:$alert}')"
    fi
    write_health "$payload"
    ;;
  *)
    echo "Usage: mailbox-watch-health.sh heartbeat <pid> | stopped <service-result> <exit-code> <exit-status>" >&2
    exit 2
    ;;
esac

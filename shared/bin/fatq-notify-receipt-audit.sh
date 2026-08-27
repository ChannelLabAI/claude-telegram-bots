#!/usr/bin/env bash
# Audit FATQ *_notified history events for relay consumer markers.
set -euo pipefail

ROOT="${FATQ_NOTIFY_RECEIPT_ROOT:-/home/oldrabbit/.claude-bots}"
TASKS_DIR="${FATQ_NOTIFY_RECEIPT_TASKS_DIR:-$ROOT/tasks}"
RELAY_DIR="${FATQ_NOTIFY_RECEIPT_RELAY_DIR:-$ROOT/relay}"
READ_DIR="${FATQ_NOTIFY_RECEIPT_READ_DIR:-$RELAY_DIR/read}"
PATROL_CONFIG="${FATQ_NOTIFY_RECEIPT_PATROL_CONFIG:-$ROOT/shared/config/patrol-scan.json}"
READERS_CONFIG="${FATQ_NOTIFY_RECEIPT_READERS_CONFIG:-$ROOT/shared/config/relay-consumed-readers.json}"
PODS_DIR="${FATQ_NOTIFY_RECEIPT_PODS_DIR:-$ROOT/pod-system/pods}"
NOW_EPOCH="${FATQ_NOTIFY_RECEIPT_NOW_EPOCH:-$(date +%s)}"
THRESHOLD_SECONDS="${FATQ_NOTIFY_RECEIPT_THRESHOLD_SECONDS:-}"
SINCE_HOURS=24
JSON_OUTPUT=false

usage() {
  echo "Usage: fatq-notify-receipt-audit.sh [--since <hours>] [--json]" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --since)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      SINCE_HOURS="$2"
      shift 2
      ;;
    --json) JSON_OUTPUT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for command_name in jq find awk sort date mktemp basename; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR missing-command=$command_name" >&2
    exit 2
  }
done
[[ "$SINCE_HOURS" =~ ^[0-9]+$ ]] && (( SINCE_HOURS > 0 )) || {
  echo "ERROR since-hours-must-be-positive-integer value=$SINCE_HOURS" >&2
  exit 2
}
[[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR now-epoch-invalid=$NOW_EPOCH" >&2; exit 2; }
[[ -d "$TASKS_DIR" ]] || { echo "ERROR tasks-dir-missing=$TASKS_DIR" >&2; exit 2; }
[[ -d "$RELAY_DIR" ]] || { echo "ERROR relay-dir-missing=$RELAY_DIR" >&2; exit 2; }
[[ -r "$PATROL_CONFIG" ]] || { echo "ERROR patrol-config-missing=$PATROL_CONFIG" >&2; exit 2; }

if [[ -z "$THRESHOLD_SECONDS" ]]; then
  THRESHOLD_SECONDS="$(jq -r '.thresholds_seconds.relay_unconsumed // 900' "$PATROL_CONFIG")"
fi
[[ "$THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || {
  echo "ERROR threshold-seconds-invalid=$THRESHOLD_SECONDS" >&2
  exit 2
}

# This is patrol-scan's true-bot source, augmented with the resident-reader
# config used by relay-consumed-archiver. The latter currently supplies the
# diana/keeper identities that patrol's fallback roster does not yet contain.
TRUE_BOT_FILE="$(mktemp "${TMPDIR:-/tmp}/fatq-notify-true-bots.XXXXXX")"
EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/fatq-notify-events.XXXXXX")"
RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/fatq-notify-results.XXXXXX")"
MARKER_FILE="$(mktemp "${TMPDIR:-/tmp}/fatq-notify-markers.XXXXXX")"
ENVELOPE_FILE="$(mktemp "${TMPDIR:-/tmp}/fatq-notify-envelopes.XXXXXX")"
cleanup() { rm -f "$TRUE_BOT_FILE" "$EVENT_FILE" "$RESULT_FILE" "$MARKER_FILE" "$ENVELOPE_FILE"; }
trap cleanup EXIT

FIELD_SEPARATOR=$'\x1f'

declare -A READER_ALIAS_TO_MARKER=()
declare -A POD_ALIAS_TO_MARKER=()

add_alias_marker() {
  local map_name="$1" alias="${2,,}" marker="$3" existing=""
  [[ -n "$alias" && -n "$marker" ]] || return 0
  if [[ "$map_name" == "reader" ]]; then
    existing="${READER_ALIAS_TO_MARKER[$alias]:-}"
    if [[ -n "$existing" && "${existing,,}" != "${marker,,}" ]]; then
      echo "ERROR readers-config-ambiguous-alias=$alias" >&2
      exit 2
    fi
    READER_ALIAS_TO_MARKER["$alias"]="$marker"
  else
    existing="${POD_ALIAS_TO_MARKER[$alias]:-}"
    if [[ -n "$existing" && "${existing,,}" != "${marker,,}" ]]; then
      echo "ERROR pod-roster-ambiguous-alias=$alias" >&2
      exit 2
    fi
    POD_ALIAS_TO_MARKER["$alias"]="$marker"
  fi
}

if [[ -r "$READERS_CONFIG" ]]; then
  while IFS=$'\t' read -r alias marker; do
    add_alias_marker reader "$alias" "$marker"
  done < <(jq -r '
    .readers[]?
    | select((.marker? | type) == "string" and (.marker | length) > 0)
    | .marker as $marker
    | (.aliases // [])[]?
    | select(type == "string" and length > 0)
    | [., $marker]
    | @tsv
  ' "$READERS_CONFIG")
fi

if [[ -d "$PODS_DIR" ]]; then
  while IFS=$'\t' read -r alias marker; do
    add_alias_marker pod "$alias" "$marker"
  done < <(find "$PODS_DIR" -maxdepth 1 -type f -name '*.json' -exec jq -r '
    .bots[]?
    | select((.username? | type) == "string" and (.username | length) > 0)
    | .username as $marker
    | [.name, $marker][]
    | [., $marker]
    | @tsv
  ' {} + 2>/dev/null || true)
fi

{
  jq -r '.true_bot_recipients_fallback[]?' "$PATROL_CONFIG"
  if [[ -d "$PODS_DIR" ]]; then
    find "$PODS_DIR" -maxdepth 1 -type f -name '*.json' \
      -exec jq -r '.bots[]? | .name, (.username // empty)' {} + 2>/dev/null || true
  fi
  if [[ -r "$READERS_CONFIG" ]]; then
    jq -r '.readers[]? | .system_identity, .roster_id, .dispatch_key, .tg_username, (.aliases[]?)' \
      "$READERS_CONFIG"
  fi
} | awk 'NF { print tolower($0) }' | sort -u > "$TRUE_BOT_FILE"

declare -A TRUE_BOT_SET=()
while IFS= read -r true_bot; do
  [[ -n "$true_bot" ]] && TRUE_BOT_SET["$true_bot"]=1
done < "$TRUE_BOT_FILE"

is_true_bot_recipient() {
  local recipient="${1,,}"
  [[ -n "${TRUE_BOT_SET[$recipient]:-}" ]]
}

expected_marker_for_recipient() {
  local recipient="${1,,}"
  if [[ -n "${READER_ALIAS_TO_MARKER[$recipient]:-}" ]]; then
    printf '%s\n' "${READER_ALIAS_TO_MARKER[$recipient]}"
  elif [[ -n "${POD_ALIAS_TO_MARKER[$recipient]:-}" ]]; then
    printf '%s\n' "${POD_ALIAS_TO_MARKER[$recipient]}"
  elif [[ "$recipient" == *bot ]]; then
    # A true-bot recipient already expressed as its Telegram username is its
    # own marker suffix. Non-bots never reach this fallback.
    printf '%s\n' "$1"
  fi
}

find "$RELAY_DIR" "$READ_DIR" -maxdepth 1 -type f -name '*.read-by-*' -printf '%f\n' 2>/dev/null \
  | sort -u > "$MARKER_FILE"
declare -A MARKER_IDENTITY_SET=()
while IFS= read -r marker_name; do
  [[ -n "$marker_name" ]] || continue
  marker_stem="${marker_name%%.read-by-*}"
  marker_identity="${marker_name##*.read-by-}"
  [[ -n "$marker_stem" && -n "$marker_identity" ]] \
    && MARKER_IDENTITY_SET["$marker_stem$FIELD_SEPARATOR${marker_identity,,}"]=1
done < "$MARKER_FILE"

find "$RELAY_DIR" "$READ_DIR" -maxdepth 1 -type f -name '*.json' -exec \
  jq -r --arg separator "$FIELD_SEPARATOR" '
    [(input_filename | split("/") | last),
     (if (.recipient? | type) == "string" then .recipient else "" end)]
    | join($separator)
  ' {} + > "$ENVELOPE_FILE" 2>/dev/null || true
declare -A ENVELOPE_RECIPIENT=()
while IFS="$FIELD_SEPARATOR" read -r envelope_name envelope_recipient; do
  [[ -n "$envelope_name" ]] && ENVELOPE_RECIPIENT["$envelope_name"]="$envelope_recipient"
done < "$ENVELOPE_FILE"

cutoff_epoch=$((NOW_EPOCH - SINCE_HOURS * 3600))
cutoff_local="$(date -d "@$cutoff_epoch" '+%Y-%m-%dT%H:%M:%S')"
# FATQ timestamps are emitted in the host timezone with fixed-width ISO local
# date/time prefixes. This cheap prefix gate discards old history before the
# exact epoch conversion below, keeping a whole-repository audit schedulable.
# Malformed timestamps stay in the stream and become undetermined evidence.
find "$TASKS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.json' -exec \
  jq -r --arg cutoff_local "$cutoff_local" --arg separator "$FIELD_SEPARATOR" '
    . as $task
    | .history[]?
    | select((.action? | type) == "string" and (.action | endswith("_notified")))
    | select(
        (.ts? | type) != "string"
        or (.ts | length) < 19
        or (.ts[0:19] >= $cutoff_local)
      )
    | [
        ($task.task_id // (input_filename | split("/") | last | sub("[.]json$"; ""))),
        (.ts // ""),
        .action,
        (.relay_file // "")
      ]
    | join($separator)
  ' {} + > "$EVENT_FILE" 2>/dev/null || true

while IFS="$FIELD_SEPARATOR" read -r task_id event_ts action relay_file; do
  [[ -n "$task_id" ]] || continue
  event_epoch="$(date -d "$event_ts" +%s 2>/dev/null || true)"

  classification="undetermined"
  reason=""
  recipient=""
  expected_marker=""
  elapsed_seconds=-1
  alert=false

  if [[ -z "$event_epoch" ]]; then
    reason="timestamp-invalid"
  else
    (( event_epoch >= cutoff_epoch )) || continue
    elapsed_seconds=$((NOW_EPOCH - event_epoch))
    (( elapsed_seconds >= 0 )) || elapsed_seconds=0

    if [[ -z "$relay_file" ]]; then
      reason="relay-file-missing-from-history"
    elif [[ "$relay_file" != "$(basename -- "$relay_file")" ]]; then
      reason="relay-file-unsafe"
    else
      if [[ ! -f "$RELAY_DIR/$relay_file" && ! -f "$READ_DIR/$relay_file" ]]; then
        reason="relay-envelope-not-found"
      else
        recipient="${ENVELOPE_RECIPIENT[$relay_file]:-}"
        if [[ -z "$recipient" ]]; then
          reason="recipient-missing"
        elif ! is_true_bot_recipient "$recipient"; then
          reason="recipient-not-true-bot"
        else
          expected_marker="$(expected_marker_for_recipient "$recipient")"
          if [[ -z "$expected_marker" ]]; then
            reason="recipient-marker-unmapped"
          elif [[ -n "${MARKER_IDENTITY_SET[$relay_file$FIELD_SEPARATOR${expected_marker,,}]:-}" ]]; then
            classification="consumed"
            reason="expected-consumer-marker-present"
          else
            classification="unconsumed"
            reason="expected-consumer-marker-missing"
            (( elapsed_seconds >= THRESHOLD_SECONDS )) && alert=true
          fi
        fi
      fi
    fi
  fi

  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$classification" "$FIELD_SEPARATOR" "$task_id" "$FIELD_SEPARATOR" \
    "$action" "$FIELD_SEPARATOR" "$relay_file" "$FIELD_SEPARATOR" \
    "$event_ts" "$FIELD_SEPARATOR" "$recipient" "$FIELD_SEPARATOR" \
    "$elapsed_seconds" "$FIELD_SEPARATOR" "$reason" "$FIELD_SEPARATOR" "$alert" "$FIELD_SEPARATOR" "$expected_marker" \
    >> "$RESULT_FILE"
done < "$EVENT_FILE"

result_json="$(jq -Rn \
  --arg separator "$FIELD_SEPARATOR" \
  --argjson since_hours "$SINCE_HOURS" \
  --argjson threshold_seconds "$THRESHOLD_SECONDS" \
  --argjson now_epoch "$NOW_EPOCH" '
    [inputs
      | split($separator)
      | {
          classification: .[0], task_id: .[1], action: .[2], relay_file: .[3],
          event_ts: .[4], recipient: .[5], elapsed_seconds: (.[6] | tonumber),
          reason: .[7], alert: (.[8] == "true"), expected_marker: .[9]
        }
    ]
    |
    {
      semantics: "relay-consumer-marker-only",
      since_hours: $since_hours,
      threshold_seconds: $threshold_seconds,
      now_epoch: $now_epoch,
      counts: {
        consumed: ([.[] | select(.classification == "consumed")] | length),
        unconsumed: ([.[] | select(.classification == "unconsumed")] | length),
        undetermined: ([.[] | select(.classification == "undetermined")] | length),
        alerting: ([.[] | select(.alert == true)] | length)
      },
      consumed: [.[] | select(.classification == "consumed")],
      unconsumed: [.[] | select(.classification == "unconsumed")],
      undetermined: [.[] | select(.classification == "undetermined")]
    }
  ' "$RESULT_FILE")"

if [[ "$JSON_OUTPUT" == true ]]; then
  jq . <<<"$result_json"
else
  jq -r '
    "AUDIT semantics=relay-consumer-marker-only since_hours=\(.since_hours) threshold_seconds=\(.threshold_seconds)",
    "COUNTS consumed=\(.counts.consumed) unconsumed=\(.counts.unconsumed) undetermined=\(.counts.undetermined) alerting=\(.counts.alerting)",
    (.unconsumed[] | "UNCONSUMED task_id=\(.task_id) action=\(.action) relay_file=\(.relay_file) elapsed_seconds=\(.elapsed_seconds) alert=\(.alert) reason=\(.reason)"),
    (.undetermined[] | "UNDETERMINED task_id=\(.task_id) action=\(.action) relay_file=\(.relay_file) elapsed_seconds=\(.elapsed_seconds) reason=\(.reason)")
  ' <<<"$result_json"
fi

alert_count="$(jq -r '.counts.alerting' <<<"$result_json")"
(( alert_count == 0 )) || exit 1

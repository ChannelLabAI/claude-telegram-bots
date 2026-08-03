#!/usr/bin/env bash
# Read-only deterministic patrol: it appends its logs/state and may create owner/task-party relay alerts.
set -euo pipefail
ROOT="${PATROL_ROOT:-/home/oldrabbit/.claude-bots}"; CONFIG="${PATROL_CONFIG:-$ROOT/shared/config/patrol-scan.json}"; NOW="${PATROL_NOW_EPOCH:-$(date +%s)}"
LOG_DIR="${PATROL_LOG_DIR:-$ROOT/logs}"; LOG_FILE="$LOG_DIR/patrol-scan.jsonl"; STATE_FILE="$LOG_DIR/patrol-scan-alert-state.jsonl"; RELAY_DIR="${PATROL_RELAY_DIR:-$ROOT/relay}"; INOTIFY_LOG="${PATROL_INOTIFY_LOG:-$LOG_DIR/inotify-watch.log}"; PODS_DIR="${PATROL_PODS_DIR:-$ROOT/pod-system/pods}"; PS_FILE="${PATROL_PS_FILE:-}"
for cmd in jq stat find awk sha256sum; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
[[ -r "$CONFIG" ]] || { echo "missing patrol config: $CONFIG" >&2; exit 2; }; mkdir -p "$LOG_DIR" "$RELAY_DIR"
threshold() { jq -r --arg n "$1" '.thresholds_seconds[$n]' "$CONFIG"; }
ALERT_OWNER_RECIPIENT="${PATROL_ALERT_OWNER_RECIPIENT:-$(jq -r '.alert_owner_recipient // empty' "$CONFIG")}"
is_whitelisted() { jq -e --arg v "$1" --argjson now "$NOW" '.whitelist[]? as $entry | select($v | contains($entry.match)) | select(($entry.expires_at|fromdateiso8601) > $now)' "$CONFIG" >/dev/null; }
true_bot_recipients() {
  {
    jq -r '.true_bot_recipients_fallback[]?' "$CONFIG"
    if [[ -d "$PODS_DIR" ]]; then
      find "$PODS_DIR" -maxdepth 1 -type f -name '*.json' -exec jq -r '.bots[]? | .name, (.username // empty)' {} + 2>/dev/null
    fi
  } | awk 'NF { print tolower($0) }' | sort -u
}
TRUE_BOT_RECIPIENTS="$(true_bot_recipients)"
is_true_bot_recipient() { awk -v recipient="${1,,}" '$0 == recipient { found=1 } END { exit !found }' <<<"$TRUE_BOT_RECIPIENTS"; }
evidence=(); fails=(); task_alert_recipients=(); declare -A RECIPIENT_FAILS=()
check() { evidence+=("$(jq -cn --arg check "$1" --arg status "$2" --arg evidence "$3" '{check:$check,status:$status,evidence:$evidence}')"); [[ "$2" == fail ]] && fails+=("$1: $3") || true; }
task_event_age() {
  local file="$1" ts epoch
  ts="$(jq -r '[.history[]? | select(.action == "dispatch" or .action == "verdict" or ((.from // "") != "") or ((.to // "") != "")) | .ts // empty] | last // empty' "$file" 2>/dev/null)"
  [[ -n "$ts" ]] || return 1
  epoch="$(date -d "$ts" +%s 2>/dev/null)" || return 1
  echo $((NOW - epoch))
}
age() { echo $((NOW - $(stat -c %Y "$1"))); }
scan_tasks() {
  local state limit file id a assigned claims recipient
  for state in pending in_progress review; do
    case "$state" in pending) limit="$(threshold pending_unclaimed)";; in_progress) limit="$(threshold in_progress)";; review) limit="$(threshold review)";; esac
    [[ -d "$ROOT/tasks/$state" ]] || continue
    while IFS= read -r -d '' file; do
      id="$(jq -r '.task_id // empty' "$file" 2>/dev/null || true)"; [[ -n "$id" ]] || continue
      if is_whitelisted "$id"; then check "task_$state" pass "whitelisted $id"; continue; fi
      if ! a="$(task_event_age "$file")"; then
        check "task_$state" fail "$file meaningful_event_timestamp_missing"
        continue
      fi
      assigned="$(jq -r '.assigned // .assigned_to // "unknown"' "$file")"; claims="$(jq '[.history[]? | select(.action == "claim")] | length' "$file")"
      if { [[ "$state" == pending && "$claims" == 0 ]] || [[ "$state" != pending ]]; } && ((a > limit)); then
        local failure="task_$state: $file task_id=$id event_age=${a}s threshold=${limit}s assigned=$assigned"
        check "task_$state" fail "${failure#*: }"
        case "$state" in
          review) recipient="$(jq -r '.reviewer // empty' "$file")" ;;
          in_progress) recipient="$(jq -r '.assigned // .assigned_to // empty' "$file")" ;;
          *) recipient="" ;;
        esac
        if [[ -n "$recipient" && "$recipient" != "null" && "$recipient" != "unknown" ]]; then
          task_alert_recipients+=("$recipient")
          RECIPIENT_FAILS["$recipient"]+="$failure"$'\n'
        elif [[ "$state" == review || "$state" == in_progress ]]; then
          check "task_${state}_recipient" fail "$id recipient_missing; owner alert retained"
        fi
      else
        check "task_$state" pass "$id event_age=${a}s threshold=${limit}s"
      fi
    done < <(find "$ROOT/tasks/$state" -maxdepth 1 -type f -name '*.json' -print0)
  done
}
scan_relays() {
  local file name recipient a limit; limit="$(threshold relay_unconsumed)"
  while IFS= read -r -d '' file; do
    name="$(basename "$file")"; [[ "$name" == *.read-by-* || "$name" == patrol-scan-* ]] && continue; recipient="$(jq -r '.recipient // empty' "$file" 2>/dev/null || true)"
    is_true_bot_recipient "$recipient" || continue
    if is_whitelisted "$name"; then check relay pass "whitelisted $file"; continue; fi
    a="$(age "$file")"; if ((a > limit)); then check relay fail "$file recipient=$recipient mtime_age=${a}s threshold=${limit}s"; else check relay pass "$name age=${a}s"; fi
  done < <(find "$RELAY_DIR" -maxdepth 1 -type f -name '*.json' -print0)
}
scan_gateway() {
  # Anchor on the daemon command, rather than any argument containing
  # "gateway". The optional path accepts absolute bun and gateway.ts paths,
  # while the end anchor excludes worker prompts and test-script arguments.
  local expected tolerance count source pattern
  expected="$(jq -r '.gateway.expected_processes' "$CONFIG")"; tolerance="$(jq -r '.gateway.tolerance' "$CONFIG")"
  pattern='(^|/)bun[[:space:]]+run[[:space:]]+([^[:space:]]*/)?gateway\.ts[[:space:]]*$'
  if [[ -n "$PS_FILE" && -r "$PS_FILE" ]]; then
    count="$(grep -E -c "$pattern" "$PS_FILE" || true)"; source="$PS_FILE (exact gateway daemon pattern)"
  else
    count="$(pgrep -fc "$pattern" || true)"; source='pgrep exact gateway daemon pattern'
  fi
  if ((count < expected-tolerance || count > expected+tolerance)); then check gateway_processes fail "count=$count expected=${expected}±${tolerance} source=$source"; else check gateway_processes pass "count=$count expected=${expected}±${tolerance} source=$source"; fi
}
scan_event_pairs() {
  local missing limit missing_ts missing_epoch missing_age event_task_path event_task_name transition_path vanished_evidence=""; [[ -r "$INOTIFY_LOG" ]] || { check event_injected pass "log absent: $INOTIFY_LOG"; return; }
  limit="$(threshold event_injection)"
  missing="$(awk '/EVENT: detected .*\/tasks\/(pending|in_progress|review|rejected)\/.*\.json/ {if(e&&!i) print p; e=1;i=0;p=$0;next} e&&/INFO: injected notification/{i=1} END{if(e&&!i)print p}' "$INOTIFY_LOG" | tail -1)"
  # Grace is based on the EVENT itself, not the shared log mtime: unrelated
  # traffic must not keep an old missing injection hidden forever.
  if [[ -n "$missing" ]]; then
    event_task_path="$(sed -n 's#^.*EVENT: detected \([^[:space:]]*/tasks/\(pending\|in_progress\|review\|rejected\)/[^[:space:]]*\.json\).*$#\1#p' <<<"$missing")"
    if [[ -n "$event_task_path" ]] && [[ ! -e "$event_task_path" ]]; then
      event_task_name="$(basename "$event_task_path")"
      transition_path="$(find \
        "$ROOT/tasks/pending" "$ROOT/tasks/in_progress" "$ROOT/tasks/review" \
        "$ROOT/tasks/done" "$ROOT/tasks/rejected" "$ROOT/tasks/cancelled" \
        "$ROOT/tasks/wont_do" "$ROOT/tasks/approval_pending" "$ROOT/tasks/archived" \
        -maxdepth 1 -type f -name "$event_task_name" -print -quit 2>/dev/null || true)"
      if [[ -n "$transition_path" ]]; then
        check event_injected pass "resolved-by-transition: original task path no longer exists, found at $transition_path"
        return
      fi
      vanished_evidence="vanished task (not found in any legal FATQ state): $event_task_path; "
    fi
    if [[ -n "$event_task_path" ]] && is_whitelisted "$event_task_path"; then check event_injected pass "whitelisted $event_task_path"; return; fi
    missing_ts="$(sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p' <<<"$missing")"
    missing_epoch="$(date -d "$missing_ts" +%s 2>/dev/null || true)"
    if [[ -z "$missing_epoch" ]]; then check event_injected fail "$missing; missing or invalid EVENT timestamp"; return; fi
    missing_age=$((NOW - missing_epoch))
    if ((missing_age > limit)); then check event_injected fail "${vanished_evidence}${missing}; no injected notification within ${limit}s of its own timestamp (age=${missing_age}s)"; return; fi
  fi
  check event_injected pass "all task EVENT records paired, or final EVENT within ${limit}s grace of its own timestamp"
}
alert_signature() {
  printf '%s\n' "${fails[@]}" \
    | sed -E \
        -e 's/(^|[^[:alnum:]_])mtime_age=-?[0-9]+s/\1mtime_age=<volatile>/g' \
        -e 's/(^|[^[:alnum:]_])age=-?[0-9]+s/\1age=<volatile>/g' \
        -e 's/(^|[^[:alnum:]_])count=[0-9]+/\1count=<volatile>/g' \
    | LC_ALL=C sort -u \
    | sha256sum \
    | awk '{print $1}'
}
send_alert_once() {
  ((${#fails[@]})) || return 0; local signature stamp recipient path payload payload_fails
  signature="$(alert_signature)"
  if [[ -f "$STATE_FILE" ]] && jq -e --arg s "$signature" --argjson now "$NOW" 'select(.signature==$s and ($now-.ts)<3600)' "$STATE_FILE" >/dev/null 2>&1; then return; fi
  stamp="$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ)"
  if [[ -z "$ALERT_OWNER_RECIPIENT" || "$ALERT_OWNER_RECIPIENT" == "null" ]]; then
    check patrol_owner_recipient fail "alert_owner_recipient missing from patrol config; no owner relay written"
  else
    task_alert_recipients+=("$ALERT_OWNER_RECIPIENT")
  fi
  while IFS= read -r recipient; do
    [[ -n "$recipient" ]] || continue
    path="$RELAY_DIR/patrol-scan-$stamp-${recipient,,}.json"
    if [[ "$recipient" == "$ALERT_OWNER_RECIPIENT" ]]; then
      payload_fails="$(printf '%s\n' "${fails[@]}")"
    else
      payload_fails="${RECIPIENT_FAILS[$recipient]:-}"
      [[ -n "$payload_fails" ]] || continue
    fi
    payload="$(printf '%s\n' "$payload_fails" | sed '/^$/d' | jq -R . | jq -sc --arg ts "$(date -u -d "@$NOW" +%FT%TZ)" --arg recipient "$recipient" '{from_bot:"patrol-scan",recipient:$recipient,ts:$ts,text:("[PATROL ALERT] deterministic bypass signal(s):\n"+join("\n"))}')"
    printf '%s\n' "$payload" > "$path.tmp" && mv "$path.tmp" "$path"
  done < <(printf '%s\n' "${task_alert_recipients[@]}" | awk 'NF' | sort -u)
  jq -cn --arg signature "$signature" --argjson ts "$NOW" '{signature:$signature,ts:$ts}' >> "$STATE_FILE"
}
scan_tasks; scan_relays; scan_gateway; scan_event_pairs; send_alert_once
checks="$(IFS=,; echo "${evidence[*]}")"
if ((${#fails[@]})); then failure_json="$(printf '%s\n' "${fails[@]}" | jq -R . | jq -sc .)"; else failure_json='[]'; fi
jq -cn --argjson ts "$NOW" --argjson checks "[$checks]" --argjson failures "$failure_json" '{ts:$ts,checks:$checks,failures:$failures,status:(if ($failures|length)>0 then "fail" else "pass" end)}' | tee -a "$LOG_FILE"

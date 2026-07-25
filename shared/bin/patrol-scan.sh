#!/usr/bin/env bash
# Read-only deterministic patrol: it appends its logs/state and may create an Anya relay alert.
set -euo pipefail
ROOT="${PATROL_ROOT:-/home/oldrabbit/.claude-bots}"; CONFIG="${PATROL_CONFIG:-$ROOT/shared/config/patrol-scan.json}"; NOW="${PATROL_NOW_EPOCH:-$(date +%s)}"
LOG_DIR="${PATROL_LOG_DIR:-$ROOT/logs}"; LOG_FILE="$LOG_DIR/patrol-scan.jsonl"; STATE_FILE="$LOG_DIR/patrol-scan-alert-state.jsonl"; RELAY_DIR="${PATROL_RELAY_DIR:-$ROOT/relay}"; INOTIFY_LOG="${PATROL_INOTIFY_LOG:-$LOG_DIR/inotify-watch.log}"; PODS_DIR="${PATROL_PODS_DIR:-$ROOT/pod-system/pods}"; PS_FILE="${PATROL_PS_FILE:-}"
for cmd in jq stat find awk sha256sum; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
[[ -r "$CONFIG" ]] || { echo "missing patrol config: $CONFIG" >&2; exit 2; }; mkdir -p "$LOG_DIR" "$RELAY_DIR"
threshold() { jq -r --arg n "$1" '.thresholds_seconds[$n]' "$CONFIG"; }
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
evidence=(); fails=()
check() { evidence+=("$(jq -cn --arg check "$1" --arg status "$2" --arg evidence "$3" '{check:$check,status:$status,evidence:$evidence}')"); [[ "$2" == fail ]] && fails+=("$1: $3") || true; }
age() { echo $((NOW - $(stat -c %Y "$1"))); }
scan_tasks() {
  local state limit file id a assigned claims
  for state in pending in_progress review; do
    case "$state" in pending) limit="$(threshold pending_unclaimed)";; in_progress) limit="$(threshold in_progress)";; review) limit="$(threshold review)";; esac
    [[ -d "$ROOT/tasks/$state" ]] || continue
    while IFS= read -r -d '' file; do
      id="$(jq -r '.task_id // empty' "$file" 2>/dev/null || true)"; [[ -n "$id" ]] || continue
      if is_whitelisted "$id"; then check "task_$state" pass "whitelisted $id"; continue; fi
      a="$(age "$file")"; assigned="$(jq -r '.assigned // .assigned_to // "unknown"' "$file")"; claims="$(jq '[.history[]? | select(.action == "claim")] | length' "$file")"
      if { [[ "$state" == pending && "$claims" == 0 ]] || [[ "$state" != pending ]]; } && ((a > limit)); then check "task_$state" fail "$file mtime_age=${a}s threshold=${limit}s assigned=$assigned"; else check "task_$state" pass "$id age=${a}s threshold=${limit}s"; fi
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
  local expected tolerance count source; expected="$(jq -r '.gateway.expected_processes' "$CONFIG")"; tolerance="$(jq -r '.gateway.tolerance' "$CONFIG")"
  if [[ -n "$PS_FILE" && -r "$PS_FILE" ]]; then count="$(wc -l < "$PS_FILE" | tr -d ' ')"; source="$PS_FILE"; else count="$(pgrep -fc 'gateway(-builder)?|gateway.ts' || true)"; source=pgrep; fi
  if ((count < expected-tolerance || count > expected+tolerance)); then check gateway_processes fail "count=$count expected=${expected}±${tolerance} source=$source"; else check gateway_processes pass "count=$count expected=${expected}±${tolerance} source=$source"; fi
}
scan_event_pairs() {
  local missing limit missing_ts missing_epoch missing_age; [[ -r "$INOTIFY_LOG" ]] || { check event_injected pass "log absent: $INOTIFY_LOG"; return; }
  limit="$(threshold event_injection)"
  missing="$(awk '/EVENT: detected .*\/tasks\/(pending|in_progress|review|rejected)\/.*\.json/ {if(e&&!i) print p; e=1;i=0;p=$0;next} e&&/INFO: injected notification/{i=1} END{if(e&&!i)print p}' "$INOTIFY_LOG" | tail -1)"
  # Grace is based on the EVENT itself, not the shared log mtime: unrelated
  # traffic must not keep an old missing injection hidden forever.
  if [[ -n "$missing" ]]; then
    missing_ts="$(sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p' <<<"$missing")"
    missing_epoch="$(date -d "$missing_ts" +%s 2>/dev/null || true)"
    if [[ -z "$missing_epoch" ]]; then check event_injected fail "$missing; missing or invalid EVENT timestamp"; return; fi
    missing_age=$((NOW - missing_epoch))
    if ((missing_age > limit)); then check event_injected fail "$missing; no injected notification within ${limit}s of its own timestamp (age=${missing_age}s)"; return; fi
  fi
  check event_injected pass "all task EVENT records paired, or final EVENT within ${limit}s grace of its own timestamp"
}
send_alert_once() {
  ((${#fails[@]})) || return 0; local signature stamp path payload; signature="$(printf '%s\n' "${fails[@]}" | sha256sum | awk '{print $1}')"
  if [[ -f "$STATE_FILE" ]] && jq -e --arg s "$signature" --argjson now "$NOW" 'select(.signature==$s and ($now-.ts)<3600)' "$STATE_FILE" >/dev/null 2>&1; then return; fi
  stamp="$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ)"; path="$RELAY_DIR/patrol-scan-$stamp-anya.json"
  payload="$(printf '%s\n' "${fails[@]}" | jq -R . | jq -sc --arg ts "$(date -u -d "@$NOW" +%FT%TZ)" '{from_bot:"patrol-scan",recipient:"anya",ts:$ts,text:("[PATROL ALERT] deterministic bypass signal(s):\n"+join("\n"))}')"
  printf '%s\n' "$payload" > "$path.tmp" && mv "$path.tmp" "$path"; jq -cn --arg signature "$signature" --argjson ts "$NOW" '{signature:$signature,ts:$ts}' >> "$STATE_FILE"
}
scan_tasks; scan_relays; scan_gateway; scan_event_pairs; send_alert_once
checks="$(IFS=,; echo "${evidence[*]}")"
if ((${#fails[@]})); then failure_json="$(printf '%s\n' "${fails[@]}" | jq -R . | jq -sc .)"; else failure_json='[]'; fi
jq -cn --argjson ts "$NOW" --argjson checks "[$checks]" --argjson failures "$failure_json" '{ts:$ts,checks:$checks,failures:$failures,status:(if ($failures|length)>0 then "fail" else "pass" end)}' | tee -a "$LOG_FILE"

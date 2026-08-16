#!/usr/bin/env bash
# Isolated safety regressions for patrol output paths, alert origin, and JSONL writes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATROL_SH="${PATROL_SCAN_SH:-$SCRIPT_DIR/../bin/patrol-scan.sh}"
DEFAULT_ROOT="/home/oldrabbit/.claude-bots"
PASS=0
FAIL=0
TMP_PATHS=()

ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
cleanup() {
  local path
  for path in "${TMP_PATHS[@]}"; do
    rm -rf -- "$path"
  done
}
trap cleanup EXIT

make_root() {
  local output_var="$1" generated_root
  generated_root="$(mktemp -d)"
  TMP_PATHS+=("$generated_root")
  mkdir -p "$generated_root"/{tasks/{pending,in_progress,review},relay,logs,shared/config,pod-system/pods}
  printf '%s\n' '{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":10,"in_progress":10,"review":10,"relay_unconsumed":10,"event_injection":10},"gateway":{"expected_processes":0,"tolerance":0},"whitelist":[],"true_bot_recipients_fallback":["anya","bella","eric"]}' > "$generated_root/shared/config/patrol-scan.json"
  : > "$generated_root/ps.txt"
  printf -v "$output_var" '%s' "$generated_root"
}

run_fixture() {
  local root="$1" now="$2" output="$3"
  PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
    PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$root/relay" \
    PATROL_INOTIFY_LOG="$root/missing-inotify.log" PATROL_PODS_DIR="$root/pod-system/pods" \
    PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH="$now" bash "$PATROL_SH" > "$output"
}

printf 'patrol scan safety fixtures\n'

make_root root
outside="$(mktemp -d)"
TMP_PATHS+=("$outside")
set +e
PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$outside/relay" \
  PATROL_INOTIFY_LOG="$root/missing.log" PATROL_PODS_DIR="$root/pod-system/pods" \
  PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH=1785000000 \
  bash "$PATROL_SH" > "$root/guard-output" 2> "$root/guard-error"
guard_rc=$?
set -e
if [[ "$guard_rc" -ne 0 ]] && grep -q 'PATROL_RELAY_DIR resolves outside PATROL_ROOT' "$root/guard-error" && [[ ! -e "$outside/relay" ]]; then
  ok "fixture relay path outside ROOT fails closed before writing"
else
  bad "fixture relay path escaped ROOT or did not fail clearly"
fi

set +e
PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$outside/logs" PATROL_RELAY_DIR="$root/relay" \
  PATROL_INOTIFY_LOG="$root/missing.log" PATROL_PODS_DIR="$root/pod-system/pods" \
  PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH=1785000000 \
  bash "$PATROL_SH" > "$root/log-guard-output" 2> "$root/log-guard-error"
log_guard_rc=$?
set -e
if [[ "$log_guard_rc" -ne 0 ]] && grep -q 'PATROL_LOG_DIR resolves outside PATROL_ROOT' "$root/log-guard-error" && [[ ! -e "$outside/logs" ]]; then
  ok "fixture log and derived state paths outside ROOT fail closed before writing"
else
  bad "fixture log path escaped ROOT or did not fail clearly"
fi

make_root root
printf '%s\n' '{"task_id":"origin-fixture-overdue","assigned":"eric","history":[]}' > "$root/tasks/pending/overdue.json"
run_fixture "$root" 1785000000 "$root/output.json"
alert="$(find "$root/relay" -maxdepth 1 -type f -name '*-anya.json' -print -quit)"
if [[ -n "$alert" ]] && jq -e --arg root "$(realpath -m "$root")" '
  .origin_root == $root
  and (.origin_pid | type == "number" and . > 0)
  and (.origin_host | type == "string" and length > 0)
  and (.origin_actor | type == "string" and length > 0)
  and (.text | startswith("[PATROL ALERT] deterministic bypass signal(s):\n") and contains("origin_root=" + $root + " pid=") and contains(" host=") and contains(" actor="))
' "$alert" >/dev/null; then
  ok "fixture alert envelope and text identify absolute ROOT, pid, host, and actor"
else
  bad "fixture alert lacks complete origin stamping"
fi

make_root root
jq '.gateway.expected_processes = 1 | .whitelist = [{"match":"","expires_at":"2099-01-01T00:00:00Z","reason":"isolate production-shaped path reads"}]' \
  "$root/shared/config/patrol-scan.json" > "$root/shared/config/patrol-scan.next"
mv "$root/shared/config/patrol-scan.next" "$root/shared/config/patrol-scan.json"
PATROL_ROOT="$DEFAULT_ROOT" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$root/relay" \
  PATROL_INOTIFY_LOG="$root/missing-inotify.log" PATROL_PODS_DIR="$root/pod-system/pods" \
  PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH=1785000000 bash "$PATROL_SH" > "$root/production-shaped.json"
prod_alert="$(find "$root/relay" -maxdepth 1 -type f -name '*-anya.json' -print -quit)"
if [[ -n "$prod_alert" ]] && jq -e --arg root "$DEFAULT_ROOT" '
  .origin_root == $root
  and (.origin_pid | type == "number")
  and (.origin_host | length > 0)
  and (.origin_actor | length > 0)
  and (.text | startswith("[PATROL ALERT] deterministic bypass signal(s):\norigin_root=" + $root + " pid="))
' "$prod_alert" >/dev/null; then
  ok "production-shaped alert keeps the legacy envelope parseable and adds origin fields"
else
  bad "production-shaped alert origin fields or legacy envelope are invalid"
fi

make_root root
expires="$(date -u -d @1785003600 +%FT%TZ)"
jq --arg expires "$expires" '.whitelist += [{"match":"WHITELISTED","expires_at":$expires,"reason":"fixture"}]' \
  "$root/shared/config/patrol-scan.json" > "$root/shared/config/patrol-scan.next"
mv "$root/shared/config/patrol-scan.next" "$root/shared/config/patrol-scan.json"
printf '%s\n' '{"task_id":"WHITELISTED","assigned":"eric","history":[]}' > "$root/tasks/pending/whitelisted.json"
run_fixture "$root" 1785000000 "$root/whitelist.json"
if jq -e 'any(.checks[]; .check == "task_pending" and .status == "pass" and .evidence == "whitelisted WHITELISTED")' "$root/whitelist.json" >/dev/null; then
  ok "existing whitelist suppression remains effective"
else
  bad "whitelist suppression regressed"
fi

make_root root
held_until="2099-01-01T00:00:00+00:00"
jq -n --arg hold "$held_until" '{task_id:"HELD",status:"review",assigned:"anna",reviewer:"bella",not_before:$hold,history:[{ts:"2026-01-01T00:00:00+00:00",action:"submit",from:"in_progress/",to:"review/"}]}' > "$root/tasks/review/held.json"
run_fixture "$root" 1785000000 "$root/held.json.out"
if jq -e --arg hold "$held_until" 'any(.checks[]; .check == "task_review" and .status == "pass" and .evidence == ("HELD held_until=" + $hold))' "$root/held.json.out" >/dev/null; then
  ok "existing held_until suppression remains effective"
else
  bad "held_until suppression regressed"
fi

make_root root
for i in $(seq 1 24); do
  run_fixture "$root" "$((1785000000 + i))" "$root/concurrent-$i.json" &
done
wait
line_count="$(wc -l < "$root/logs/patrol-scan.jsonl" | tr -d ' ')"
if [[ "$line_count" == 24 ]] && jq -e . "$root/logs/patrol-scan.jsonl" >/dev/null && grep -q '}$' "$root/logs/patrol-scan.jsonl"; then
  ok "24 concurrent patrol writers append 24 complete parseable JSONL records"
else
  bad "concurrent patrol writers produced missing or malformed JSONL records"
fi

make_root root
expires="$(date -u -d @1785003600 +%FT%TZ)"
jq --arg expires "$expires" '.whitelist = [{"match":"LONG","expires_at":$expires,"reason":"large-output fixture"}]' \
  "$root/shared/config/patrol-scan.json" > "$root/shared/config/patrol-scan.next"
mv "$root/shared/config/patrol-scan.next" "$root/shared/config/patrol-scan.json"
for i in $(seq 1 30); do
  printf '{"task_id":"LONG-%02d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","assigned":"eric","history":[]}\n' "$i" > "$root/tasks/pending/$i.json"
done
set +e
PATROL_ROOT="$root" PATROL_CONFIG="$root/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$root/logs" PATROL_RELAY_DIR="$root/relay" \
  PATROL_INOTIFY_LOG="$root/missing-inotify.log" PATROL_PODS_DIR="$root/pod-system/pods" \
  PATROL_PS_FILE="$root/ps.txt" PATROL_NOW_EPOCH=1785000000 bash "$PATROL_SH" | head -c 1000 > "$root/first-1000-bytes"
producer_rc="${PIPESTATUS[0]}"
set -e
log_bytes="$(wc -c < "$root/logs/patrol-scan.jsonl" | tr -d ' ')"
if [[ "$log_bytes" -gt 1000 ]] && jq -e . "$root/logs/patrol-scan.jsonl" >/dev/null && [[ "$producer_rc" == 0 || "$producer_rc" == 141 ]]; then
  ok "closing stdout at 1000 bytes cannot truncate the durable JSONL record"
else
  bad "stdout cutoff still truncates or corrupts the durable JSONL record"
fi

printf 'RESULT: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

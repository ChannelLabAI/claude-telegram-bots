#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/shared/bin/tech-radar.py"
CONFIG="$ROOT/shared/config/tech-radar.json"
FIXTURE="$ROOT/shared/tests/fixtures/tech-radar"
RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT

pass=0
fail=0
check() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name expected=$expected actual=$actual"
    fail=$((fail + 1))
  fi
}

run_radar() {
  local state="$1" output="$2" notify_log="$3"
  TECH_RADAR_STUB_LOG="$notify_log" "$SCRIPT" \
    --config "$CONFIG" \
    --state "$state" \
    --feed-dir "$FIXTURE" \
    --notify-bin "$FIXTURE/notify-stub.sh" > "$output" 2>&1
}

state="$RUN_DIR/watermark.json"
first="$RUN_DIR/first.out"
second="$RUN_DIR/second.out"
notify_log="$RUN_DIR/notify.log"
run_radar "$state" "$first" "$notify_log"
run_radar "$state" "$second" "$notify_log"

check "first run processes 12 real articles" "$(grep -c '^\[tech-radar\] \(MATCH\|SKIP\)' "$first")" "12"
check "relevance has matches" "$(grep -c '^\[tech-radar\] MATCH' "$first")" "10"
check "relevance has non-matches" "$(grep -c '^\[tech-radar\] SKIP' "$first")" "2"
check "first run calls notifier for every match" "$(wc -l < "$notify_log" | tr -d ' ')" "10"
check "second run has no duplicates" "$(grep -c 'new=0 matched=0 skipped=0 notified=0' "$second")" "1"
check "stub receives agent-comms channel id" "$(jq -r '.channel_id' "$notify_log" | sort -u)" "j9t9pohqeff6bg4uz4ndwyqkph"
check "notification contains title" "$(grep -c '標題：' "$notify_log")" "10"
check "notification contains link" "$(grep -c '連結：https://blog.cloudflare.com/' "$notify_log")" "10"
check "notification contains impact" "$(grep -c '影響：' "$notify_log")" "10"
check "watermark schema is guid plus timestamp only" "$(jq -r '.["cloudflare-blog"] | keys | sort | join(",")' "$state")" "guid,published_at"
check "watermark contains no article text" "$(grep -Eic 'title|description|content|summary|body' "$state" || true)" "0"

gap_state="$RUN_DIR/gap-watermark.json"
jq -n '{"cloudflare-blog": {guid:"cf-old-not-in-window", published_at:"2026-01-01T00:00:00Z"}}' > "$gap_state"
gap_out="$RUN_DIR/gap.out"
gap_notify="$RUN_DIR/gap-notify.log"
run_radar "$gap_state" "$gap_out" "$gap_notify"
check "old missing watermark emits visible gap" "$(grep -c '^\[tech-radar\] GAP' "$gap_out")" "1"
check "gap reaches real configured consumer" "$(grep -c '@Anyachl_bot 漏抓風險' "$gap_notify")" "1"
check "gap run still classifies visible items" "$(grep -c '^\[tech-radar\] \(MATCH\|SKIP\)' "$gap_out")" "12"
check "gap notification uses existing channel" "$(jq -r 'select(.message | contains("漏抓風險")) | .channel_id' "$gap_notify")" "j9t9pohqeff6bg4uz4ndwyqkph"

echo "--- FIRST RUN ---"
cat "$first"
echo "--- SECOND RUN ---"
cat "$second"
echo "--- GAP RUN ---"
cat "$gap_out"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]]

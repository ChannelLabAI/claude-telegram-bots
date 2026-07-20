#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SH="$SCRIPT_DIR/../bin/fatq-closeout-sweep.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_CLOSEOUT_SWEEP_STATE="$TMPROOT/state.json"
export FATQ_NOW_ISO="2026-07-20T12:00:00+08:00"
mkdir -p "$FATQ_ROOT/done" "$FATQ_RELAY_DIR"

make_done() {
  local tid="$1" done_ts="$2" closeout_json="$3"
  jq -n --arg tid "$tid" --arg ts "$done_ts" --argjson closeout "$closeout_json" '
    {task_id:$tid, status:"done", closeout:$closeout,
     history:[{ts:$ts,by:"bella",via:"fatq-cli",action:"verdict_approve",from:"review/",to:"done/"}]}
  ' > "$FATQ_ROOT/done/$tid.json"
}

make_done overdue "2026-07-18T10:00:00+08:00" '{"state":"pending"}'
make_done closed "2026-07-18T10:00:00+08:00" '{"state":"closed"}'
make_done fresh "2026-07-20T00:30:00+08:00" '{"state":"pending"}'
jq -n '{task_id:"legacy",status:"done",history:[{ts:"2026-01-01T00:00:00+08:00",action:"verdict_approve",to:"done/"}]}' \
  > "$FATQ_ROOT/done/legacy.json"

bash "$SWEEP_SH" > "$TMPROOT/run1.log"
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l)" -eq 1 ]]
relay_file="$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' -print -quit)"
jq -e '
  .from_bot == "fatq-closeout-sweep"
  and .recipient == "anya"
  and .kind == "fatq_closeout_overdue"
  and .fatq_task_ids == ["overdue"]
  and (.text | contains("overdue"))
  and (.text | contains("@Anyachl_bot"))
' "$relay_file" >/dev/null
jq -e '.alerted.overdue.relay_file | type == "string" and length > 0' "$FATQ_CLOSEOUT_SWEEP_STATE" >/dev/null

# 同一張未 closed 任務重掃不得重複 relay（固定時鐘避免 fresh fixture 也跨 24h）。
bash "$SWEEP_SH" > "$TMPROOT/run2.log"
[[ "$(find "$FATQ_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l)" -eq 1 ]]
grep -q 'no new overdue' "$TMPROOT/run2.log"

echo "[fatq-closeout-sweep-test] PASS: overdue relay + legacy exclusion + duplicate suppression"

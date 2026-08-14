#!/usr/bin/env bash
# fatq-closeout-sweep.sh — 每日掃描 done/ 中超過 24h 尚未閉環的新制任務。
#
# 歷史 done 任務沒有 closeout schema，依 spec v1.1 明確略過、不回填。
# 同一 task_id 成功產生一次 relay 後寫入 state，後續每日掃描不重複告警。

set -euo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
FATQ_CLOSEOUT_SWEEP_STATE="${FATQ_CLOSEOUT_SWEEP_STATE:-/home/oldrabbit/.claude-bots/shared/.fatq-closeout-sweep-state.json}"
FATQ_NOW_ISO="${FATQ_NOW_ISO:-}"
FATQ_CLOSEOUT_MAX_AGE_SECS="${FATQ_CLOSEOUT_MAX_AGE_SECS:-86400}"
FATQ_BLOCKING_LIB="${FATQ_BLOCKING_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fatq-blocking.sh}"

[[ -r "$FATQ_BLOCKING_LIB" ]] || { echo "[fatq-closeout-sweep] missing FATQ blocking helper: $FATQ_BLOCKING_LIB" >&2; exit 2; }
# shellcheck source=../lib/fatq-blocking.sh
source "$FATQ_BLOCKING_LIB"

now_iso() {
  if [[ -n "$FATQ_NOW_ISO" ]]; then
    printf '%s\n' "$FATQ_NOW_ISO"
  else
    TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"
  fi
}

now_epoch() {
  date -d "$(now_iso)" +%s
}

mkdir -p "$(dirname "$FATQ_CLOSEOUT_SWEEP_STATE")" "$FATQ_RELAY_DIR"
lock_file="${FATQ_CLOSEOUT_SWEEP_STATE}.lock"
exec 9>"$lock_file"
flock -n 9 || {
  echo "[fatq-closeout-sweep] another sweep is running; skip"
  exit 0
}

if [[ ! -f "$FATQ_CLOSEOUT_SWEEP_STATE" ]] || ! jq -e '.alerted | type == "object"' "$FATQ_CLOSEOUT_SWEEP_STATE" >/dev/null 2>&1; then
  state_tmp="$(mktemp "$(dirname "$FATQ_CLOSEOUT_SWEEP_STATE")/.fatq-closeout-state.XXXXXX")"
  jq -n '{alerted:{}}' > "$state_tmp"
  mv -f "$state_tmp" "$FATQ_CLOSEOUT_SWEEP_STATE"
fi

overdue_tmp="$(mktemp)"
trap 'rm -f "$overdue_tmp"' EXIT
now_ep="$(now_epoch)"

while IFS= read -r -d '' task_file; do
  jq empty "$task_file" >/dev/null 2>&1 || continue
  # closeout schema 不存在＝歷史單；依「不回填歷史 done」規則略過。
  jq -e '(.closeout | type == "object") and ((.closeout.state // "pending") != "closed")' \
    "$task_file" >/dev/null 2>&1 || continue

  task_id="$(jq -r '.task_id // empty' "$task_file")"
  [[ -n "$task_id" ]] || continue
  # An explicit future hold means deployment/live verification was deliberately
  # deferred. Do not record it as alerted: once not_before expires, the same
  # overdue task must flow through the ordinary closeout reminder path.
  fatq_task_is_blocked "$task_file" "$now_ep" && continue
  jq -e --arg tid "$task_id" '.alerted | has($tid)' "$FATQ_CLOSEOUT_SWEEP_STATE" >/dev/null 2>&1 && continue

  done_ts="$(jq -r '
    [(.history // [])[]
      | select((.to // "") == "done/" or (.action // "") == "verdict_approve")
      | .ts // empty][-1] // empty
  ' "$task_file")"
  [[ -n "$done_ts" ]] || continue
  done_ep="$(date -d "$done_ts" +%s 2>/dev/null || true)"
  [[ -n "$done_ep" ]] || continue
  age_secs=$((now_ep - done_ep))
  [[ "$age_secs" -gt "$FATQ_CLOSEOUT_MAX_AGE_SECS" ]] || continue

  jq -cn --arg task_id "$task_id" --arg done_ts "$done_ts" \
    --arg state "$(jq -r '.closeout.state // "pending"' "$task_file")" \
    --arg path "$task_file" --argjson age_secs "$age_secs" \
    '{task_id:$task_id, done_ts:$done_ts, closeout_state:$state, age_secs:$age_secs, task_file:$path}' \
    >> "$overdue_tmp"
done < <(find "$FATQ_ROOT/done" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

count="$(wc -l < "$overdue_tmp" | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  echo "[fatq-closeout-sweep] OK: no new overdue closeout tasks"
  exit 0
fi

items_json="$(jq -s '.' "$overdue_tmp")"
ids_json="$(jq '[.[].task_id]' <<< "$items_json")"
summary="$(jq -r '.[] | "- \(.task_id)：done_at=\(.done_ts)，closeout.state=\(.closeout_state)，age=\((.age_secs / 3600 | floor))h"' <<< "$items_json")"
ts="$(now_iso)"
text="[FATQ 閉環逾時告警] ${count} 張 done 任務超過 24h 尚未 closed：
${summary}
@Anyachl_bot 請追部署／live check 證據；同一任務後續每日掃描將抑制重複告警。"
relay_name="fatq-closeout-sweep-$(date -d "$ts" +%Y%m%d%H%M%S)-$$.json"
relay_tmp="$(mktemp "$FATQ_RELAY_DIR/.fatq-closeout-sweep.XXXXXX")"
jq -n --arg from_bot "fatq-closeout-sweep" --arg recipient "anya" --arg text "$text" \
  --arg ts "$ts" --argjson task_ids "$ids_json" --argjson tasks "$items_json" \
  '{from_bot:$from_bot, recipient:$recipient, text:$text, ts:$ts,
    kind:"fatq_closeout_overdue", fatq_task_ids:$task_ids, tasks:$tasks}' > "$relay_tmp"
mv -f "$relay_tmp" "$FATQ_RELAY_DIR/$relay_name"

state_tmp="$(mktemp "$(dirname "$FATQ_CLOSEOUT_SWEEP_STATE")/.fatq-closeout-state.XXXXXX")"
jq --arg ts "$ts" --arg relay_file "$relay_name" --argjson ids "$ids_json" '
  reduce $ids[] as $id (.;
    .alerted[$id] = {alerted_at:$ts, relay_file:$relay_file})
' "$FATQ_CLOSEOUT_SWEEP_STATE" > "$state_tmp"
mv -f "$state_tmp" "$FATQ_CLOSEOUT_SWEEP_STATE"

echo "[fatq-closeout-sweep] ALERT: wrote $FATQ_RELAY_DIR/$relay_name ($count tasks)"

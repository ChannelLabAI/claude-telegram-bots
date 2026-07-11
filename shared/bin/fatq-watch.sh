#!/usr/bin/env bash
# fatq-watch.sh — FATQ 派工事件化：inotify 監聽 tasks/ 觸發 fatq-dispatch.sh
#
# Spec: tasks/{in_progress,done}/20260705-1425-a9f3-fatq-event-driven-dispatch.json
#
# 監聽 tasks/{pending,review,design_review,spec_review,design,rejected}/ 的
# create/moved_to（僅 .json）→ debounce → 呼叫既有 fatq-dispatch.sh。
# fatq-dispatch.sh 本身 idempotent（claim + noclobber + flock），事件觸發
# 疊加安全；本腳本不新增鎖、不改 fatq-dispatch.sh 的決策邏輯。
#
# Usage: fatq-watch.sh
# 通常透過 systemd user unit (fatq-watch.service) 常駐執行。

set -uo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_WATCH_DEBOUNCE_SECS="${FATQ_WATCH_DEBOUNCE_SECS:-7}"
FATQ_DISPATCH_SH="${FATQ_DISPATCH_SH:-/home/oldrabbit/.claude-bots/shared/bin/fatq-dispatch.sh}"
FATQ_WATCH_LOG="${FATQ_WATCH_LOG:-/home/oldrabbit/.claude-bots/logs/fatq-watch.log}"
FATQ_WATCH_SKIP_INITIAL_DISPATCH="${FATQ_WATCH_SKIP_INITIAL_DISPATCH:-0}"  # 1＝測試用，跳過開機保底那次
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
INOTIFYWAIT="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
FATQ_DISPATCH_LOCK="${FATQ_DISPATCH_LOCK:-/tmp/cron-fatq-dispatch.lock}"  # 測試須覆寫成專屬臨時路徑，避免撞真實生產 cron 的同一把鎖
FATQ_DISPATCH_LOCK_WAIT_SECS="${FATQ_DISPATCH_LOCK_WAIT_SECS:-120}"

SPEC_HASH_FIELDS=(goal context acceptance_criteria deliverables out_of_scope)
WATCH_SUBDIRS=(pending in_progress review design_review spec_review design rejected approval_pending)  # in_progress：claim 後 spec staleness notify；approval_pending：Part 2 §2.2/E2，審批請求即時觸發通知

log() {
  echo "[$(TZ='Asia/Taipei' date '+%Y-%m-%dT%H:%M:%S+08:00')] $*" >> "$FATQ_WATCH_LOG"
}

trigger_dispatch() {
  scan_spec_staleness

  log "INFO: debounce 窗口(${FATQ_WATCH_DEBOUNCE_SECS}s)已過，呼叫 fatq-dispatch.sh"
  # fatq-dispatch.sh 自己的 flock（$FATQ_DISPATCH_LOCK，預設 /tmp/cron-fatq-dispatch.lock）
  # 已防重疊，這裡不另加鎖；事件觸發跟 cron 巡迴共用同一把鎖，天然互斥。
  (
    log "INFO: fatq-dispatch.sh 等待 dispatch 鎖（timeout=${FATQ_DISPATCH_LOCK_WAIT_SECS}s）"
    if /usr/bin/flock -w "$FATQ_DISPATCH_LOCK_WAIT_SECS" "$FATQ_DISPATCH_LOCK" bash "$FATQ_DISPATCH_SH" >> "${FATQ_WATCH_LOG%.log}-dispatch.log" 2>&1; then
      log "INFO: fatq-dispatch.sh 執行完成"
    else
      log "WARN: fatq-dispatch.sh 未執行成功或等待 dispatch 鎖逾時（timeout=${FATQ_DISPATCH_LOCK_WAIT_SECS}s）"
    fi
  ) &
}

now_iso() {
  TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"
}

spec_payload_json() {
  local task_file="$1"
  jq -S -c '{
    goal: (.goal // null),
    context: (.context // null),
    acceptance_criteria: (.acceptance_criteria // null),
    deliverables: (.deliverables // null),
    out_of_scope: (.out_of_scope // null)
  }' "$task_file"
}

spec_payload_hash() {
  spec_payload_json "$1" | sha256sum | awk '{print $1}'
}

spec_field_hashes_json() {
  local task_file="$1"
  local goal context acceptance_criteria deliverables out_of_scope value
  value="$(jq -S -c '.goal // null' "$task_file")"; goal="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  value="$(jq -S -c '.context // null' "$task_file")"; context="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  value="$(jq -S -c '.acceptance_criteria // null' "$task_file")"; acceptance_criteria="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  value="$(jq -S -c '.deliverables // null' "$task_file")"; deliverables="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  value="$(jq -S -c '.out_of_scope // null' "$task_file")"; out_of_scope="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  jq -n -S -c \
    --arg goal "$goal" --arg context "$context" \
    --arg acceptance_criteria "$acceptance_criteria" --arg deliverables "$deliverables" \
    --arg out_of_scope "$out_of_scope" \
    '{goal:$goal, context:$context, acceptance_criteria:$acceptance_criteria, deliverables:$deliverables, out_of_scope:$out_of_scope}'
}

scan_spec_staleness() {
  local task_file
  shopt -s nullglob
  for task_file in "$FATQ_ROOT"/in_progress/*.json; do
    scan_spec_staleness_file "$task_file" || log "WARN: spec staleness scan failed for ${task_file}"
  done
  shopt -u nullglob
}

scan_spec_staleness_file() {
  local task_file="$1"
  [[ -f "$task_file" ]] || return 0

  local lock_fd
  exec {lock_fd}<"$task_file" 2>/dev/null || return 0
  flock -x "$lock_fd"

  if [[ ! -f "$task_file" ]]; then
    flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
    return 0
  fi

  local baseline_hash baseline_field_hashes current_hash current_field_hashes notified_count
  baseline_hash="$(jq -r '[.history[]? | select((.action=="claim" or .action=="spec_hash") and (.spec_hash // "") != "")][-1].spec_hash // ""' "$task_file" 2>/dev/null)"
  if [[ -z "$baseline_hash" ]]; then
    flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
    return 0
  fi

  current_hash="$(spec_payload_hash "$task_file")"
  if [[ "$current_hash" == "$baseline_hash" ]]; then
    flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
    return 0
  fi

  notified_count="$(jq --arg hash "$current_hash" '[.history[]? | select(.action=="spec_staleness_notified" and .current_spec_hash==$hash)] | length' "$task_file" 2>/dev/null)"
  if [[ "${notified_count:-0}" -gt 0 ]]; then
    flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
    return 0
  fi

  baseline_field_hashes="$(jq -S -c '[.history[]? | select((.action=="claim" or .action=="spec_hash") and (.spec_hash // "") != "")][-1].field_hashes // {}' "$task_file")"
  current_field_hashes="$(spec_field_hashes_json "$task_file")"

  local changed_fields task_id assignee relay_file relay_text relay_content tmp entry
  changed_fields="$(jq -r --argjson before "$baseline_field_hashes" --argjson after "$current_field_hashes" \
    '$after | to_entries | map(select($before[.key] != .value) | .key) | join(", ")' <<< '{}')"
  task_id="$(jq -r '.task_id // empty' "$task_file")"
  assignee="$(jq -r '.assigned // empty' "$task_file")"
  [[ -z "$task_id" ]] && task_id="$(basename "$task_file" .json)"
  [[ -z "$assignee" ]] && assignee="anya"

  relay_text="[FATQ spec 變更通知] 任務 ${task_id} 在 claim 後 spec 欄位已變更。\n變更欄位：${changed_fields:-<unknown>}\n任務檔：${task_file}\n請在 submit 前重新讀取最新 goal/context/acceptance_criteria/deliverables/out_of_scope。"
  relay_content="$(jq -n --arg from "fatq-watch" --arg recipient "$assignee" --arg text "$relay_text" \
    --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}')"
  mkdir -p "$FATQ_RELAY_DIR"
  relay_file="fatq-${task_id}-spec-staleness-$(date +%s%N 2>/dev/null || echo $$).json"
  printf '%s\n' "$relay_content" > "${FATQ_RELAY_DIR}/${relay_file}"

  entry="$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --arg assignee "$assignee" \
    --arg previous "$baseline_hash" --arg current "$current_hash" --arg changed "$changed_fields" \
    '{ts:$ts, by:"fatq-watch", action:"spec_staleness_notified",
      relay_file:$relay, recipient:$assignee, previous_spec_hash:$previous,
      current_spec_hash:$current, changed_fields:($changed | split(", ") | map(select(. != "")))}')"
  tmp="$(mktemp "$(dirname "$task_file")/.fatq-watch.XXXXXX")"
  if jq --argjson entry "$entry" '.history = ((.history // []) + [$entry])' "$task_file" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$task_file"
    log "INFO: spec staleness notified for ${task_id}: ${changed_fields:-<unknown>}"
  else
    rm -f "$tmp"
    flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
    return 1
  fi

  flock -u "$lock_fd"; exec {lock_fd}<&- 2>/dev/null || true
  return 0
}

main() {
  mkdir -p "$(dirname "$FATQ_WATCH_LOG")"

  if [[ ! -x "$INOTIFYWAIT" ]]; then
    log "ERROR: inotifywait 不存在於 ${INOTIFYWAIT}（需要 inotify-tools 套件）"
    echo "ERROR: inotifywait not found at ${INOTIFYWAIT}" >&2
    exit 1
  fi

  local existing_dirs=()
  local d
  for d in "${WATCH_SUBDIRS[@]}"; do
    if [[ -d "$FATQ_ROOT/$d" ]]; then
      existing_dirs+=("$FATQ_ROOT/$d")
    fi
  done

  if [[ ${#existing_dirs[@]} -eq 0 ]]; then
    log "ERROR: 沒有任何可監聽的目錄存在於 ${FATQ_ROOT}"
    exit 1
  fi

  log "INFO: fatq-watch 啟動，監聽：${existing_dirs[*]}（debounce=${FATQ_WATCH_DEBOUNCE_SECS}s）"

  if [[ "$FATQ_WATCH_SKIP_INITIAL_DISPATCH" != "1" ]]; then
    # 開機保底：daemon 重啟期間可能錯過事件，先跑一次補上
    trigger_dispatch
  else
    # 測試仍允許單獨驗證 spec staleness 的重啟補掃，不觸發 dispatch。
    scan_spec_staleness
  fi

  if [[ "${FATQ_WATCH_RUN_ONCE:-0}" == "1" ]]; then
    log "INFO: FATQ_WATCH_RUN_ONCE=1，完成 spec staleness 掃描後退出"
    exit 0
  fi

  "$INOTIFYWAIT" -m -e create -e moved_to --format '%w%f' "${existing_dirs[@]}" 2>>"$FATQ_WATCH_LOG" | \
  while true; do
    if ! IFS= read -r full_path; then
      log "INFO: inotifywait 輸出結束（進程可能被終止），退出"
      break
    fi
    case "$full_path" in
      *.json) ;;
      *) continue ;;
    esac
    log "EVENT: detected ${full_path}"

    # debounce：窗口內持續讀到新事件就重置計時，安靜下來才觸發一次
    while IFS= read -r -t "$FATQ_WATCH_DEBOUNCE_SECS" next_path; do
      case "$next_path" in
        *.json) log "EVENT: detected ${next_path}（debounce 中，合併）" ;;
      esac
    done

    trigger_dispatch
  done
}

main "$@"

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
INOTIFYWAIT="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
FATQ_DISPATCH_LOCK="${FATQ_DISPATCH_LOCK:-/tmp/cron-fatq-dispatch.lock}"  # 測試須覆寫成專屬臨時路徑，避免撞真實生產 cron 的同一把鎖

WATCH_SUBDIRS=(pending review design_review spec_review design rejected approval_pending)  # approval_pending：Part 2 §2.2/E2，審批請求即時觸發通知

log() {
  echo "[$(TZ='Asia/Taipei' date '+%Y-%m-%dT%H:%M:%S+08:00')] $*" >> "$FATQ_WATCH_LOG"
}

trigger_dispatch() {
  log "INFO: debounce 窗口(${FATQ_WATCH_DEBOUNCE_SECS}s)已過，呼叫 fatq-dispatch.sh"
  # fatq-dispatch.sh 自己的 flock（$FATQ_DISPATCH_LOCK，預設 /tmp/cron-fatq-dispatch.lock）
  # 已防重疊，這裡不另加鎖；事件觸發跟 cron 巡迴共用同一把鎖，天然互斥。
  if ! /usr/bin/flock -n "$FATQ_DISPATCH_LOCK" bash "$FATQ_DISPATCH_SH" >> "${FATQ_WATCH_LOG%.log}-dispatch.log" 2>&1; then
    log "WARN: fatq-dispatch.sh 未執行成功或搶不到鎖（cron 也在跑，下一輪事件/巡迴會補上）"
  fi
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

#!/usr/bin/env bash
# fatq-dispatch.sh — FATQ 調度 cron（pull → push 化）
#
# Spec: handover/fatq-dispatch-cron-spec-20260705.md (v1.1)
#
# 週期掃描 tasks/ 全狀態目錄，對待派/待催任務生成 relay 檔喚醒 pod worker。
# 紅線：對 task 檔的唯一寫入權＝ append history 一行；永不 mv 任何 task 檔跨目錄；
# verify gate 判定不歸此腳本，只在文案提醒。
#
# Usage: fatq-dispatch.sh
# Exit:  always 0 (cron job — failures are logged, not fatal to the run)

set -uo pipefail

# ── env（全部有預設值，供測試 fixture 覆寫） ──────────────────────────────
FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
FATQ_STALE_SECS="${FATQ_STALE_SECS:-7200}"                     # in_progress/rejected 催工門檻 (2h)
FATQ_NUDGE_COOLDOWN_SECS="${FATQ_NUDGE_COOLDOWN_SECS:-7200}"   # 兩次 nudge 最小間隔
FATQ_MAX_NUDGES="${FATQ_MAX_NUDGES:-3}"                        # 催滿升級
FATQ_CLAIM_TTL_SECS="${FATQ_CLAIM_TTL_SECS:-14400}"            # dispatch claim 有效期 (4h)
FATQ_MAX_DISPATCH="${FATQ_MAX_DISPATCH:-3}"                    # 重派上限，達到即升級
FATQ_DRY_RUN="${FATQ_DRY_RUN:-0}"                              # 1=只 log 決策，不寫任何檔
FATQ_NOW_EPOCH="${FATQ_NOW_EPOCH:-}"                           # 測試注入時鐘（空＝真實時間）
# 以下兩個未列於 spec §4.2 表格，但 §3.2 pending 無主任務判定需要可注入的門檻才可測試；
# 沿用「全部有預設值、供測試覆寫」的精神新增，非狀態機/欄位變動。
FATQ_UNASSIGNED_ALERT_SECS="${FATQ_UNASSIGNED_ALERT_SECS:-3600}"   # 無主任務首次提醒門檻 (60min)
FATQ_UNASSIGNED_REMIND_SECS="${FATQ_UNASSIGNED_REMIND_SECS:-86400}" # 無主任務重提醒間隔 (24h)
FATQ_STALE_RELAY_WARN_SECS="${FATQ_STALE_RELAY_WARN_SECS:-7200}"    # relay 檔滯留告警門檻 (2h, §6.4)
FATQ_STATE_DIR="${FATQ_STATE_DIR:-/home/oldrabbit/.claude-bots/shared/.fatq-dispatch-state}"  # §6.1/§6.4 告警節流狀態（測試須覆寫）
FATQ_MATTERMOST_DISABLE="${FATQ_MATTERMOST_DISABLE:-0}"             # 1＝不真的呼叫 mm_post（測試用）
# §2.2/§2.6（Part 2 approval_pending）：沿 unassigned_alert 節流模式，同款 24h 預設
FATQ_APPROVAL_REMIND_SECS="${FATQ_APPROVAL_REMIND_SECS:-86400}"
mkdir -p "$FATQ_STATE_DIR" 2>/dev/null || true

LOG_PREFIX="[fatq-dispatch]"

# ── 計數器（§4.4 收尾摘要） ────────────────────────────────────────────────
N_DISPATCHED=0
N_NUDGED=0
N_ESCALATED=0
N_SKIPPED=0
WRITE_ERROR_THIS_ROUND=0

# ── Mattermost 告警（§6.1/§6.4，Bella review 建議補上，非阻塞） ───────────
alert_mattermost() {
  local msg="$1"
  if [[ "$FATQ_DRY_RUN" == "1" || "$FATQ_MATTERMOST_DISABLE" == "1" ]]; then
    log_line "ALERT(suppressed dry_run/disabled) $msg"
    return 0
  fi
  ( source /home/oldrabbit/.claude-bots/bots/anya/.env.mattermost 2>/dev/null && bash /home/oldrabbit/.claude-bots/shared/bin/mm_post "$msg" ) >/dev/null 2>&1 \
    || log_line "WARN mattermost 告警發送失敗（非阻斷）: $msg"
}

# ── bot 名稱映射（§4.3，權威來源 shared/team-config.json + gateway BOTS） ──
# key: lowercase assigned/reviewer 值 → "recipient|tg_handle"
declare -A BOT_MAP=(
  [anna]="anna|@annadesu_bot"
  [sancai]="sancai|@threedishes_bot"
  [eric]="eric|@Ron0002_bot"
  [ron-builder]="eric|@Ron0002_bot"
  [bella]="Bella|@Bellalovechl_Bot"
  [yitang]="yitang|@onesoup_bot"
  [ron-reviewer]="ron-reviewer|@ron0003_bot"
  [twinkle]="twinkle|@TwinkleCHL_bot"
  ["星星人"]="twinkle|@TwinkleCHL_bot"
  [interns]="interns|@WuTung_bot"
  [anya]="|@Anyachl_bot"   # 不在 pod BOTS，recipient 留空，靠 text @handle 由常駐 plugin 自撿
)

# ── 時間工具 ───────────────────────────────────────────────────────────────
now_epoch() {
  if [[ -n "$FATQ_NOW_EPOCH" ]]; then
    printf '%s' "$FATQ_NOW_EPOCH"
  else
    date +%s
  fi
}

now_iso() {
  TZ='Asia/Taipei' date -d "@$(now_epoch)" '+%Y-%m-%dT%H:%M:%S+08:00'
}

iso_to_epoch() {
  # 缺值或壞值時回傳空字串，呼叫端自行 fallback
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && return 1
  date -d "$iso" +%s 2>/dev/null
}

log_line() {
  echo "[$(now_iso)] $*"
}

log_decision() {
  local task_id="$1" decision="$2"
  log_line "task=$task_id decision=$decision"
}

# ── bot 映射查找 ───────────────────────────────────────────────────────────
# 回傳 "recipient|handle"；查無回傳非 0
lookup_bot() {
  local raw="$1"
  local lower
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [[ -n "${BOT_MAP[$lower]:-}" ]]; then
    printf '%s' "${BOT_MAP[$lower]}"
    return 0
  fi
  return 1
}

# ── relay 檔名用的 task_id 消毒（Bella REJECT 修法，2026-07-05） ──────────
# task_id 本身就是 FATQ 唯一鍵，天然 collision-free；絕不可從內容「抓字」
# （舊版用 grep -oE 抓 4 個 hex 字元/tail -c 5，不同 task_id 會撞名，且
#   task_id 不含 hex 序列時 fallback 固定值，100% 必撞非機率問題）。
# 直接消毒整個 task_id：非英數字元全換成 "-"。
task_hex_id() {
  local tid="$1"
  echo "${tid//[^A-Za-z0-9]/-}"
}

# ── relay 檔名加來源目錄（phase），2026-07-05 Anya rider ───────────────────
# 同一 task_id 在不同階段（pending 派 assignee、review 派 reviewer 等）都可能
# 用同一個 type=dispatch、attempt 各自從 1 起算 → 不含 phase 會跨階段撞名
# （read/ 舊檔被 mv 覆蓋、審計軌跡疊掉；極端時序下 noclobber 誤判棄權延遲 4h）。
# 從 task_file 路徑取父目錄名當 phase，套用到全部 5 個 relay 檔名產生點。
task_phase() {
  basename "$(dirname "$1")"
}

# ── task JSON 有效性判定（§3.3，D9 防呆） ─────────────────────────────────
is_valid_task() {
  local f="$1"
  jq empty "$f" >/dev/null 2>&1 || return 1
  local tid
  tid=$(jq -r 'if (has("task_id") and (.task_id|type=="string") and (.task_id|length>0)) then .task_id else empty end' "$f" 2>/dev/null)
  [[ -n "$tid" ]] || return 1
  return 0
}

# ── 欄位讀取（相容 assigned/assigned_to，D2） ─────────────────────────────
get_assigned() {
  jq -r '(.assigned // .assigned_to // empty)' "$1" 2>/dev/null
}

get_reviewer() {
  jq -r '(.reviewer // empty)' "$1" 2>/dev/null
}

get_task_id() {
  jq -r '.task_id' "$1" 2>/dev/null
}

# ── not_before 欄位（Q7 正式解，取代「解除指派」窗口型任務 workaround） ────
# ISO8601；缺值/解析失敗一律視為「無 not_before」（不誤擋派工/催工）。
get_not_before_epoch() {
  local f="$1" nb
  nb=$(jq -r '(.not_before // empty)' "$f" 2>/dev/null)
  [[ -z "$nb" || "$nb" == "null" ]] && return 1
  iso_to_epoch "$nb"
}

# 回傳 0＝not_before 存在且仍在未來（該擋）；回傳非 0＝可派工/催工
is_not_before_future() {
  local f="$1" now="$2" nb_epoch
  nb_epoch=$(get_not_before_epoch "$f") || return 1
  [[ "$nb_epoch" -gt "$now" ]]
}

get_created_epoch() {
  local f="$1" created
  created=$(jq -r '(.created_at // empty)' "$f" 2>/dev/null)
  if [[ -n "$created" ]] && iso_to_epoch "$created" >/dev/null 2>&1; then
    iso_to_epoch "$created"
  else
    stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null
  fi
}

# 最後一筆「非 cron」history 條目的 ts epoch；history 空/無非 cron 條目 → 檔案 mtime（§3.4）
get_last_noncron_activity_epoch() {
  local f="$1" ts
  ts=$(jq -r '[.history // [] | .[] | select(.by != "fatq-dispatch-cron")] | last | (.ts // empty)' "$f" 2>/dev/null)
  if [[ -n "$ts" ]]; then
    iso_to_epoch "$ts" || stat -c %Y "$f" 2>/dev/null
  else
    stat -c %Y "$f" 2>/dev/null
  fi
}

# 該 activity 之後、cron 寫入的 action=="nudge" 條目數
count_cron_nudges_since_index() {
  local f="$1" since_idx="$2"
  jq -r --argjson idx "$since_idx" '
    [ .history // [] | to_entries[] | select(.key > $idx) | .value | select(.by=="fatq-dispatch-cron" and .action=="nudge") ] | length
  ' "$f" 2>/dev/null
}

# 該 activity 之後是否已有 action=="escalate" 條目
has_cron_escalate_since_index() {
  local f="$1" since_idx="$2"
  local c
  c=$(jq -r --argjson idx "$since_idx" '
    [ .history // [] | to_entries[] | select(.key > $idx) | .value | select(.by=="fatq-dispatch-cron" and .action=="escalate") ] | length
  ' "$f" 2>/dev/null)
  [[ "$c" -gt 0 ]]
}

# 找出「最後一筆非 cron 條目」在 history 陣列中的 index（-1 表示不存在／history 為空）
get_last_noncron_index() {
  local f="$1"
  jq -r '
    ([.history // [] | to_entries[] | select(.value.by != "fatq-dispatch-cron") | .key] | last) // -1
  ' "$f" 2>/dev/null
}

# ── history append（crash-safe：flock 包住 read-modify-rename，§6.6） ──────
# 回傳 0＝成功寫入；1＝檔案在讀寫之間消失（已被 mv 走，呼叫端應 skip:moved）
append_history_locked() {
  local task_file="$1" entry_json="$2"
  local lock_fd

  if [[ "$FATQ_DRY_RUN" == "1" ]]; then
    return 0
  fi

  exec {lock_fd}<"$task_file" 2>/dev/null || return 1
  flock -x "$lock_fd"

  if [[ ! -e "$task_file" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}<&- 2>/dev/null || true
    return 1
  fi

  local dir tmp
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-dispatch.XXXXXX")"
  if ! jq --argjson entry "$entry_json" '.history = ((.history // []) + [$entry])' "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}<&- 2>/dev/null || true
    return 1
  fi
  mv -f "$tmp" "$task_file"

  flock -u "$lock_fd"
  exec {lock_fd}<&- 2>/dev/null || true
  return 0
}

# ── relay 檔原子寫入（tmp + ln noclobber，§3.5 併發去重） ──────────────────
# 回傳 0＝本進程贏得寫入；1＝檔名已存在（輸家，放棄不當第二次 claim）
write_relay_atomic() {
  local filename="$1" content="$2"
  local tmp_dir="$FATQ_RELAY_DIR/.tmp"

  if [[ "$FATQ_DRY_RUN" == "1" ]]; then
    return 0
  fi

  if ! mkdir -p "$tmp_dir" "$FATQ_RELAY_DIR" 2>/dev/null; then
    WRITE_ERROR_THIS_ROUND=1
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "$tmp_dir/relay.XXXXXX" 2>/dev/null) || { WRITE_ERROR_THIS_ROUND=1; return 1; }
  if ! printf '%s' "$content" > "$tmp_file" 2>/dev/null; then
    WRITE_ERROR_THIS_ROUND=1
    rm -f "$tmp_file"
    return 1
  fi

  if ln "$tmp_file" "$FATQ_RELAY_DIR/$filename" 2>/dev/null; then
    rm -f "$tmp_file"
    return 0
  else
    rm -f "$tmp_file"
    if [[ -e "$FATQ_RELAY_DIR/$filename" ]]; then
      return 1   # 正常 noclobber 併發輸家（§3.5），非錯誤
    fi
    WRITE_ERROR_THIS_ROUND=1  # 目標仍不存在＝真正寫入失敗（權限/磁碟等，§6.1）
    return 1
  fi
}

relay_file_exists() {
  [[ -e "$FATQ_RELAY_DIR/$1" ]]
}

# ── 建構派工/催工/升級的 relay JSON 內容 ───────────────────────────────────
build_relay_json() {
  local recipient="$1" text="$2" task_id="$3"
  jq -n --arg from "fatq-dispatch-cron" --arg recipient "$recipient" --arg text "$text" \
        --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot: $from, recipient: $recipient, text: $text, ts: $ts, fatq_task_id: $tid}'
}

# ══════════════════════════════════════════════════════════════════════════
# 核心：pending / design_review / review / spec_review / design 的
# dispatch 判斷與執行（§3.5 idempotency 適用於這五類目錄的「首派/重派」）
# ══════════════════════════════════════════════════════════════════════════
handle_dispatch_target() {
  local task_file="$1" recipient="$2" handle="$3" text="$4"
  local task_id
  task_id=$(get_task_id "$task_file")
  local now
  now=$(now_epoch)

  # 即時重讀，找出最後一筆 action=="dispatch" 的 cron 條目（若有）
  local last_dispatch
  last_dispatch=$(jq -c '[.history // [] | to_entries[] | select(.value.by=="fatq-dispatch-cron" and .value.action=="dispatch")] | last' "$task_file" 2>/dev/null)

  local attempt=1
  if [[ -n "$last_dispatch" && "$last_dispatch" != "null" ]]; then
    local d_idx d_ts d_epoch d_attempt d_relay
    d_idx=$(jq -r '.key' <<<"$last_dispatch")
    d_ts=$(jq -r '.value.ts' <<<"$last_dispatch")
    d_attempt=$(jq -r '.value.attempt // 1' <<<"$last_dispatch")
    d_relay=$(jq -r '.value.relay_file // empty' <<<"$last_dispatch")
    d_epoch=$(iso_to_epoch "$d_ts" || echo 0)

    # 該 dispatch 之後有沒有 assignee(非 cron) 活動？
    local activity_after
    activity_after=$(jq -r --argjson idx "$d_idx" '
      [.history // [] | to_entries[] | select(.key > $idx and .value.by != "fatq-dispatch-cron")] | length
    ' "$task_file" 2>/dev/null)

    # 規則 2：上一筆 relay 檔仍在 relay/（gateway 尚未消費）→ 絕不再寫第二份
    if [[ -n "$d_relay" ]] && relay_file_exists "$d_relay"; then
      local relay_age=$(( now - $(stat -c %Y "$FATQ_RELAY_DIR/$d_relay" 2>/dev/null || echo "$now") ))
      if [[ "$relay_age" -gt "$FATQ_STALE_RELAY_WARN_SECS" ]]; then
        log_line "task=$task_id WARN relay 檔滯留 ${relay_age}s 未被消費：$d_relay"
        local alerted_marker="$FATQ_STATE_DIR/alerted-${d_relay}"
        if [[ ! -f "$alerted_marker" ]]; then
          alert_mattermost "🟡 fatq-dispatch: task=${task_id} 的 relay 檔 ${d_relay} 滯留 ${relay_age}s（>${FATQ_STALE_RELAY_WARN_SECS}s）未被 gateway 消費，可能 gateway 離線。"
          touch "$alerted_marker" 2>/dev/null || true
        fi
      fi
      log_decision "$task_id" "skip:relay_pending"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi

    if [[ "$activity_after" -gt 0 ]]; then
      : # assignee 已有活動，視同無有效 claim 擋路，走首派邏輯（attempt 重算為 1）
    elif [[ $(( now - d_epoch )) -lt "$FATQ_CLAIM_TTL_SECS" ]]; then
      # 規則 1：有效 claim，跳過不重派
      log_decision "$task_id" "skip:claimed"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    else
      # 規則 3：claim 過期且全程無活動 → 允許重派
      attempt=$(( d_attempt + 1 ))
      if [[ "$attempt" -gt "$FATQ_MAX_DISPATCH" ]]; then
        # 達重派上限 → 停止重派，改 escalate（一次性，用同一把 escalate 判斷避免重複）
        if has_cron_escalate_since_index "$task_file" "$d_idx"; then
          log_decision "$task_id" "skip:already_escalated"
          N_SKIPPED=$((N_SKIPPED+1))
          return 0
        fi
        local esc_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a${d_attempt}-escalate.json"
        local esc_text="[FATQ 升級] 任務 ${task_id} 已重派 ${d_attempt} 次仍無 assignee 活動，達重派上限 ${FATQ_MAX_DISPATCH}，停止自動重派。任務檔：${task_file}\n@Anyachl_bot 請人工介入。"
        local esc_content
        esc_content=$(build_relay_json "" "$esc_text" "$task_id")
        local esc_entry
        esc_entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$esc_relay" --arg target "$recipient" --argjson attempt "$d_attempt" \
          '{ts: $ts, by: "fatq-dispatch-cron", action: "escalate", relay_file: $relay, target: $target, attempt: $attempt}')
        if append_history_locked "$task_file" "$esc_entry"; then
          write_relay_atomic "$esc_relay" "$esc_content" || true
          log_decision "$task_id" "escalate"
          N_ESCALATED=$((N_ESCALATED+1))
        else
          log_decision "$task_id" "skip:moved"
          N_SKIPPED=$((N_SKIPPED+1))
        fi
        return 0
      fi
    fi
  fi

  # 走到這裡＝首派或允許中的重派，attempt 已定
  local relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a${attempt}-dispatch.json"
  local relay_content
  relay_content=$(build_relay_json "$recipient" "$text" "$task_id")

  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --arg target "$recipient" --argjson attempt "$attempt" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "dispatch", relay_file: $relay, target: $target, attempt: $attempt}')

  # 寫入順序（crash-safe，§3.5）：先 append history claim 行，再寫 relay 檔
  if ! append_history_locked "$task_file" "$entry"; then
    log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  if write_relay_atomic "$relay_file" "$relay_content"; then
    log_decision "$task_id" "dispatch"
    N_DISPATCHED=$((N_DISPATCHED+1))
  else
    # 檔名已存在＝另一個並發 dispatcher 贏了（§3.5 併發去重）。
    # history 端我方仍寫入一筆 claim（last-writer-wins 可能吃掉一筆），
    # relay 唯一性由檔名保證，不視為錯誤。
    log_decision "$task_id" "dispatch:lost_race"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# nudge/escalate（in_progress、rejected 適用，§3.2 / §3.4）
# ══════════════════════════════════════════════════════════════════════════
handle_nudge_target() {
  local task_file="$1" recipient="$2" handle="$3" verb="$4"   # verb: 描述用文字
  local task_id
  task_id=$(get_task_id "$task_file")
  local now
  now=$(now_epoch)

  local basis_idx basis_epoch
  basis_idx=$(get_last_noncron_index "$task_file")
  basis_epoch=$(get_last_noncron_activity_epoch "$task_file")
  [[ -z "$basis_epoch" ]] && basis_epoch=$now

  local age=$(( now - basis_epoch ))
  if [[ "$age" -lt "$FATQ_STALE_SECS" ]]; then
    log_decision "$task_id" "skip:not_stale"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  # 已升級過（同一 staleness 週期內）→ 不再重複升級，也不再催
  if has_cron_escalate_since_index "$task_file" "$basis_idx"; then
    log_decision "$task_id" "skip:already_escalated"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local nudge_count
  nudge_count=$(count_cron_nudges_since_index "$task_file" "$basis_idx")

  if [[ "$nudge_count" -ge "$FATQ_MAX_NUDGES" ]]; then
    # 升級（一次性）
    local esc_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a$((nudge_count+1))-escalate.json"
    local esc_text="[FATQ 升級] 任務 ${task_id} 已催 ${nudge_count} 次無回應（最後活動 $(TZ='Asia/Taipei' date -d "@$basis_epoch" '+%Y-%m-%d %H:%M') +08:00），assigned=${recipient}。任務檔：${task_file}\n@Anyachl_bot 請人工介入。"
    local esc_content
    esc_content=$(build_relay_json "" "$esc_text" "$task_id")
    local esc_entry
    esc_entry=$(jq -n --arg ts "$(now_iso)" --argjson n "$nudge_count" --arg target "$recipient" \
      '{ts: $ts, by: "fatq-dispatch-cron", action: "escalate", target: $target, nudge_count: $n}')
    if append_history_locked "$task_file" "$esc_entry"; then
      write_relay_atomic "$esc_relay" "$esc_content" || true
      log_decision "$task_id" "escalate"
      N_ESCALATED=$((N_ESCALATED+1))
    else
      log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
    fi
    return 0
  fi

  # cooldown：距上一筆 cron nudge 是否 > FATQ_NUDGE_COOLDOWN_SECS
  local last_nudge_ts last_nudge_epoch
  last_nudge_ts=$(jq -r --argjson idx "$basis_idx" '
    [.history // [] | to_entries[] | select(.key > $idx and .value.by=="fatq-dispatch-cron" and .value.action=="nudge")] | last | .value.ts // empty
  ' "$task_file" 2>/dev/null)
  if [[ -n "$last_nudge_ts" ]]; then
    last_nudge_epoch=$(iso_to_epoch "$last_nudge_ts" || echo 0)
    if [[ $(( now - last_nudge_epoch )) -lt "$FATQ_NUDGE_COOLDOWN_SECS" ]]; then
      log_decision "$task_id" "skip:cooldown"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
  fi

  # 發一次 nudge
  local next_n=$((nudge_count+1))
  local nudge_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a${next_n}-nudge.json"
  local nudge_text="[FATQ 催工] 任務 ${task_id} ${verb}已 $((age/60)) 分鐘無新進度（第 ${next_n}/${FATQ_MAX_NUDGES} 次提醒）。任務檔：${task_file}\n完成後先跑 shared/bin/fatq-verify.sh 全過再 mv 狀態。"
  local nudge_content
  nudge_content=$(build_relay_json "$recipient" "$nudge_text" "$task_id")
  local nudge_entry
  nudge_entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$nudge_relay" --arg target "$recipient" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "nudge", relay_file: $relay, target: $target}')

  if ! append_history_locked "$task_file" "$nudge_entry"; then
    log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  write_relay_atomic "$nudge_relay" "$nudge_content" || true
  log_decision "$task_id" "nudge"
  N_NUDGED=$((N_NUDGED+1))
}

# ══════════════════════════════════════════════════════════════════════════
# pending/ 無主任務提醒（§3.2）
# ══════════════════════════════════════════════════════════════════════════
handle_unassigned_pending() {
  local task_file="$1"
  local task_id
  task_id=$(get_task_id "$task_file")
  local now created age
  now=$(now_epoch)
  created=$(get_created_epoch "$task_file")
  age=$(( now - created ))

  if [[ "$age" -lt "$FATQ_UNASSIGNED_ALERT_SECS" ]]; then
    log_decision "$task_id" "skip:too_new"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local last_alert_ts last_alert_epoch
  last_alert_ts=$(jq -r '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="unassigned_alert")] | last | .ts // empty' "$task_file" 2>/dev/null)
  if [[ -n "$last_alert_ts" ]]; then
    last_alert_epoch=$(iso_to_epoch "$last_alert_ts" || echo 0)
    if [[ $(( now - last_alert_epoch )) -lt "$FATQ_UNASSIGNED_REMIND_SECS" ]]; then
      log_decision "$task_id" "skip:remind_cooldown"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
  fi

  local text="[FATQ 無主任務] ${task_id} 進 pending 已 $((age/60)) 分鐘仍無 assigned/assigned_to。任務檔：${task_file}\n@Anyachl_bot 請指派。"
  local content
  content=$(build_relay_json "" "$text" "$task_id")
  local relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-unassigned.json"
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" '{ts: $ts, by: "fatq-dispatch-cron", action: "unassigned_alert"}')

  if ! append_history_locked "$task_file" "$entry"; then
    log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  write_relay_atomic "$relay_file" "$content" || true
  log_decision "$task_id" "unassigned_alert"
  N_NUDGED=$((N_NUDGED+1))
}

# ══════════════════════════════════════════════════════════════════════════
# approval_pending/ 通知 + 逾時梯（Part 2 §2.2/§2.6）
#
# 紅線（v1.3 §6.6 原樣適用）：cron 對此目錄只 append history，永不 mv——
# 所有轉移（approve/reject/expire）都由 fatq-cli 角色親手執行。
# 逾時梯：①未到期→24h 節流的一般提醒 ②到期→升級提醒一次性
# （approval_expired_alert）③升級後再 24h 仍未決策→提醒 Anya 執行
# `fatq approval expire`（同樣 24h 節流，可重複直到被處理）。
# ══════════════════════════════════════════════════════════════════════════
handle_approval_pending() {
  local task_file="$1"
  local task_id
  task_id=$(get_task_id "$task_file")
  local now status expires_iso expires_epoch domain requested_by
  now=$(now_epoch)
  status=$(jq -r '.approval.status // ""' "$task_file" 2>/dev/null)
  expires_iso=$(jq -r '.approval.expires // ""' "$task_file" 2>/dev/null)
  domain=$(jq -r '.approval.domain // "?"' "$task_file" 2>/dev/null)
  requested_by=$(jq -r '.approval.requested_by // "?"' "$task_file" 2>/dev/null)
  expires_epoch=$(iso_to_epoch "$expires_iso" || echo "$now")

  if [[ "$status" != "pending" ]]; then
    # approve/reject/expire 已由 CLI 處理過但檔案還沒被移走（極短暫窗口）；不重複通知
    log_decision "$task_id" "skip:approval_not_pending"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  if [[ "$now" -lt "$expires_epoch" ]]; then
    # 未到期：一般提醒，24h 節流（沿 unassigned_alert 模式）
    local last_ts last_epoch
    last_ts=$(jq -r '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="approval_reminder")] | last | .ts // empty' "$task_file" 2>/dev/null)
    if [[ -n "$last_ts" ]]; then
      last_epoch=$(iso_to_epoch "$last_ts" || echo 0)
      if [[ $(( now - last_epoch )) -lt "$FATQ_APPROVAL_REMIND_SECS" ]]; then
        log_decision "$task_id" "skip:approval_remind_cooldown"
        N_SKIPPED=$((N_SKIPPED+1))
        return 0
      fi
    fi

    local text="[FATQ 審批待決] ${task_id}（domain=${domain}, requested_by=${requested_by}）待審批，${expires_iso} 逾時。任務檔：${task_file}\n@Anyachl_bot 請轉達老兔決策。"
    local content relay_file entry
    content=$(build_relay_json "" "$text" "$task_id")
    relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-approval-reminder.json"
    entry=$(jq -n --arg ts "$(now_iso)" '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_reminder"}')

    if ! append_history_locked "$task_file" "$entry"; then
      log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    write_relay_atomic "$relay_file" "$content" || true
    log_decision "$task_id" "approval_reminder"
    N_NUDGED=$((N_NUDGED+1))
    return 0
  fi

  # 已逾時：§2.6 逾時梯
  local expired_alert_ts
  expired_alert_ts=$(jq -r '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="approval_expired_alert")] | last | .ts // empty' "$task_file" 2>/dev/null)

  if [[ -z "$expired_alert_ts" ]]; then
    # 第一步：升級提醒一次性
    local text="[FATQ 審批逾時] ${task_id}（domain=${domain}）已逾時（${expires_iso}）仍無決策。任務檔：${task_file}\n@Anyachl_bot 請盡速轉達老兔，逾時不等於同意（default-deny）。"
    local content relay_file entry
    content=$(build_relay_json "" "$text" "$task_id")
    relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-approval-expired-alert.json"
    entry=$(jq -n --arg ts "$(now_iso)" '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_expired_alert"}')

    if ! append_history_locked "$task_file" "$entry"; then
      log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    write_relay_atomic "$relay_file" "$content" || true
    log_decision "$task_id" "approval_expired_alert"
    N_ESCALATED=$((N_ESCALATED+1))
    return 0
  fi

  # 第二步：升級後再 24h 仍無決策 → 提醒 Anya 執行回收（可重複直到被處理，24h 節流）
  local expired_alert_epoch
  expired_alert_epoch=$(iso_to_epoch "$expired_alert_ts" || echo 0)
  if [[ $(( now - expired_alert_epoch )) -lt "$FATQ_APPROVAL_REMIND_SECS" ]]; then
    log_decision "$task_id" "skip:approval_expire_cooldown"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local last_expire_reminder_ts
  last_expire_reminder_ts=$(jq -r '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="approval_expire_reminder")] | last | .ts // empty' "$task_file" 2>/dev/null)
  if [[ -n "$last_expire_reminder_ts" ]]; then
    local last_expire_reminder_epoch
    last_expire_reminder_epoch=$(iso_to_epoch "$last_expire_reminder_ts" || echo 0)
    if [[ $(( now - last_expire_reminder_epoch )) -lt "$FATQ_APPROVAL_REMIND_SECS" ]]; then
      log_decision "$task_id" "skip:approval_expire_cooldown"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
  fi

  local text="[FATQ 審批回收] ${task_id} 逾時已超過 24h 仍無決策。請執行：fatq approval expire ${task_id} --as anya（回歸 ${task_file} 原狀態，decision 維持 null，受門控操作仍不得執行）。"
  local content relay_file entry
  content=$(build_relay_json "" "$text" "$task_id")
  relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-approval-expire-reminder.json"
  entry=$(jq -n --arg ts "$(now_iso)" '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_expire_reminder"}')

  if ! append_history_locked "$task_file" "$entry"; then
    log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  write_relay_atomic "$relay_file" "$content" || true
  log_decision "$task_id" "approval_expire_reminder"
  N_NUDGED=$((N_NUDGED+1))
}

scan_dir_approval_pending() {
  local dir="$FATQ_ROOT/approval_pending"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if ! is_valid_task "$f"; then
      log_line "WARN invalid task json, skip: $f"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi
    handle_approval_pending "$f"
  done
}

# ══════════════════════════════════════════════════════════════════════════
# 掃描主流程（§3.2）
# ══════════════════════════════════════════════════════════════════════════
scan_dir_dispatch() {
  # $1 = 目錄名（pending/design_review/review/spec_review/design）
  # $2 = 欄位來源：assigned（pending 用）或 reviewer（review 系列用，缺省 Bella）或 fixed:<name>（design 用）
  local dirname="$1" field_mode="$2"
  local dir="$FATQ_ROOT/$dirname"
  [[ -d "$dir" ]] || return 0

  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue

    if ! is_valid_task "$f"; then
      log_line "WARN invalid task json, skip: $f"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi
    local task_id
    task_id=$(get_task_id "$f")

    # not_before（Q7）：僅 pending 適用，判定前先擋——與 unassigned_alert 互斥
    # （未到時間一律 skip:not_before，不管有無 assigned，不再靠「解除指派」迴避乒乓）
    if [[ "$dirname" == "pending" ]] && is_not_before_future "$f" "$(now_epoch)"; then
      log_decision "$task_id" "skip:not_before"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi

    # approval 門控（Anya 裁決 2026-07-07，Part 2 spec_conflict 結案，Bella 轉錄
    # 於 task a7e5 history）：approval 物件存在且 decision 為 null（含 expired
    # 回 pending 但尚未重新審批的情形）→ 不視為可正常派工的任務，
    # skip:approval_gated——不派、不寫 history（僅 log_decision，紅線例外已授權）。
    if [[ "$dirname" == "pending" ]]; then
      local approval_decision
      approval_decision=$(jq -r 'if has("approval") and (.approval != null) then (.approval.decision // "null") else "none" end' "$f" 2>/dev/null)
      if [[ "$approval_decision" == "null" ]]; then
        log_decision "$task_id" "skip:approval_gated"
        N_SKIPPED=$((N_SKIPPED+1))
        continue
      fi
    fi

    local raw_name=""
    case "$field_mode" in
      assigned)
        raw_name=$(get_assigned "$f")
        if [[ -z "$raw_name" ]]; then
          handle_unassigned_pending "$f"
          continue
        fi
        ;;
      reviewer)
        raw_name=$(get_reviewer "$f")
        [[ -z "$raw_name" ]] && raw_name="bella"
        ;;
      fixed:*)
        raw_name="${field_mode#fixed:}"
        ;;
    esac

    local mapped
    if ! mapped=$(lookup_bot "$raw_name"); then
      log_line "ERROR unknown bot mapping '$raw_name' for task=$task_id, skip"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi
    local recipient="${mapped%%|*}"
    local handle="${mapped##*|}"

    local text
    case "$dirname" in
      pending)
        text="[FATQ 派工] 任務 ${task_id} 已指派給你。\n任務檔：${f}\n請：1) 讀任務檔（先讀 last_run_summary/lessons_learned 若有）；2) 自行 mv pending→in_progress（原子操作，append history）；3) 完成後先跑 shared/bin/fatq-verify.sh 全過，再 mv in_progress→review。你不得 mv 到 done。"
        ;;
      review|spec_review|design_review)
        text="[FATQ 派工·審查] 任務 ${task_id} 待你審查。\n任務檔：${f}\nQA 第一步先跑 fatq-verify.sh，任一 fail 直接 REJECT，不進人工審。"
        ;;
      design)
        text="[FATQ 派工·設計] 任務 ${task_id} 待你出設計方案。\n任務檔：${f}"
        ;;
      *)
        text="[FATQ 派工] 任務 ${task_id}。任務檔：${f}"
        ;;
    esac

    handle_dispatch_target "$f" "$recipient" "$handle" "$text"
  done
}

scan_dir_nudge() {
  # $1 = 目錄名（in_progress/rejected）
  local dirname="$1"
  local dir="$FATQ_ROOT/$dirname"
  [[ -d "$dir" ]] || return 0

  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue

    if ! is_valid_task "$f"; then
      log_line "WARN invalid task json, skip: $f"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi
    local task_id raw_name
    task_id=$(get_task_id "$f")

    # not_before（Q7）：in_progress/rejected 同樣適用，判定前先擋
    if is_not_before_future "$f" "$(now_epoch)"; then
      log_decision "$task_id" "skip:not_before"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi

    raw_name=$(get_assigned "$f")
    if [[ -z "$raw_name" ]]; then
      log_line "WARN task=$task_id in $dirname has no assigned, skip"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi

    local mapped
    if ! mapped=$(lookup_bot "$raw_name"); then
      log_line "ERROR unknown bot mapping '$raw_name' for task=$task_id, skip"
      N_SKIPPED=$((N_SKIPPED+1))
      continue
    fi
    local recipient="${mapped%%|*}"
    local handle="${mapped##*|}"

    local verb="停滯"
    [[ "$dirname" == "rejected" ]] && verb="被 REJECT 後未修復"

    handle_nudge_target "$f" "$recipient" "$handle" "$verb"
  done
}

skip_dir() {
  local dirname="$1"
  local dir="$FATQ_ROOT/$dirname"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if is_valid_task "$f"; then
      log_decision "$(get_task_id "$f")" "skip:terminal_or_nontask"
    fi
    N_SKIPPED=$((N_SKIPPED+1))
  done
}

# ══════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════
main() {
  log_line "scan start (dry_run=$FATQ_DRY_RUN, root=$FATQ_ROOT, relay=$FATQ_RELAY_DIR)"

  scan_dir_dispatch "pending" "assigned"
  scan_dir_dispatch "design_review" "reviewer"
  scan_dir_dispatch "review" "reviewer"
  scan_dir_dispatch "spec_review" "reviewer"
  scan_dir_dispatch "design" "fixed:twinkle"

  scan_dir_nudge "rejected"
  scan_dir_nudge "in_progress"

  scan_dir_approval_pending

  for d in done cancelled wont_do reviews proposals; do
    skip_dir "$d"
  done

  log_line "scan done: ${N_DISPATCHED} dispatched, ${N_NUDGED} nudged, ${N_ESCALATED} escalated, ${N_SKIPPED} skipped"

  # §6.1：relay 寫入連續 2 輪出現 ERROR → 告警一次（noclobber 併發輸家不計入，見 write_relay_atomic）
  local err_flag="$FATQ_STATE_DIR/last_round_write_error"
  if [[ "$WRITE_ERROR_THIS_ROUND" == "1" ]]; then
    if [[ -f "$err_flag" ]]; then
      alert_mattermost "🔴 fatq-dispatch: relay 寫入連續 2 輪出現 ERROR，請檢查磁碟/權限（log: logs/fatq-dispatch.log）。"
    fi
    touch "$err_flag" 2>/dev/null || true
  else
    rm -f "$err_flag" 2>/dev/null || true
  fi
}

main "$@"
exit 0

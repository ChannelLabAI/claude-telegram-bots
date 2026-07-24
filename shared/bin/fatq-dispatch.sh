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
FATQ_TEAM_CONFIG="${FATQ_TEAM_CONFIG:-/home/oldrabbit/.claude-bots/shared/team-config.json}"
FATQ_STALE_SECS="${FATQ_STALE_SECS:-7200}"                     # in_progress/rejected 催工門檻 (2h)
FATQ_NUDGE_COOLDOWN_SECS="${FATQ_NUDGE_COOLDOWN_SECS:-7200}"   # 兩次 nudge 最小間隔
FATQ_MAX_NUDGES="${FATQ_MAX_NUDGES:-3}"                        # 催滿升級
FATQ_DAILY_NUDGE_LIMIT="${FATQ_DAILY_NUDGE_LIMIT:-2}"           # 每單每日最多例行 nudge 次數
FATQ_CLAIM_TTL_SECS="${FATQ_CLAIM_TTL_SECS:-14400}"            # dispatch claim 有效期 (4h)
FATQ_MAX_DISPATCH="${FATQ_MAX_DISPATCH:-3}"                    # 重派上限，達到即升級
FATQ_DRY_RUN="${FATQ_DRY_RUN:-0}"                              # 1=只 log 決策，不寫任何檔
FATQ_NOW_EPOCH="${FATQ_NOW_EPOCH:-}"                           # 測試注入時鐘（空＝真實時間）
# 以下兩個未列於 spec §4.2 表格，但 §3.2 pending 無主任務判定需要可注入的門檻才可測試；
# 沿用「全部有預設值、供測試覆寫」的精神新增，非狀態機/欄位變動。
FATQ_UNASSIGNED_ALERT_SECS="${FATQ_UNASSIGNED_ALERT_SECS:-3600}"   # 無主任務首次提醒門檻 (60min)
FATQ_UNASSIGNED_REMIND_SECS="${FATQ_UNASSIGNED_REMIND_SECS:-86400}" # 無主任務重提醒間隔 (24h)
FATQ_STALE_RELAY_WARN_SECS="${FATQ_STALE_RELAY_WARN_SECS:-7200}"    # relay 檔滯留告警門檻 (2h, §6.4)
FATQ_BLOCKED_ALERT_SECS="${FATQ_BLOCKED_ALERT_SECS:-900}"           # blocked 無後續活動告警門檻 (15min)
FATQ_STATE_DIR="${FATQ_STATE_DIR:-/home/oldrabbit/.claude-bots/shared/.fatq-dispatch-state}"  # §6.1/§6.4 告警節流狀態（測試須覆寫）
FATQ_MATTERMOST_DISABLE="${FATQ_MATTERMOST_DISABLE:-0}"             # 1＝不真的呼叫 mm_post（測試用）
# §2.2/§2.6（Part 2 approval_pending）：沿 unassigned_alert 節流模式，同款 24h 預設
FATQ_APPROVAL_REMIND_SECS="${FATQ_APPROVAL_REMIND_SECS:-86400}"
# org-design-lines-20260707 決議 #2/#3（d5c3）：業務線軟親和 + 公共財偵測表，
# 與 fatq-cli.sh create 的 infra 偵測補遺共用同一份配置檔，改映射/模式表不動代碼。
FATQ_DISPATCH_AFFINITY="${FATQ_DISPATCH_AFFINITY:-/home/oldrabbit/.claude-bots/shared/lib/dispatch-affinity.json}"
FATQ_TRUST_LEDGER="${FATQ_TRUST_LEDGER:-/home/oldrabbit/.claude-bots/shared/loops/trust-ledger/trust.tsv}"
# Test fixtures that predate the create provenance contract may explicitly disable
# this gate. Production defaults fail closed.
FATQ_CREATE_GATE_DISABLED="${FATQ_CREATE_GATE_DISABLED:-0}"
mkdir -p "$FATQ_STATE_DIR" 2>/dev/null || true

LOG_PREFIX="[fatq-dispatch]"

# ── 計數器（§4.4 收尾摘要） ────────────────────────────────────────────────
N_DISPATCHED=0
N_NUDGED=0
N_ESCALATED=0
N_COMPLETION_NOTIFIED=0
N_REJECT_NOTIFIED=0
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
  [bella]="bella|@Bellalovechl_Bot"
  [yitang]="yitang|@onesoup_bot"
  [kk]="kk|@ron0003_bot"
  [twinkle]="twinkle|@TwinkleCHL_bot"
  ["星星人"]="twinkle|@TwinkleCHL_bot"
  [orange]="orange|@WuTung_bot"
  [spark]="spark|"
  [sara]="sara|"
  [anya]="anya|@Anyachl_bot" # 特助也必須使用明確 structured recipient；禁止空 recipient fallback
  [stargazer]="stargazer|@stargazer_chlbot" # 小米特助；相容映射，requester delivery 解析仍走 team-config.json
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

today_key() {
  TZ='Asia/Taipei' date -d "@$(now_epoch)" '+%Y-%m-%d'
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

lc_local() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

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

# Completion delivery resolves requester-chain bots from team-config rather
# than the assignment/reviewer compatibility map above. Exactly one matching
# bot state_dir is required; external human identities are not delivery routes.
lookup_delivery_bot() {
  local lower match
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  match=$(jq -r --arg ident "$lower" '
    [ (.assistants // [])[]?,
      (.shared_pools // {} | to_entries[] | .value[]?) ]
    | map(select((.state_dir // "" | ascii_downcase) == $ident))
    | if length == 1 then
        "\(.[0].state_dir)|\(.[0].bot_username // "")"
      else empty end
  ' "$FATQ_TEAM_CONFIG" 2>/dev/null)
  [[ -n "$match" ]] || return 1
  printf '%s' "$match"
}

# ── 業務線軟親和 + 公共財偵測（org-design-lines-20260707 決議 #2/#3，d5c3） ──
# 讀 shared/lib/dispatch-affinity.json，改映射/模式表不動代碼即生效。
# $1=task_file $2=欄位名（builder|reviewer），查無 created_by 對應線或設定檔
# 不存在時一律 fallback 到 lines.default，找不到 default 才算失敗（極端防呆）。
get_affinity_default() {
  local f="$1" field="$2" created_by
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  created_by=$(jq -r '(.created_by // "")' "$f" 2>/dev/null)
  jq -r --arg cb "$created_by" --arg field "$field" \
    '(.lines[$cb][$field] // .lines.default[$field] // empty)' "$FATQ_DISPATCH_AFFINITY" 2>/dev/null
}

# goal/context/deliverables 文字命中 infra_patterns 任一子字串 → 視為公共財變動
# （防漏優先於防誤，Diana 式機械守門，同 fatq-cli.sh is_infra_change 的精神）
is_infra_task() {
  local f="$1"
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  local probe_text
  probe_text=$(jq -r '[(.goal // "" | tostring), (.context // "" | tostring), ((.deliverables // [])[]? | tostring)] | join(" ")' "$f" 2>/dev/null) || probe_text=""
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if [[ "$probe_text" == *"$pattern"* ]]; then
      return 0
    fi
  done < <(jq -r '.infra_patterns[]?' "$FATQ_DISPATCH_AFFINITY" 2>/dev/null)
  return 1
}

trust_hint_for_task() {
  local f="$1" subject category
  subject="$(get_assigned "$f" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$subject" ]] && return 0
  category="normal"
  is_infra_task "$f" && category="infra"
  if [[ -f "$FATQ_TRUST_LEDGER" ]]; then
    local row
    row="$(awk -F'\t' -v s="$subject" -v c="$category" 'NR>1 && $1==s && $2==c && $3=="" {print; exit}' "$FATQ_TRUST_LEDGER" 2>/dev/null)"
    [[ -z "$row" ]] && row="$(awk -F'\t' -v s="$subject" 'NR>1 && $1==s && $2=="*" && $3=="" {print; exit}' "$FATQ_TRUST_LEDGER" 2>/dev/null)"
    if [[ -n "$row" ]]; then
      local _category runs rate level
      _category="$(awk -F'\t' '{print $2}' <<< "$row")"
      runs="$(awk -F'\t' '{print $5}' <<< "$row")"
      rate="$(awk -F'\t' '{print $8}' <<< "$row")"
      level="$(awk -F'\t' '{print $9}' <<< "$row")"
      printf '\n信任帳本(advisory-only)：%s/%s level=%s pass_rate=%s runs=%s；不自動放行、不省 QA gate。' "$subject" "$_category" "$level" "$rate" "$runs"
      return 0
    fi
  fi
  printf '\n信任帳本(advisory-only)：%s/%s level=L2 default（無帳本或無樣本）；不自動放行、不省 QA gate。' "$subject" "$category"
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

is_terminal_dir() {
  case "$1" in
    done|cancelled|wont_do) return 0 ;;
    *) return 1 ;;
  esac
}

is_legacy_task_json() {
  local f="$1"
  jq -e '
    type == "object"
    and (has("task_id") | not)
    and (
      (.id? | type == "string" and length > 0)
      or (.title? | type == "string" and length > 0)
      or (.goal? | type == "string" and length > 0)
      or (.spec? | type == "string" and length > 0)
      or (.status? | type == "string" and length > 0)
      or (.history? | type == "array")
    )
  ' "$f" >/dev/null 2>&1
}

handle_invalid_task_json() {
  local f="$1" dirname="$2"
  if is_terminal_dir "$dirname" && is_legacy_task_json "$f"; then
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  log_line "WARN invalid task json, skip: $f"
  N_SKIPPED=$((N_SKIPPED+1))
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

# 回傳 0＝成功（epoch 印到 stdout）；1＝兩路都失敗，呼叫端必須視為暫態
# read race（例如 Anya 剛好在 mv 建檔那一瞬間），本輪 skip，不可當 0 用
# （d7e2 事故：c2d1 剛建檔即被掃到，created_at 空+stat 也失敗，舊版兩路都
# 失敗時靜默回傳空字串，caller 算術把空字串當 0，age=now-0≈56 年，誤報
# 巨大假年齡的無主告警）。
get_created_epoch() {
  local f="$1" created
  created=$(jq -r '(.created_at // empty)' "$f" 2>/dev/null)
  if [[ -n "$created" ]] && iso_to_epoch "$created" >/dev/null 2>&1; then
    iso_to_epoch "$created"
    return 0
  fi
  local mtime
  mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  if [[ -n "$mtime" ]]; then
    echo "$mtime"
    return 0
  fi
  return 1
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

# 持久 event sequence：同一 action 每成功留下一筆 history 就遞增。
# 這是 relay filename 的事件身分，attempt/nudge_count 則仍只表示當前
# retry/staleness 週期內的預算。relay 寫入後、history append 前 crash 時
# 會重算出同一序號，保留 no-clobber 的幂等性。
get_next_cron_action_seq() {
  local f="$1" action="$2" seq
  seq=$(jq -r --arg action "$action" '
    [.history // [] | .[] |
      select(.by == "fatq-dispatch-cron" and .action == $action)
    ] | length + 1
  ' "$f" 2>/dev/null) || return 1
  [[ "$seq" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$seq"
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

# ── history append（crash-safe：stable task lock 包住 read-modify-rename） ──
# 不鎖 task inode 本身：atomic rename 會替換 inode，後來的 claim 可能鎖到新
# inode，讓兩邊誤以為互斥。鎖檔以 task basename 為 key，跨 state 目錄維持
# 同一把鎖；不同 task 仍可完全平行，不造成 dispatch 全域串行化。
task_lock_file_for() {
  local task_file="$1" lock_dir task_name
  lock_dir="${FATQ_ROOT}/.locks"
  task_name="$(basename "$task_file" .json)"
  mkdir -p "$lock_dir" 2>/dev/null || return 1
  printf '%s/%s.lock\n' "$lock_dir" "$task_name"
}

# 回傳 0＝成功寫入；1＝檔案在讀寫之間消失（已被 mv 走，呼叫端應 skip:moved）
append_history_locked() {
  local task_file="$1" entry_json="$2"
  local lock_fd lock_file

  if [[ "$FATQ_DRY_RUN" == "1" ]]; then
    return 0
  fi

  lock_file="$(task_lock_file_for "$task_file")" || return 1
  exec {lock_fd}>"$lock_file" 2>/dev/null || return 1
  flock -x "$lock_fd" || {
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  }

  if [[ ! -e "$task_file" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi

  local dir tmp source_identity current_identity
  source_identity="$(stat -Lc '%d:%i' "$task_file" 2>/dev/null)" || {
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  }
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-dispatch.XXXXXX")"
  if ! jq --argjson entry "$entry_json" '.history = ((.history // []) + [$entry])' "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi
  current_identity="$(stat -Lc '%d:%i' "$task_file" 2>/dev/null)" || current_identity=""
  if [[ "$current_identity" != "$source_identity" ]]; then
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi
  mv -f "$tmp" "$task_file"

  flock -u "$lock_fd"
  exec {lock_fd}>&- 2>/dev/null || true
  return 0
}

# Append a cron action at most once. The check and append share the stable task
# lock, so concurrent dispatcher scans cannot create duplicate completion
# markers.
append_history_action_once_locked() {
  local task_file="$1" action="$2" entry_json="$3"
  local lock_fd lock_file dir tmp source_identity current_identity

  [[ "$FATQ_DRY_RUN" == "1" ]] && return 0
  lock_file="$(task_lock_file_for "$task_file")" || return 1
  exec {lock_fd}>"$lock_file" 2>/dev/null || return 1
  flock -x "$lock_fd" || {
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  }
  if [[ ! -e "$task_file" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi
  if jq -e --arg action "$action" \
      'any(.history // [] | .[]; .action == $action)' "$task_file" >/dev/null 2>&1; then
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 0
  fi
  source_identity="$(stat -Lc '%d:%i' "$task_file" 2>/dev/null)" || {
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  }
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-dispatch.XXXXXX")"
  if ! jq --argjson entry "$entry_json" \
      '.history = ((.history // []) + [$entry])' "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi
  current_identity="$(stat -Lc '%d:%i' "$task_file" 2>/dev/null)" || current_identity=""
  if [[ "$current_identity" != "$source_identity" ]]; then
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi
  mv -f "$tmp" "$task_file"
  flock -u "$lock_fd"
  exec {lock_fd}>&- 2>/dev/null || true
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

task_current_path_matches() {
  local task_file="$1" task_id current_path wanted_path
  [[ -f "$task_file" ]] || return 1
  task_id="$(get_task_id "$task_file")"
  [[ -n "$task_id" && "$task_id" != "null" ]] || return 1
  wanted_path="$(readlink -f "$task_file" 2>/dev/null || printf '%s' "$task_file")"
  current_path="$(find "$FATQ_ROOT" -mindepth 2 -maxdepth 2 -type f -name "${task_id}.json" -print 2>/dev/null | head -1)"
  [[ -n "$current_path" ]] || return 1
  current_path="$(readlink -f "$current_path" 2>/dev/null || printf '%s' "$current_path")"
  [[ "$current_path" == "$wanted_path" ]]
}

# ── 原子派送（e4c8 builder_fix，Bella 22:17:27/22:18:47 同 relay 檔重複派工事故）
# 舊順序是「先 append history、再搶 relay 檔名」：append_history_locked 本身雖靠
# flock 保證單次寫入原子，但兩個併發觸發源（fatq-watch 的 inotify 喚醒＋週期 cron）
# 各自讀到「尚未派過」都會各自組出 attempt=1 的 entry 並各自呼叫 append，flock 只
# 序列化寫入順序、不阻止兩筆語意重複的 entry 都寫入成功——history 真的被寫兩筆
# （relay 檔名的 ln no-clobber 去重只擋到第二次 TG 通知，擋不到 history 重複）。
# 修法：把唯一真正跨行程原子的操作（ln no-clobber 搶檔名）挪到最前面當關卡，
# 贏了才寫 history；輸了直接放棄，不再讓 history 也留一筆重複紀錄。
# 回傳：0＝贏得派送且 history 已寫入；1＝併發輸家（relay 檔名已被搶走，非錯誤，
#       不動 history）；2＝贏得派送但 task 檔案在寫 history 前已被 mv 走（極短暫
#       窗口，relay 通知已送出，history 記錄以下次掃描補上或視為可接受落差）。
dispatch_send() {
  local task_file="$1" relay_file="$2" relay_content="$3" history_entry="$4"
  if ! task_current_path_matches "$task_file"; then
    return 2
  fi
  if ! write_relay_atomic "$relay_file" "$relay_content"; then
    return 1
  fi
  if ! append_history_locked "$task_file" "$history_entry"; then
    return 2
  fi
  return 0
}

audit_nudge_skip_once_daily() {
  local task_id="$1" reason="$2" detail="${3:-}"
  local day audit_file lock_file key line lock_fd
  day="$(today_key)"
  audit_file="$FATQ_STATE_DIR/nudge-skip-audit-${day}.log"
  lock_file="$audit_file.lock"
  key="${day} task=${task_id} reason=${reason}"
  line="${key} detail=${detail}"

  log_line "audit:nudge_skip $line"
  [[ "$FATQ_DRY_RUN" == "1" ]] && return 0

  mkdir -p "$FATQ_STATE_DIR" 2>/dev/null || return 0
  exec {lock_fd}>>"$lock_file" 2>/dev/null || return 0
  flock -x "$lock_fd" 2>/dev/null || true
  if [[ ! -f "$audit_file" ]] || ! grep -Fq "$key" "$audit_file" 2>/dev/null; then
    printf '%s\n' "$line" >>"$audit_file" 2>/dev/null || true
  fi
  flock -u "$lock_fd" 2>/dev/null || true
  exec {lock_fd}>&- 2>/dev/null || true
}

is_blocked_on_external() {
  local f="$1" last_action
  last_action=$(jq -r '(.history // [] | last | .action // empty)' "$f" 2>/dev/null)
  [[ "$last_action" == "blocked" ]] || return 1

  local haystack
  haystack=$(jq -r '
    [
      (.blocked_on // empty),
      (.last_run_summary // empty),
      (.lessons_learned // empty),
      (.history // [] | last | .note // empty),
      (.history // [] | last | .reason // empty),
      (.history // [] | last | .comment // empty),
      (.history // [] | last | .blocker // empty)
    ] | map(tostring) | join(" ")
  ' "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')

  [[ "$haystack" =~ (external|blocked-on-external|credential|credentials|manual|human|operator|production-runner|production\ runner|prod-runner|prod\ runner|runner|network|no\ network|sandbox|approval|access|secret|token|cloudflare|gcp|人工|憑證|凭证|外部|無網路|无网络|沙箱|權限|权限|登入|登录) ]]
}

count_cron_nudges_today() {
  local f="$1" day
  day="$(today_key)"
  jq -r --arg day "$day" '
    [ .history // [] | .[] |
      select(.by=="fatq-dispatch-cron" and .action=="nudge") |
      select((.ts // "") | startswith($day))
    ] | length
  ' "$f" 2>/dev/null
}

# ── 建構派工/催工/升級的 relay JSON 內容 ───────────────────────────────────
build_relay_json() {
  local recipient="$1" text="$2" task_id="$3"
  jq -n --arg from "fatq-dispatch-cron" --arg recipient "$recipient" --arg text "$text" \
        --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot: $from, recipient: $recipient, text: $text, ts: $ts, fatq_task_id: $tid}'
}

latest_active_blocked_event_json() {
  local f="$1"
  jq -c '([.history // [] | to_entries[] | select(.value.by != "fatq-dispatch-cron")] | last // empty) | select(.value.action == "blocked") | {idx: .key, ts: (.value.ts // ""), diagnostic: ([(.value.note // empty), (.value.reason // empty), (.value.comment // empty), (.value.blocker // empty), (.value.summary // empty), (.value.message // empty)] | map(tostring) | join(" "))}' "$f" 2>/dev/null
}

handle_blocked_stall_notify() {
  local task_file="$1" task_id event event_idx event_ts event_epoch age diagnostic
  task_id=$(get_task_id "$task_file")
  event=$(latest_active_blocked_event_json "$task_file")
  [[ -n "$event" && "$event" != "null" ]] || return 1
  event_idx=$(jq -r '.idx' <<<"$event" 2>/dev/null)
  event_ts=$(jq -r '.ts' <<<"$event" 2>/dev/null)
  if ! event_epoch=$(iso_to_epoch "$event_ts"); then log_decision "$task_id" "skip:blocked_bad_timestamp"; return 0; fi
  age=$(( $(now_epoch) - event_epoch ))
  if [[ "$age" -lt "$FATQ_BLOCKED_ALERT_SECS" ]]; then log_decision "$task_id" "skip:blocked_alert_not_due"; return 0; fi
  if is_blocked_on_external "$task_file"; then log_decision "$task_id" "skip:blocked_on_external"; return 1; fi
  local already_notified
  already_notified=$(jq -r --argjson idx "$event_idx" '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="blocked_stalled_alert" and (.blocked_index // -1) == $idx)] | length' "$task_file" 2>/dev/null)
  if [[ "${already_notified:-0}" != "0" ]]; then log_decision "$task_id" "skip:blocked_alert_already_notified"; return 0; fi
  diagnostic=$(jq -r '.diagnostic' <<<"$event" 2>/dev/null | tr '\n' ' ' | cut -c1-240)
  [[ -n "$diagnostic" ]] || diagnostic="未提供 blocker 說明。"
  local minutes=$(( age / 60 )) text content relay_file entry
  text="[FATQ BLOCKED STALL] 任務 ${task_id} 最後一筆 action=blocked 已 ${minutes} 分鐘，尚無後續活動。\n診斷：${diagnostic}\n任務檔：${task_file}\n@Anyachl_bot 請依診斷協調解除。"
  content=$(build_relay_json "anya" "$text" "$task_id")
  relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-b${event_idx}-blocked-stall.json"
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson idx "$event_idx" --arg diagnostic "$diagnostic" '{ts: $ts, by: "fatq-dispatch-cron", action: "blocked_stalled_alert", relay_file: $relay, target: "anya", blocked_index: $idx, diagnostic: $diagnostic}')
  if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
    log_decision "$task_id" "blocked_stalled_alert"; N_NUDGED=$((N_NUDGED+1))
  else
    local dsrc=$?; [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "blocked_stalled_alert:lost_race" || log_decision "$task_id" "skip:moved"; N_SKIPPED=$((N_SKIPPED+1))
  fi
  return 0
}

# assigned/reviewer 查無可投遞的 structured recipient 時 fail closed：不產生
# 「已指派給你」派工檔，改寫一筆可稽核 history 並通知建單者。這同時涵蓋
# lookup 失敗與歷史 BOT_MAP 中 recipient 為空的壞映射。
handle_unmapped_dispatch_target() {
  local task_file="$1" raw_name="$2" task_id phase created_by
  task_id=$(get_task_id "$task_file")
  phase=$(task_phase "$task_file")
  created_by=$(jq -r '(.created_by // "")' "$task_file" 2>/dev/null)

  log_line "AUDIT dispatch_target_unmapped task=$task_id phase=$phase target=$raw_name created_by=${created_by:-unknown}"

  local already_alerted
  already_alerted=$(jq -r --arg target "$raw_name" --arg phase "$phase" '
    [.history // [] | .[] |
      select(.by=="fatq-dispatch-cron" and .action=="dispatch_target_unmapped") |
      select((.target // "") == $target and (.phase // "") == $phase)] | length
  ' "$task_file" 2>/dev/null)
  if [[ "${already_alerted:-0}" != "0" ]]; then
    log_decision "$task_id" "skip:unmapped_target_already_alerted"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local creator_mapped="" creator_recipient=""
  if [[ -n "$created_by" ]] && creator_mapped=$(lookup_bot "$created_by"); then
    creator_recipient="${creator_mapped%%|*}"
  fi

  local text="[FATQ 派工異常] 任務 ${task_id} 的指派對象 '${raw_name}' 查無可投遞 bot，已停止派工，未產生空 recipient 通知。\n任務檔：${task_file}\n建單者 ${created_by:-unknown} 請重新指派到有效執行 bot。"
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg target "$raw_name" --arg phase "$phase" \
    --arg creator "${created_by:-}" --arg notified "${creator_recipient:-mattermost_fallback}" \
    '{ts:$ts,by:"fatq-dispatch-cron",action:"dispatch_target_unmapped",target:$target,phase:$phase,created_by:$creator,notified:$notified}')

  if [[ -n "$creator_recipient" ]]; then
    local event_seq relay_file content
    if ! event_seq=$(get_next_cron_action_seq "$task_file" "dispatch_target_unmapped"); then
      log_decision "$task_id" "skip:unmapped_target_seq_error"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    relay_file="fatq-$(task_hex_id "$task_id")-${phase}-e${event_seq}-a1-unmapped-target.json"
    content=$(build_relay_json "$creator_recipient" "$text" "$task_id")
    if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
      log_decision "$task_id" "alert:unmapped_target_creator=$creator_recipient"
    else
      local dsrc=$?
      [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "alert:unmapped_target_lost_race" || log_decision "$task_id" "skip:moved"
    fi
  else
    alert_mattermost "${text} @Anyachl_bot"
    append_history_locked "$task_file" "$entry" || true
    log_decision "$task_id" "alert:unmapped_target_mattermost_fallback"
  fi
  N_SKIPPED=$((N_SKIPPED+1))
}

# Creation integrity is enforced at the dispatch convergence point. A task is
# dispatchable only when the reviewer is materialized in the task and history
# proves it was created by fatq-cli. The cron never repairs either field.
creation_gate_defects() {
  local task_file="$1"
  jq -r '
    [
      (if ((.reviewer // "") | type) != "string" or ((.reviewer // "") | length) == 0
       then "missing_reviewer" else empty end),
      (if any((.history // [])[]?;
              (.action // "") == "create" and (.via // "") == "fatq-cli")
       then empty else "missing_fatq_cli_create" end)
    ] | join(",")
  ' "$task_file" 2>/dev/null
}

handle_creation_gate_failure() {
  local task_file="$1" defects="$2" task_id phase created_by
  task_id=$(get_task_id "$task_file")
  phase=$(task_phase "$task_file")
  created_by=$(jq -r '(.created_by // "")' "$task_file" 2>/dev/null)

  log_line "AUDIT creation_gate_failed task=$task_id phase=$phase defects=$defects created_by=${created_by:-unknown}"

  local already_alerted
  already_alerted=$(jq -r --arg defects "$defects" '
    [.history // [] | .[] |
      select(.by=="fatq-dispatch-cron" and .action=="creation_gate_failed") |
      select((.defects // "") == $defects)] | length
  ' "$task_file" 2>/dev/null)
  if [[ "${already_alerted:-0}" != "0" ]]; then
    log_decision "$task_id" "skip:creation_gate_already_alerted"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local creator_mapped="" creator_recipient=""
  if [[ -n "$created_by" ]] && creator_mapped=$(lookup_bot "$created_by"); then
    creator_recipient="${creator_mapped%%|*}"
  fi

  local text="[FATQ 建單守門] 任務 ${task_id} 結構不合格（${defects}），已 fail-closed 停止派工。\n任務檔：${task_file}\n建單者 ${created_by:-unknown} 請用 fatq-cli 修復／重建；禁止手寫 JSON。"
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg defects "$defects" --arg phase "$phase" \
    --arg creator "${created_by:-}" --arg notified "${creator_recipient:-mattermost_fallback}" \
    '{ts:$ts,by:"fatq-dispatch-cron",action:"creation_gate_failed",defects:$defects,phase:$phase,created_by:$creator,notified:$notified}')

  if [[ -n "$creator_recipient" ]]; then
    local event_seq relay_file content
    if ! event_seq=$(get_next_cron_action_seq "$task_file" "creation_gate_failed"); then
      log_decision "$task_id" "skip:creation_gate_seq_error"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    relay_file="fatq-$(task_hex_id "$task_id")-${phase}-e${event_seq}-a1-create-gate.json"
    content=$(build_relay_json "$creator_recipient" "$text" "$task_id")
    if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
      log_decision "$task_id" "alert:creation_gate_creator=$creator_recipient"
    else
      local dsrc=$?
      [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "alert:creation_gate_lost_race" || log_decision "$task_id" "skip:moved"
    fi
  else
    alert_mattermost "${text} @Anyachl_bot"
    append_history_locked "$task_file" "$entry" || true
    log_decision "$task_id" "alert:creation_gate_mattermost_fallback"
  fi
  N_SKIPPED=$((N_SKIPPED+1))
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

    # 該 dispatch 之後有沒有非 cron 活動？pending/rejected 用它重開
    # builder 的首派週期；review 系列則只有 dispatch target 本人的
    # 活動算 ack，第三方 comment 不得清掉 TTL/attempt 預算。
    local activity_after
    activity_after=$(jq -r --argjson idx "$d_idx" '
      [.history // [] | to_entries[] | select(.key > $idx and .value.by != "fatq-dispatch-cron")] | length
    ' "$task_file" 2>/dev/null)

    local dispatch_phase
    dispatch_phase=$(task_phase "$task_file")
    case "$dispatch_phase" in
      review|design_review|spec_review)
        # 上一筆若是 pending/rejected 的 dispatch，代表剛轉入新的
        # review phase；必須立即首派 reviewer，不能沿用 builder TTL。
        if [[ "$d_relay" == *"-${dispatch_phase}-"* ]]; then
          local review_reentry_after phase_dir continue_review_dispatch
          phase_dir="${dispatch_phase}/"
          review_reentry_after=$(jq -r --argjson idx "$d_idx" --arg phase_dir "$phase_dir" '
            [.history // [] | to_entries[] |
              select(.key > $idx and (.value.to // "") == $phase_dir)] | length
          ' "$task_file" 2>/dev/null)
          if [[ "${review_reentry_after:-0}" -gt 0 ]]; then
            # reject/resubmit 已開始新的 review cycle，上一輪 reviewer
            # 的 verdict/comment 不能 ack 這一輪尚未發送的請審。
            activity_after=1
            continue_review_dispatch=1
          else
            continue_review_dispatch=0
          fi
          local target_activity_after
          target_activity_after=$(jq -r --argjson idx "$d_idx" --arg target "$recipient" '
            [.history // [] | to_entries[] |
              select(.key > $idx and .value.by != "fatq-dispatch-cron" and .value.by == $target)] | length
          ' "$task_file" 2>/dev/null)
          if [[ "$continue_review_dispatch" -eq 0 && "${target_activity_after:-0}" -gt 0 ]]; then
            log_decision "$task_id" "skip:acked"
            N_SKIPPED=$((N_SKIPPED+1))
            return 0
          fi
          # reviewer 還沒 ack：第三方活動視為與 dispatch 無關，繼續用
          # 原 dispatch 的 TTL 與 attempt，不走下方 builder 重置分支。
          if [[ "$continue_review_dispatch" -eq 0 ]]; then
            activity_after=0
          fi
        else
          activity_after=1
        fi
        ;;
    esac

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
        local esc_seq
        if ! esc_seq=$(get_next_cron_action_seq "$task_file" "escalate"); then
          log_decision "$task_id" "skip:transient_read"
          N_SKIPPED=$((N_SKIPPED+1))
          return 0
        fi
        local esc_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${esc_seq}-a${d_attempt}-escalate.json"
        local esc_text="[FATQ 升級] 任務 ${task_id} 已重派 ${d_attempt} 次仍無 assignee 活動，達重派上限 ${FATQ_MAX_DISPATCH}，停止自動重派。任務檔：${task_file}\n@Anyachl_bot 請人工介入。"
        local esc_content
        esc_content=$(build_relay_json "anya" "$esc_text" "$task_id")
        local esc_entry
        esc_entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$esc_relay" --arg target "$recipient" --argjson attempt "$d_attempt" \
          '{ts: $ts, by: "fatq-dispatch-cron", action: "escalate", relay_file: $relay, target: $target, attempt: $attempt}')
        # e6a8：dispatch_send 內部的存在檢查發生在 write_relay_atomic 之後——
        # relay 檔（真正觸發 TG 通知那個）已經送出去了才檢查，太晚。這裡在
        # 「送」之前就先確認任務還在原本掃到它的那個目錄，不然 Bella 會收到
        # 已經 done/rejected 的單的過期「請審」通知（她親身回報這個 bug）。
        if [[ ! -f "$task_file" ]]; then
          log_decision "$task_id" "skip:left_state"
          N_SKIPPED=$((N_SKIPPED+1))
          return 0
        fi
        if dispatch_send "$task_file" "$esc_relay" "$esc_content" "$esc_entry"; then
          log_decision "$task_id" "escalate"
          N_ESCALATED=$((N_ESCALATED+1))
        else
          local dsrc=$?
          [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "escalate:lost_race" || log_decision "$task_id" "skip:moved"
          N_SKIPPED=$((N_SKIPPED+1))
        fi
        return 0
      fi
    fi
  fi

  # 走到這裡＝首派或允許中的重派，attempt 已定。review 與
  # rejected 可能在同一任務生命週期內再次進入；上方 builder
  # activity 會正確將 attempt 重算為 1，但舊的 phase-a1 已在 gateway
  # read archive 裡，再用同名會被 relay-dedup 當成重送而靜默丟棄。
  # 因此所有 phase 檔名都加入由 task history 持久推導的
  # dispatch sequence。pending 通常只進入一次，但仍可能因 comment 等
  # 非 cron 活動使 attempt 在同目錄內重算為 1，所以也必須納入。
  #   * 真正 resubmit 前已多了狀態轉移/history，sequence 必然增加；
  #   * crash 發生在 relay 寫入後、history append 前時，重跑仍取得同一
  #     sequence，保留原本 no-clobber/read-archive 的冪等防重語義。
  local phase relay_file dispatch_seq
  phase=$(task_phase "$task_file")
  if ! dispatch_seq=$(get_next_cron_action_seq "$task_file" "dispatch"); then
    # 無法從持久狀態取得 sequence 時不可降級回 d1，否則正好
    # 會復活本案的 read-archive 撞名。當作瞬時讀取失敗，下輪重試。
    log_decision "$task_id" "skip:transient_read"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  relay_file="fatq-$(task_hex_id "$task_id")-${phase}-d${dispatch_seq}-a${attempt}-dispatch.json"
  local relay_content
  relay_content=$(build_relay_json "$recipient" "$text" "$task_id")

  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --arg target "$recipient" \
    --argjson attempt "$attempt" --argjson dispatch_seq "$dispatch_seq" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "dispatch", relay_file: $relay, target: $target, attempt: $attempt, dispatch_seq: $dispatch_seq}')

  # e6a8：跟上面 escalate 分支同理——dispatch_send 的存在檢查在 write_relay_atomic
  # 之後才發生，relay 都送出去了才發現任務已經離開來源目錄（review 審完移
  # done/rejected 是最常見情境）太晚，Bella 已經收到過期「請審」通知了。
  if [[ ! -f "$task_file" ]]; then
    log_decision "$task_id" "skip:left_state"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  # 寫入順序（e4c8 builder_fix）：relay 檔名 ln no-clobber 才是唯一跨行程真原子的
  # 關卡，先搶它；贏了才寫 history。輸了直接放棄，不讓 history 也留重複一筆
  # （22:17:27/22:18:47 事故：舊順序先 append history 再搶 relay，兩個併發觸發源
  # 各自都在 history 寫入一筆 attempt=1，relay 檔名去重只擋到重複 TG 通知）。
  if dispatch_send "$task_file" "$relay_file" "$relay_content" "$entry"; then
    log_decision "$task_id" "dispatch"
    N_DISPATCHED=$((N_DISPATCHED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "dispatch:lost_race" || log_decision "$task_id" "skip:moved"
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

  if is_blocked_on_external "$task_file"; then
    log_decision "$task_id" "skip:blocked_on_external"
    audit_nudge_skip_once_daily "$task_id" "blocked_on_external" "last_history_action=blocked"
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
    local esc_seq
    if ! esc_seq=$(get_next_cron_action_seq "$task_file" "escalate"); then
      log_decision "$task_id" "skip:transient_read"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    local esc_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${esc_seq}-a$((nudge_count+1))-escalate.json"
    local esc_text="[FATQ 升級] 任務 ${task_id} 已催 ${nudge_count} 次無回應（最後活動 $(TZ='Asia/Taipei' date -d "@$basis_epoch" '+%Y-%m-%d %H:%M') +08:00），assigned=${recipient}。任務檔：${task_file}\n@Anyachl_bot 請人工介入。"
    local esc_content
    esc_content=$(build_relay_json "anya" "$esc_text" "$task_id")
    local esc_entry
    esc_entry=$(jq -n --arg ts "$(now_iso)" --argjson n "$nudge_count" --arg target "$recipient" \
      '{ts: $ts, by: "fatq-dispatch-cron", action: "escalate", target: $target, nudge_count: $n}')
    if dispatch_send "$task_file" "$esc_relay" "$esc_content" "$esc_entry"; then
      log_decision "$task_id" "escalate"
      N_ESCALATED=$((N_ESCALATED+1))
    else
      local dsrc=$?
      [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "escalate:lost_race" || log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
    fi
    return 0
  fi

  local nudges_today
  nudges_today=$(count_cron_nudges_today "$task_file")
  if [[ "$nudges_today" -ge "$FATQ_DAILY_NUDGE_LIMIT" ]]; then
    log_decision "$task_id" "skip:daily_nudge_limit"
    audit_nudge_skip_once_daily "$task_id" "daily_nudge_limit" "nudges_today=${nudges_today} limit=${FATQ_DAILY_NUDGE_LIMIT}"
    N_SKIPPED=$((N_SKIPPED+1))
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
  local nudge_seq
  if ! nudge_seq=$(get_next_cron_action_seq "$task_file" "nudge"); then
    log_decision "$task_id" "skip:transient_read"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  local nudge_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${nudge_seq}-a${next_n}-nudge.json"
  local nudge_text="[FATQ 催工] 任務 ${task_id} ${verb}已 $((age/60)) 分鐘無新進度（第 ${next_n}/${FATQ_MAX_NUDGES} 次提醒）。任務檔：${task_file}\n完成後先跑 shared/bin/fatq-verify.sh 全過再 mv 狀態。"
  if jq -e '[.history // [] | .[] | select(.action=="spec_staleness_notified")] | length > 0' "$task_file" >/dev/null 2>&1; then
    nudge_text="${nudge_text}\n⚠ spec 已變更，請先重讀任務檔最新 goal/context/acceptance_criteria/deliverables/out_of_scope。"
  fi
  local nudge_content
  nudge_content=$(build_relay_json "$recipient" "$nudge_text" "$task_id")
  local nudge_entry
  nudge_entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$nudge_relay" --arg target "$recipient" --argjson event_seq "$nudge_seq" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "nudge", relay_file: $relay, target: $target, event_seq: $event_seq}')

  if dispatch_send "$task_file" "$nudge_relay" "$nudge_content" "$nudge_entry"; then
    log_decision "$task_id" "nudge"
    N_NUDGED=$((N_NUDGED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "nudge:lost_race" || log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# in_progress/ 授權紅線即時通知（b8e8，老兔 2026-07-16 核准）
#
# Builder 若已把可做的工作做完，但因 production/shared 權限紅線只能等 Anya 或
# 授權維護者套 patch / 執行生產動作，history 需留下以 [BLOCKED-AUTH] 開頭的
# blocked/comment。dispatch 下一輪看到後即時寫 relay 給 Anya，不等 2h nudge。
# 去重鍵存在 task history：同一 blocked event index 只通知一次；同任務若新增
# 另一筆 [BLOCKED-AUTH] history，index 變大，會再次通知。
# ══════════════════════════════════════════════════════════════════════════
latest_blocked_auth_event_json() {
  local f="$1"
  jq -c '
    def marker_text:
      [
        (.note // empty),
        (.comment // empty),
        (.reason // empty),
        (.blocker // empty),
        (.summary // empty),
        (.message // empty)
      ]
      | map(tostring)
      | map(select(startswith("[BLOCKED-AUTH]")))
      | first // empty;

    [.history // [] | to_entries[]
      | . as $entry
      | (($entry.value | marker_text) // empty) as $text
      | select($text != "")
      | {idx: $entry.key, text: $text, action: ($entry.value.action // "")}]
    | last // empty
  ' "$f" 2>/dev/null
}

handle_blocked_auth_notify() {
  local task_file="$1"
  local task_id event event_idx need_line
  task_id=$(get_task_id "$task_file")
  event=$(latest_blocked_auth_event_json "$task_file")
  if [[ -z "$event" || "$event" == "null" ]]; then
    return 1
  fi

  event_idx=$(jq -r '.idx' <<< "$event" 2>/dev/null)
  need_line=$(jq -r '.text' <<< "$event" 2>/dev/null | sed -e 's/^\[BLOCKED-AUTH\][[:space:]]*//' -e 's/[[:cntrl:]]/ /g' | cut -c1-240)
  [[ -z "$need_line" ]] && need_line="需要 Anya/授權維護者介入解除授權紅線。"

  local already_notified
  already_notified=$(jq -r --argjson idx "$event_idx" '
    [.history // [] | .[]
      | select(.by=="fatq-dispatch-cron" and .action=="blocked_auth_notified" and (.blocked_auth_index // -1) == $idx)]
    | length
  ' "$task_file" 2>/dev/null)
  if [[ "${already_notified:-0}" != "0" ]]; then
    log_decision "$task_id" "skip:blocked_auth_already_notified"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local text content relay_file entry
  text="[FATQ BLOCKED-AUTH] 任務 ${task_id} 卡在授權紅線，需要 Anya/授權維護者介入。\n需求：${need_line}\n任務檔：${task_file}\n@Anyachl_bot"
  content=$(build_relay_json "anya" "$text" "$task_id")
  relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-ba${event_idx}-blocked-auth.json"
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson idx "$event_idx" --arg need "$need_line" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "blocked_auth_notified", relay_file: $relay, target: "anya", blocked_auth_index: $idx, need: $need}')

  if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
    log_decision "$task_id" "blocked_auth_notified"
    N_NUDGED=$((N_NUDGED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "blocked_auth_notified:lost_race" || log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
  return 0
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
  if ! created=$(get_created_epoch "$task_file"); then
    log_decision "$task_id" "skip:transient_read"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
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

  # 軟親和建議（org-design #2，d5c3）：只是「建議」附在文案裡供 Anya 參考，
  # 不代寫 assigned 欄位——欄位仍是空的，真正指派要靠 Anya 執行
  # `fatq reassign <task_id> --as anya --to <X>`，CLI 寫入欄位後 builder
  # 才可能 claim 成功（矩陣紅線下沒有「不寫欄位就能派工」的合法路徑，
  # Bella QA REJECT 實測抓到：直接拿親和預設當 assigned 派工，relay 收件人
  # claim 時會被 claim_locked 的 assigned==identity 檢查擋下 E_PERM）。
  local affinity_suggestion suggestion_line=""
  affinity_suggestion=$(get_affinity_default "$task_file" "builder")
  if [[ -n "$affinity_suggestion" ]]; then
    suggestion_line="\n依線親和建議指派 ${affinity_suggestion}：fatq reassign ${task_id} --as anya --to ${affinity_suggestion}"
  fi
  # §3.5 寫入當下重讀原則（d7e2）：從函式一開頭判定「無主」到這裡，中間經過
  # cooldown 查詢、親和查表——這段時間足夠讓任務被指派或被移出 pending。真的
  # 要送告警前用當下狀態再驗一次，不要沿用開頭那份可能已經過期的判斷。
  if [[ ! -f "$task_file" ]]; then
    log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  local recheck_assigned
  recheck_assigned=$(get_assigned "$task_file")
  if [[ -n "$recheck_assigned" ]]; then
    log_decision "$task_id" "skip:no_longer_unassigned"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local event_seq
  if ! event_seq=$(get_next_cron_action_seq "$task_file" "unassigned_alert"); then
    log_decision "$task_id" "skip:transient_read"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  local text="[FATQ 無主任務] ${task_id} 進 pending 已 $((age/60)) 分鐘仍無 assigned/assigned_to。任務檔：${task_file}${suggestion_line}\n@Anyachl_bot 請指派。"
  local content
  content=$(build_relay_json "anya" "$text" "$task_id")
  local relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${event_seq}-a1-unassigned.json"
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson event_seq "$event_seq" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "unassigned_alert", relay_file: $relay, event_seq: $event_seq}')

  if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
    log_decision "$task_id" "unassigned_alert"
    N_NUDGED=$((N_NUDGED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "unassigned_alert:lost_race" || log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# done/ 完成通知（f9c3，老兔 2026-07-08 診斷）
#
# 根因：派工系統原本通知 builder(派活)/reviewer(派審)/停滯(nudge)/無主(alert)，
# 唯獨任務真的完成（verdict_approve→done/）時沒有機制通知調度者，才讓 Anya
# 得靠手動查任務詳情才知道早就完成、時間差因此產生。
#
# 冪等：history 記一筆 completion_notified 標記防重發（同 unassigned_alert 節流
# 手法，只是這裡不是節流重提醒、而是「只發一次，發過就不再發」）。
#
# ⚠️回溯轟炸防呆（deliverable 明講）：這支 rule 上線那一刻，done/ 目錄裡本來就
# 堆了大量早就完成、只是沒有 completion_notified 標記的舊任務——如果照樣當「新
# 完成」處理，第一輪掃描會把歷史堆積全部轟炸出去，這比完全沒有這個功能還糟。
# 用一個一次性 state marker（completion_notify_seeded）分辨「這是這支 rule 第
# 一次真的跑」：第一次跑到的所有 done/ 任務只補標記、不發 relay（歷史庫存視為
# 已知）；state marker 建立後，之後每一輪看到的「done+verdict_approve 但無
# completion_notified」才是貨真價實的新完成，才真的發通知。marker 建立時機在
# 整個目錄跑完之後才寫，中途被打斷不會有「一半歷史被通知、一半沒被通知」的
# 不一致——沒寫 marker 前，任何一輪重跑都還是「補標記模式」，安全且冪等。
completion_leg_marked() {
  local task_file="$1" action="$2"
  jq -e --arg action "$action" \
    'any(.history // [] | .[]; .action == $action)' "$task_file" >/dev/null 2>&1
}

# Deterministic relay + independent history marker. A relay that survived a
# crash before its marker is backfilled without emitting a duplicate.
send_completion_leg() {
  local task_file="$1" relay_file="$2" content="$3" action="$4"
  completion_leg_marked "$task_file" "$action" && return 0
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg action "$action" --arg relay "$relay_file" \
    '{ts:$ts, by:"fatq-dispatch-cron", action:$action, relay_file:$relay}')
  if relay_file_exists "$relay_file"; then
    append_history_action_once_locked "$task_file" "$action" "$entry"
    return $?
  fi
  if write_relay_atomic "$relay_file" "$content"; then
    append_history_action_once_locked "$task_file" "$action" "$entry"
    return $?
  fi
  if relay_file_exists "$relay_file"; then
    append_history_action_once_locked "$task_file" "$action" "$entry"
    return $?
  fi
  return 1
}

structured_artifact_lines() {
  local task_file="$1" assets_prefix="${FATQ_ROOT%/}/assets/"
  jq -r --arg prefix "$assets_prefix" '
    [(.artifacts // empty) | .. | strings | select(startswith($prefix))]
    | unique | sort | .[] | "- " + .
  ' "$task_file" 2>/dev/null
}

handle_completion_notify() {
  local task_file="$1" seeding="$2"
  local task_id
  task_id=$(get_task_id "$task_file")

  # Legacy aggregate markers remain authoritative and are never replayed.
  if completion_leg_marked "$task_file" "completion_notified"; then
    log_decision "$task_id" "skip:completion_already_notified"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local verdict_entry
  verdict_entry=$(jq -c '[.history // [] | .[] | select(.action=="verdict_approve")] | last // empty' "$task_file" 2>/dev/null)
  if [[ -z "$verdict_entry" || "$verdict_entry" == "null" ]]; then
    log_decision "$task_id" "skip:no_verdict_approve"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  if [[ "$seeding" == "1" ]]; then
    local seed_entry
    seed_entry=$(jq -n --arg ts "$(now_iso)" \
      '{ts:$ts, by:"fatq-dispatch-cron", action:"completion_notified", note:"backfill_seed_no_relay"}')
    if append_history_action_once_locked "$task_file" "completion_notified" "$seed_entry"; then
      log_decision "$task_id" "completion_notify:seeded_no_relay"
    else
      log_decision "$task_id" "skip:seed_write_failed"
    fi
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local slug reviewer verdict_by verdict_ts verdict_summary created_by raw_deliver_to effective_deliver_to
  slug=$(jq -r '.slug // .task_id' "$task_file" 2>/dev/null)
  reviewer=$(jq -r '.reviewer // ""' "$task_file" 2>/dev/null)
  verdict_by=$(jq -r '.by // ""' <<< "$verdict_entry" 2>/dev/null)
  verdict_ts=$(jq -r '.ts // ""' <<< "$verdict_entry" 2>/dev/null)
  verdict_summary=$(jq -r --argjson verdict "$verdict_entry" '
    [
      ($verdict.reason?),
      ($verdict.note?),
      (.review.reason?),
      (.review.note?)
    ]
    | map(select(. != null and (tostring | length > 0)))
    | first // "<未填>"
    | tostring
    | gsub("[\r\n]+"; " ")
    | .[0:100]
  ' "$task_file" 2>/dev/null)
  created_by=$(jq -r '.created_by // ""' "$task_file" 2>/dev/null)
  raw_deliver_to=$(jq -r 'if (.deliver_to | type) == "string" and (.deliver_to | length) > 0 then .deliver_to else (.created_by // "") end' "$task_file" 2>/dev/null)
  effective_deliver_to="$(lc_local "$raw_deliver_to" | tr -d '\n')"

  local delivery_map="" delivery_mapped=0 delivery_recipient=""
  if [[ -n "$effective_deliver_to" ]] && delivery_map=$(lookup_delivery_bot "$effective_deliver_to"); then
    delivery_mapped=1
    delivery_recipient="${delivery_map%%|*}"
  fi

  local closeout_instruction
  if [[ "$delivery_mapped" -eq 0 ]]; then
    closeout_instruction="交付路由 BLOCKED：deliver_to '${effective_deliver_to:-<empty>}' 查無 bot mapping；只向 owner 回覆一行 FYI 並請修復 deliver_to，禁止附檔或轉發路徑。"
  elif [[ "$effective_deliver_to" != "anya" ]]; then
    closeout_instruction="若 deliver_to 不是 anya：只向 owner 回覆一行 FYI：「FYI：FATQ ${task_id} 已通過 QA，成品已交付 ${effective_deliver_to} 需求鏈。」"
  else
    closeout_instruction="deliver_to 是 anya；成品只由獨立 FATQ DELIVERY 通知處理，本 closeout 信號仍禁止附檔或轉發路徑。"
  fi

  local closeout_text="[FATQ CLOSEOUT｜NO ATTACH]\n任務 ${task_id}（${slug}）已由 ${verdict_by:-$reviewer} 於 ${verdict_ts} 核准進入 done/。\n這是 closeout 狀態信號，不是成品交付。禁止附檔、禁止複製成品路徑、禁止轉發附件給 owner。\n${closeout_instruction}\n任務檔：${task_file}"

  # A1/A2 retain independent markers and retry semantics, but when both legs
  # resolve to Anya they share one deterministic delivery relay. Calling the
  # same relay once per marker also preserves crash recovery: a relay that was
  # written before either marker is backfilled without being emitted again.
  if [[ "$delivery_mapped" -eq 1 && "$delivery_recipient" == "anya" ]]; then
    local merged_artifact_lines
    merged_artifact_lines="$(structured_artifact_lines "$task_file")"
    [[ -n "$merged_artifact_lines" ]] || merged_artifact_lines="未登錄結構化 artifacts"
    local merged_text="[FATQ DELIVERY｜CLOSEOUT MERGED]\n任務 ${task_id}（${slug}）已由 ${verdict_by:-$reviewer} 於 ${verdict_ts} 核准進入 done/，並已通過 QA，可向原需求者交付。\nVerdict 摘要：APPROVE｜${verdict_summary}\n同一收件路由已合併 closeout 與 delivery；只需依本通知回覆一次。\ndeliver_to：${effective_deliver_to}\n成品路徑：\n${merged_artifact_lines}\n任務檔：${task_file}\n請依你的既有對人通道交付；不要改送 owner，除非 owner 就是本需求鏈的明確需求者。"
    local merged_content merged_relay
    merged_content=$(build_relay_json "$delivery_recipient" "$merged_text" "$task_id")
    merged_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a2-completed-delivery.json"
    if ! send_completion_leg "$task_file" "$merged_relay" "$merged_content" "completion_closeout_notified"; then
      log_decision "$task_id" "completion_merged:write_failed"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    if ! send_completion_leg "$task_file" "$merged_relay" "$merged_content" "completion_delivery_notified"; then
      log_decision "$task_id" "completion_merged:write_failed"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi

    local merged_aggregate_entry
    merged_aggregate_entry=$(jq -n --arg ts "$(now_iso)" \
      '{ts:$ts, by:"fatq-dispatch-cron", action:"completion_notified"}')
    if append_history_action_once_locked "$task_file" "completion_notified" "$merged_aggregate_entry"; then
      log_decision "$task_id" "completion_notified:merged_same_recipient"
      N_COMPLETION_NOTIFIED=$((N_COMPLETION_NOTIFIED+1))
    else
      log_decision "$task_id" "completion_aggregate:write_failed"
      N_SKIPPED=$((N_SKIPPED+1))
    fi
    return 0
  fi

  local closeout_content closeout_relay
  closeout_content=$(build_relay_json "anya" "$closeout_text" "$task_id")
  closeout_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-completed-closeout.json"
  if ! send_completion_leg "$task_file" "$closeout_relay" "$closeout_content" "completion_closeout_notified"; then
    log_decision "$task_id" "completion_closeout:write_failed"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  if [[ "$delivery_mapped" -eq 0 ]]; then
    local unmapped_entry
    unmapped_entry=$(jq -n --arg ts "$(now_iso)" --arg target "$effective_deliver_to" \
      '{ts:$ts, by:"fatq-dispatch-cron", action:"completion_delivery_unmapped", target:$target}')
    append_history_action_once_locked "$task_file" "completion_delivery_unmapped" "$unmapped_entry" || true
    log_decision "$task_id" "completion_delivery:unmapped"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local artifact_lines
  artifact_lines="$(structured_artifact_lines "$task_file")"
  [[ -n "$artifact_lines" ]] || artifact_lines="未登錄結構化 artifacts"
  local delivery_text="[FATQ DELIVERY]\n你所屬需求鏈的任務 ${task_id}（${slug}）已通過 QA，可向原需求者交付。\nVerdict 摘要：APPROVE｜${verdict_summary}\ndeliver_to：${effective_deliver_to}\n成品路徑：\n${artifact_lines}\n任務檔：${task_file}\n請依你的既有對人通道交付；不要改送 owner，除非 owner 就是本需求鏈的明確需求者。"
  local delivery_content delivery_relay
  delivery_content=$(build_relay_json "$delivery_recipient" "$delivery_text" "$task_id")
  delivery_relay="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a2-completed-delivery.json"
  if ! send_completion_leg "$task_file" "$delivery_relay" "$delivery_content" "completion_delivery_notified"; then
    log_decision "$task_id" "completion_delivery:write_failed"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local aggregate_entry
  aggregate_entry=$(jq -n --arg ts "$(now_iso)" \
    '{ts:$ts, by:"fatq-dispatch-cron", action:"completion_notified"}')
  if append_history_action_once_locked "$task_file" "completion_notified" "$aggregate_entry"; then
    log_decision "$task_id" "completion_notified"
    N_COMPLETION_NOTIFIED=$((N_COMPLETION_NOTIFIED+1))
  else
    log_decision "$task_id" "completion_aggregate:write_failed"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

scan_dir_done_completion() {
  local dir="$FATQ_ROOT/done"
  [[ -d "$dir" ]] || return 0
  local seed_marker="$FATQ_STATE_DIR/completion_notify_seeded"
  local seeding=0
  [[ -f "$seed_marker" ]] || seeding=1

  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if ! is_valid_task "$f"; then
      handle_invalid_task_json "$f" "done"
      continue
    fi
    handle_completion_notify "$f" "$seeding"
  done

  if [[ "$seeding" == "1" ]]; then
    touch "$seed_marker" 2>/dev/null || true
    log_line "completion_notify: first pass complete, existing done/ backlog seeded without relay"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# rejected/ 指揮官同步通知（74c3，Anya 2026-07-09 診斷）
#
# builder 的退件重派已由 scan_dir_dispatch "rejected" "assigned" 處理；這裡只補
# orchestrator 旁路通知，讓 Anya 收到 REJECT 原因摘要與累計次數。冪等鍵用目前
# verdict_reject 累計數：同一輪 REJECT 只會有同一個 rN relay 檔名，併發由既有
# ln no-clobber 擋重；history 記 reject_notified/reject_count 防重掃重發。
handle_reject_notify() {
  local task_file="$1"
  local task_id
  task_id=$(get_task_id "$task_file")

  local reject_count
  reject_count=$(jq -r '[.history // [] | .[] | select(.action=="verdict_reject")] | length' "$task_file" 2>/dev/null)
  if [[ "${reject_count:-0}" == "0" ]]; then
    log_decision "$task_id" "skip:no_verdict_reject"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local already_notified
  already_notified=$(jq -r --argjson n "$reject_count" \
    '[.history // [] | .[] | select(.action=="reject_notified" and (.reject_count // 0) == $n)] | length' \
    "$task_file" 2>/dev/null)
  if [[ "${already_notified:-0}" != "0" ]]; then
    log_decision "$task_id" "skip:reject_already_notified"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi

  local verdict_entry reason_summary issue_type verdict_by verdict_ts slug
  verdict_entry=$(jq -c '[.history // [] | .[] | select(.action=="verdict_reject")] | last // empty' "$task_file" 2>/dev/null)
  reason_summary=$(jq -r --argjson verdict "$verdict_entry" '
    def nonempty:
      . != null and (. | tostring | length > 0);
    def readable_findings:
      if type == "array" then
        map(
          if type == "object" then
            "[\(.status // "UNKNOWN")] \(.dimension // "finding"): \(.detail // .reason // .note // tostring)"
          else
            tostring
          end
        ) | join(" | ")
      elif type == "object" then
        "[\(.status // "UNKNOWN")] \(.dimension // "finding"): \(.detail // .reason // .note // tostring)"
      else
        tostring
      end;
    [
      ($verdict.reason?),
      ($verdict.note?),
      (.review.note?),
      (.review.reason?),
      (.review.findings? | if . == null then null else readable_findings end)
    ]
    | map(select(nonempty))
    | first // "<未填>"
    | tostring
    | .[0:200]
  ' "$task_file" 2>/dev/null)
  issue_type=$(jq -r --argjson verdict "$verdict_entry" '$verdict.issue_type? // .review.issue_type? // ""' "$task_file" 2>/dev/null)
  verdict_by=$(jq -r '.by // ""' <<< "$verdict_entry" 2>/dev/null)
  verdict_ts=$(jq -r '.ts // ""' <<< "$verdict_entry" 2>/dev/null)
  slug=$(jq -r '.slug // .task_id' "$task_file" 2>/dev/null)

  local issue_line=""
  [[ -n "$issue_type" ]] && issue_line="\nissue_type：${issue_type}"

  local verdict_summary="${reason_summary:0:100}"
  local text="[FATQ REJECT 通知] 任務 ${task_id}（${slug}）已進入 rejected/，累計第 ${reject_count} 次 REJECT。${issue_line}\nReviewer：${verdict_by:-<未知>} ${verdict_ts}\nVerdict 摘要：REJECT｜${verdict_summary}\n原因摘要（前 200 字）：${reason_summary}\n任務檔：${task_file}\n@Anyachl_bot"
  local content
  content=$(build_relay_json "anya" "$text" "$task_id")
  local relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-r${reject_count}-reject-notify.json"
  local entry
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson n "$reject_count" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "reject_notified", relay_file: $relay, target: "anya", reject_count: $n}')

  if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
    log_decision "$task_id" "reject_notified"
    N_REJECT_NOTIFIED=$((N_REJECT_NOTIFIED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "reject_notified:lost_race" || log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

scan_dir_reject_notify() {
  local dir="$FATQ_ROOT/rejected"
  [[ -d "$dir" ]] || return 0

  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if ! is_valid_task "$f"; then
      handle_invalid_task_json "$f" "rejected"
      continue
    fi
    handle_reject_notify "$f"
  done
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

    local event_seq
    if ! event_seq=$(get_next_cron_action_seq "$task_file" "approval_reminder"); then
      log_decision "$task_id" "skip:transient_read"
      N_SKIPPED=$((N_SKIPPED+1))
      return 0
    fi
    local text="[FATQ 審批待決] ${task_id}（domain=${domain}, requested_by=${requested_by}）待審批，${expires_iso} 逾時。任務檔：${task_file}\n@Anyachl_bot 請轉達老兔決策。"
    local content relay_file entry
    content=$(build_relay_json "anya" "$text" "$task_id")
    relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${event_seq}-a1-approval-reminder.json"
    entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson event_seq "$event_seq" \
      '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_reminder", relay_file: $relay, event_seq: $event_seq}')

    if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
      log_decision "$task_id" "approval_reminder"
      N_NUDGED=$((N_NUDGED+1))
    else
      local dsrc=$?
      [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "approval_reminder:lost_race" || log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
    fi
    return 0
  fi

  # 已逾時：§2.6 逾時梯
  local expired_alert_ts
  expired_alert_ts=$(jq -r '[.history // [] | .[] | select(.by=="fatq-dispatch-cron" and .action=="approval_expired_alert")] | last | .ts // empty' "$task_file" 2>/dev/null)

  if [[ -z "$expired_alert_ts" ]]; then
    # 第一步：升級提醒一次性
    local text="[FATQ 審批逾時] ${task_id}（domain=${domain}）已逾時（${expires_iso}）仍無決策。任務檔：${task_file}\n@Anyachl_bot 請盡速轉達老兔，逾時不等於同意（default-deny）。"
    local content relay_file entry
    content=$(build_relay_json "anya" "$text" "$task_id")
    relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-a1-approval-expired-alert.json"
    entry=$(jq -n --arg ts "$(now_iso)" '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_expired_alert"}')

    if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
      log_decision "$task_id" "approval_expired_alert"
      N_ESCALATED=$((N_ESCALATED+1))
    else
      local dsrc=$?
      [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "approval_expired_alert:lost_race" || log_decision "$task_id" "skip:moved"
      N_SKIPPED=$((N_SKIPPED+1))
    fi
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

  local event_seq
  if ! event_seq=$(get_next_cron_action_seq "$task_file" "approval_expire_reminder"); then
    log_decision "$task_id" "skip:transient_read"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  local text="[FATQ 審批回收] ${task_id} 逾時已超過 24h 仍無決策。請執行：fatq approval expire ${task_id} --as anya（回歸 ${task_file} 原狀態，decision 維持 null，受門控操作仍不得執行）。"
  local content relay_file entry
  content=$(build_relay_json "anya" "$text" "$task_id")
  relay_file="fatq-$(task_hex_id "$task_id")-$(task_phase "$task_file")-e${event_seq}-a1-approval-expire-reminder.json"
  entry=$(jq -n --arg ts "$(now_iso)" --arg relay "$relay_file" --argjson event_seq "$event_seq" \
    '{ts: $ts, by: "fatq-dispatch-cron", action: "approval_expire_reminder", relay_file: $relay, event_seq: $event_seq}')

  if dispatch_send "$task_file" "$relay_file" "$content" "$entry"; then
    log_decision "$task_id" "approval_expire_reminder"
    N_NUDGED=$((N_NUDGED+1))
  else
    local dsrc=$?
    [[ "$dsrc" -eq 1 ]] && log_decision "$task_id" "approval_expire_reminder:lost_race" || log_decision "$task_id" "skip:moved"
    N_SKIPPED=$((N_SKIPPED+1))
  fi
}

scan_dir_approval_pending() {
  local dir="$FATQ_ROOT/approval_pending"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if ! is_valid_task "$f"; then
      handle_invalid_task_json "$f" "approval_pending"
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
      handle_invalid_task_json "$f" "$dirname"
      continue
    fi
    local task_id
    task_id=$(get_task_id "$f")

    if [[ "$FATQ_CREATE_GATE_DISABLED" != "1" ]]; then
      local create_defects
      create_defects=$(creation_gate_defects "$f")
      if [[ -n "$create_defects" ]]; then
        handle_creation_gate_failure "$f" "$create_defects"
        continue
      fi
    fi

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
          # ①軟親和（org-design #2，d5c3）——Bella QA REJECT 修正：不可直接拿
          # 親和預設當 raw_name 派工。task 檔的 assigned 欄位仍是空的，relay
          # 收件人拿到「已指派給你」卻在 claim 時被 claim_locked 的
          # assigned==identity 檢查擋下（E_PERM），且原本 60 分鐘無主告警
          # Anya 的安全網也被繞過了——比改動前更糟（Bella fixture 實錘）。
          # 矩陣紅線下沒有「builder-direct 自動指派」的合法實作：assigned 要
          # 先真的被寫入（唯有 anya 執行 fatq reassign 才能寫），CLI 才可能讓
          # 人 claim 成功。改為「建議制」：走原本的 unassigned_pending 告警，
          # 只是文案帶上親和建議人選，讓 Anya 一鍵 reassign 而非純靠猜。
          handle_unassigned_pending "$f"
          continue
        fi
        ;;
      reviewer)
        raw_name=$(get_reviewer "$f")
        # reviewer 為空時維持舊版硬編碼預設 bella（Bella QA REJECT 修正：
        # 親和表若指到 yitang/ron-reviewer 等非 bella/anya 身份，實際 .reviewer
        # 欄位仍是空的，該身份執行 verdict 時 E4 判定會被拒——bella 對 E4
        # 有 ∪{bella,anya} 的萬用審查權，欄位是否為空不影響她的權限，是唯一
        # 在「不寫欄位就能路由」前提下安全的預設值）。
        [[ -z "$raw_name" ]] && raw_name="bella"
        # ②infra gate（org-design #3，d5c3）：公共財變動一律強制 reviewer=bella，
        # 即使已明文指定他人也覆蓋（防漏優先於防誤）。覆蓋事件記 1 次性 history
        # （infra_gate_override，避免每輪掃描重複寫入同一筆稽核）。
        if is_infra_task "$f" && [[ "$(lc_local "$raw_name")" != "bella" ]]; then
          local already_logged
          already_logged=$(jq -r '[.history // [] | .[] | select(.action=="infra_gate_override")] | length' "$f" 2>/dev/null)
          if [[ "${already_logged:-0}" == "0" ]]; then
            local override_entry
            override_entry=$(jq -n --arg ts "$(now_iso)" --arg original "$raw_name" \
              '{ts: $ts, by: "fatq-dispatch-cron", action: "infra_gate_override", original_reviewer: $original, forced_reviewer: "bella"}')
            append_history_locked "$f" "$override_entry" || true
          fi
          log_decision "$task_id" "infra_gate_override:reviewer=bella(was:$raw_name)"
          raw_name="bella"
        fi
        ;;
      fixed:*)
        raw_name="${field_mode#fixed:}"
        ;;
    esac

    local mapped recipient handle
    if ! mapped=$(lookup_bot "$raw_name") || [[ -z "${mapped%%|*}" ]]; then
      handle_unmapped_dispatch_target "$f" "$raw_name"
      continue
    fi
    recipient="${mapped%%|*}"
    handle="${mapped##*|}"

    local text
    case "$dirname" in
      pending)
        text="[FATQ 派工] 任務 ${task_id} 已指派給你。\n任務檔：${f}$(trust_hint_for_task "$f")\n請：1) 讀任務檔（先讀 last_run_summary/lessons_learned 若有）；2) 自行 mv pending→in_progress（原子操作，append history）；3) 完成後先跑 shared/bin/fatq-verify.sh 全過，再 mv in_progress→review。你不得 mv 到 done。"
        ;;
      review|spec_review|design_review)
        text="[FATQ 派工·審查] 任務 ${task_id} 待你審查。\n任務檔：${f}$(trust_hint_for_task "$f")\nQA 第一步先跑 fatq-verify.sh，任一 fail 直接 REJECT，不進人工審。"
        ;;
      design)
        text="[FATQ 派工·設計] 任務 ${task_id} 待你出設計方案。\n任務檔：${f}"
        ;;
      rejected)
        # f7c1：退件的「首次通知」複用 handle_dispatch_target 既有的 claim-TTL/
        # activity-detection 機制，不另發明新 idempotency 標記——verdict_reject
        # 本身就是一筆 by!=cron 的 history 活動，天然會讓上一筆 dispatch（task
        # 首次進 pending 時那筆）判定為「之後有 assignee 活動」而重算 attempt=1，
        # 立刻首派一次；同一輪之後沒有新的非 cron 活動就落回原本 claim TTL（4h）
        # 邏輯，不會每次 cron/事件觸發都重送（冪等天然成立，非額外加鎖）。
        # scan_dir_nudge("rejected") 的 2h catch-up 催工完全不動、獨立並行。
        text="[FATQ 退件重派] 任務 ${task_id} 被 Bella REJECT，請立即查看 review.findings 並修復。\n任務檔：${f}\n請：1) 讀 review.findings/fix_required；2) 自行 mv rejected→in_progress（原子操作，append history）；3) 修復後先跑 shared/bin/fatq-verify.sh 全過，再 mv in_progress→review。你不得 mv 到 done。"
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
      handle_invalid_task_json "$f" "$dirname"
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

    if [[ "$dirname" == "in_progress" ]]; then
      if handle_blocked_auth_notify "$f"; then continue; fi
      if handle_blocked_stall_notify "$f"; then continue; fi
    fi

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
  # f7c1（老兔 2026-07-09 04:38 挖出）：退件此前只吃 scan_dir_nudge 的 2h 催工
  # 門檻，assignee 要等 2h stale nudge 才被重新通知去修，今晚每張退件默默損失
  # ~2h。加這行讓 rejected/ 也走跟 pending 一樣的即時首派路徑（同一顆
  # handle_dispatch_target，見上方 case "$dirname" in rejected) 分支的說明）。
  # 下面 scan_dir_nudge "rejected" 完全不動，繼續當「即時派了但遲遲沒動」的
  # 二次催工保底，兩者互不覆蓋。
  scan_dir_dispatch "rejected" "assigned"
  scan_dir_reject_notify

  scan_dir_nudge "rejected"
  scan_dir_nudge "in_progress"

  scan_dir_approval_pending

  scan_dir_done_completion

  for d in cancelled wont_do reviews proposals; do
    skip_dir "$d"
  done

  log_line "scan done: ${N_DISPATCHED} dispatched, ${N_NUDGED} nudged, ${N_ESCALATED} escalated, ${N_COMPLETION_NOTIFIED} completion_notified, ${N_REJECT_NOTIFIED} reject_notified, ${N_SKIPPED} skipped"

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

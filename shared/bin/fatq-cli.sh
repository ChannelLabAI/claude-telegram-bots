#!/usr/bin/env bash
# fatq-cli.sh — FATQ 統一寫入層（Part 1）
#
# Spec: handover/fatq-cli-and-approval-spec-20260707.md (v1) §1
#
# tasks/ 的唯一寫入介面：取代散裝 jq+mv，把權限矩陣、原子寫入、flock 鎖、
# history 標準化收進一支工具。Part 2（approval_pending 審批狀態機）不在本檔範圍。
#
# Usage: fatq-cli.sh <subcommand> [args...] --as <identity> [--json]
#
# Subcommands: create, claim, submit, verdict approve, verdict reject,
#              reassign, comment, query, hold, update-field,
#              approval request, approval approve, approval reject, approval expire
#
# Exit codes (§1.4):
#   0 = 成功
#   2 = E_USAGE  用法/參數錯
#   3 = E_PERM   權限拒絕
#   4 = E_STATE  非法狀態轉移
#   5 = E_VERIFY verify gate 未過
#   6 = E_CONFLICT 併發衝突落敗
#   7 = E_NOTFOUND 任務不存在

set -uo pipefail

# ── env（有預設值，供測試 fixture 覆寫，沿 fatq-dispatch.sh 慣例） ─────────
FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_TEAM_CONFIG="${FATQ_TEAM_CONFIG:-/home/oldrabbit/.claude-bots/shared/team-config.json}"
FATQ_VERIFY_SH="${FATQ_VERIFY_SH:-/home/oldrabbit/.claude-bots/shared/bin/fatq-verify.sh}"
FATQ_NOW_ISO="${FATQ_NOW_ISO:-}"   # 測試注入時鐘（ISO8601 +08:00）；空＝真實時間
FATQ_PROD_ROOT="${FATQ_PROD_ROOT:-/home/oldrabbit/.claude-bots/tasks}"   # 生產路徑常數（f7d9 時鐘完整性）：僅此路徑無視 FATQ_NOW_ISO 注入；可覆寫供測試模擬「這就是生產路徑」情境，不需真的碰真實 tasks/
FATQ_DISPATCH_AFFINITY="${FATQ_DISPATCH_AFFINITY:-/home/oldrabbit/.claude-bots/shared/lib/dispatch-affinity.json}"  # org-design #3 公共財偵測表
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"  # approval reject 通知 requester 用（§2.5，request 的通知交給 dispatch/watch 偵測 approval_pending 產生）
PROJECTS_ROOT="${PROJECTS_ROOT:-/home/oldrabbit/.claude-bots/projects}"  # b8f4：專案小組薄 project 檔目錄，同 FATQ_ROOT 慣例可測試注入

# §1.2 核心狀態目錄（CLI 狀態機只認這些 + approval_pending，E1）
CORE_STATE_DIRS=(pending in_progress review done rejected cancelled wont_do approval_pending)

# 附加身份名單（Q5 裁決落地，2026-07-07）：不再寫死在腳本，改讀
# team-config.json 的 external_identities 段——單一權威源，mac-agent 的
# users.db 身份映射與本 CLI 共用同一份名單，不會漂移。

LOG_PREFIX="[fatq-cli]"

# ── 小工具 ──────────────────────────────────────────────────────────────
lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

# 生產路徑防呆（f7d9）：realpath -m 解析 FATQ_ROOT 是否＝生產 tasks/ 路徑
# （-m 容忍不存在的路徑片段，不因 fixture 用 mktemp -d 的隨機目錄而炸掉；
# 同時解析 symlink，避免用軟連結繞過判定——review_focus 明點的健壯性要求）。
# 生產路徑一律無視 FATQ_NOW_ISO 注入，只有非生產（測試 fixture）才會生效。
is_prod_root() {
  [[ "$(realpath -m "$FATQ_ROOT" 2>/dev/null)" == "$(realpath -m "$FATQ_PROD_ROOT" 2>/dev/null)" ]]
}

now_iso() {
  if [[ -n "$FATQ_NOW_ISO" ]] && ! is_prod_root; then
    echo "$FATQ_NOW_ISO"
    return
  fi
  TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"
}

now_epoch() {
  if [[ -n "$FATQ_NOW_ISO" ]] && ! is_prod_root; then
    date -d "$FATQ_NOW_ISO" +%s 2>/dev/null && return
  fi
  date +%s
}

# 單調性防呆（f7d9）：對已組好、尚未寫入磁碟的 tmp 檔內容操作——若最新一筆
# history 的 ts 早於前一筆，改用系統時鐘覆寫該筆 ts，並插入一筆 clock_warn
# 記錄異常（attempted_ts＝原本要寫入但被拒的值）。統一在每個 mv -f 前呼叫。
# 只比較「新寫入的這一筆」跟「它前面那一筆」——兩者都已在同一支 tmp 檔內，
# 不需要額外重讀任務檔，天然跟 flock 持鎖區段一致，不引入新的併發窗口。
enforce_history_monotonic() {
  local tmp_file="$1"
  local n
  n=$(jq '.history | length' "$tmp_file" 2>/dev/null)
  [[ -z "$n" || "$n" -lt 2 ]] && return 0

  local last_ts prev_ts last_epoch prev_epoch
  last_ts=$(jq -r '.history[-1].ts' "$tmp_file")
  prev_ts=$(jq -r '.history[-2].ts' "$tmp_file")
  last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
  prev_epoch=$(date -d "$prev_ts" +%s 2>/dev/null)
  [[ -z "$last_epoch" || -z "$prev_epoch" ]] && return 0

  if [[ "$last_epoch" -lt "$prev_epoch" ]]; then
    local corrected_ts warn_entry fixed
    corrected_ts="$(TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00")"
    warn_entry=$(jq -n --arg ts "$corrected_ts" --arg attempted "$last_ts" \
      '{ts:$ts, by:"fatq-cli", via:"fatq-cli", action:"clock_warn",
        attempted_ts:$attempted,
        note:"history append 單調性防呆：偵測到新條目 ts 早於前一筆，已改用系統時鐘"}')
    fixed=$(jq --arg new_ts "$corrected_ts" '.history[-1].ts = $new_ts' "$tmp_file") \
      && printf '%s' "$fixed" > "$tmp_file"
    fixed=$(jq --argjson warn "$warn_entry" \
      '.history = (.history[0:-1] + [$warn] + [.history[-1]])' "$tmp_file") \
      && printf '%s' "$fixed" > "$tmp_file"
  fi
  return 0
}

err() { echo "$LOG_PREFIX ERROR: $*" >&2; }

# JSON 輸出（成功／失敗），依 --json flag 決定是否印出
JSON_MODE=0
json_ok() {
  # $1=task_id $2=from $3=to $4=history_appended(true/false)
  jq -n --arg task_id "$1" --arg from "$2" --arg to "$3" --argjson ha "${4:-true}" \
    '{ok:true, task_id:$task_id, from:$from, to:$to, history_appended:$ha}'
}
json_err() {
  # $1=code $2=message
  jq -n --arg code "$1" --arg message "$2" '{ok:false, code:$code, message:$message}'
}

exit_usage() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_USAGE" "$msg"
  exit 2
}
exit_perm() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_PERM" "$msg"
  exit 3
}
exit_state() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_STATE" "$msg"
  exit 4
}
exit_verify() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_VERIFY" "$msg"
  exit 5
}
exit_conflict() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_CONFLICT" "$msg"
  exit 6
}
exit_notfound() {
  local msg="$1"
  err "$msg"
  [[ $JSON_MODE -eq 1 ]] && json_err "E_NOTFOUND" "$msg"
  exit 7
}

# ── 身份 (§1.3.1) ───────────────────────────────────────────────────────
# 合法身份名單 = team-config.json 的 bot 名單 ∪ external_identities 段
# team-config.json 結構：assistants[].state_dir ∪ shared_pools.*[].state_dir
#                        ∪ external_identities[]（Q5：單一權威源，非 bot 的
#                        web/human 身份如 laotu 與 mac-agent 皆收在此段）
known_identities() {
  jq -r '
    [ (.assistants // [])[].state_dir,
      (.shared_pools // {} | to_entries[] | .value[]?.state_dir),
      (.external_identities // [])[] ] | .[]
  ' "$FATQ_TEAM_CONFIG" 2>/dev/null
}

is_known_identity() {
  local ident_lc name
  ident_lc="$(lc "$1")"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$(lc "$name")" == "$ident_lc" ]] && return 0
  done < <(known_identities)
  return 1
}

# reviewer pool 身份清單（state_dir, lowercase）—— 用於權限矩陣判斷「reviewer 類」
reviewer_pool_identities() {
  jq -r '(.shared_pools.reviewer // [])[].state_dir' "$FATQ_TEAM_CONFIG" 2>/dev/null
}

is_reviewer_pool() {
  local ident_lc name
  ident_lc="$(lc "$1")"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$(lc "$name")" == "$ident_lc" ]] && return 0
  done < <(reviewer_pool_identities)
  return 1
}

# builder pool 身份清單（state_dir, lowercase）＋附加 mac-agent（③a 裁決：fail-closed）
# 用於權限矩陣判斷「builder 類」轉移（claim/submit）——即使 assigned 欄位寫某身份，
# 該身份不在 builder pool（∪ mac-agent）一律拒絕，防誤設任務指派給非 builder 身份。
builder_pool_identities() {
  jq -r '(.shared_pools.builder // [])[].state_dir' "$FATQ_TEAM_CONFIG" 2>/dev/null
}

is_builder_pool() {
  local ident_lc name
  ident_lc="$(lc "$1")"
  [[ "$ident_lc" == "mac-agent" ]] && return 0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$(lc "$name")" == "$ident_lc" ]] && return 0
  done < <(builder_pool_identities)
  return 1
}

# ── 公共財路徑偵測（org-design-lines-20260707 決議 #3，create 建單補遺） ──
# 精準化規則（81aa）：deliverables/context 只有指向 shared/ 等實際公共財路徑
# 才命中；goal 則必須同時出現修改動詞與 infra_patterns。純描述流程詞
# （如 pending→dispatch→QA）不再因子字串命中而改寫 reviewer。
INFRA_MATCH_PATTERN=""
infra_pattern_in_text() {
  local text pattern text_lc pattern_lc
  text="$1"
  text_lc="$(lc "$text")"
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    pattern_lc="$(lc "$pattern")"
    if [[ "$text_lc" == *"$pattern_lc"* ]]; then
      INFRA_MATCH_PATTERN="$pattern"
      return 0
    fi
  done < <(jq -r '.infra_patterns[]?' "$FATQ_DISPATCH_AFFINITY" 2>/dev/null)
  return 1
}

has_infra_action_verb() {
  local text text_lc
  text="$1"
  text_lc="$(lc "$text")"
  [[ "$text" == *"改"* || "$text" == *"修"* || "$text" == *"新增"* || "$text" == *"刪"* || "$text" == *"重構"* || "$text" == *"遷移"* || "$text_lc" == *"fix"* || "$text_lc" == *"update"* || "$text_lc" == *"change"* || "$text_lc" == *"modify"* || "$text_lc" == *"patch"* || "$text_lc" == *"migrate"* || "$text_lc" == *"migration"* || "$text_lc" == *"rename"* || "$text_lc" == *"restart"* || "$text_lc" == *"deploy"* ]]
}

has_shared_path_reference() {
  local text="$1"
  [[ "$text" == *"shared/"* || "$text" == *"/shared/"* || "$text" == *"shared/bin/"* || "$text" == *"shared/lib/"* || "$text" == *"shared/tests/"* ]]
}

is_infra_change() {
  local goal_text="${1:-}" field_text="${2:-}"
  INFRA_MATCH_PATTERN=""

  if has_shared_path_reference "$field_text" && infra_pattern_in_text "$field_text"; then
    return 0
  fi

  if has_infra_action_verb "$goal_text" && infra_pattern_in_text "$goal_text"; then
    return 0
  fi

  return 1
}

write_infra_gate_rewrite_relay() {
  local task_id="$1" task_file="$2" creator="$3" original_reviewer="$4" pattern="$5"
  [[ "${FATQ_MATTERMOST_DISABLE:-0}" == "1" ]] && return 0

  local recipient="" handle="" mapped relay_text relay_content relay_file
  if [[ -n "$creator" ]] && mapped=$(lookup_bot_for_relay "$creator"); then
    recipient="${mapped%%|*}"
    handle="${mapped##*|}"
  else
    handle="@Anyachl_bot"
  fi

  relay_text="[FATQ infra-gate] 任務 ${task_id} 命中公共財守門，reviewer 已由 '${original_reviewer:-<空>}' 強制改為 'bella'。\npattern：${pattern:-<unknown>}\n任務檔：${task_file}\n${handle}"
  relay_content=$(jq -n --arg from "fatq-cli" --arg recipient "$recipient" --arg text "$relay_text" \
    --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}')
  relay_file="fatq-infra-gate-rewrite-$(date +%s%N 2>/dev/null || echo $$).json"
  mkdir -p "$FATQ_RELAY_DIR" 2>/dev/null || true
  printf '%s' "$relay_content" > "${FATQ_RELAY_DIR}/${relay_file}" 2>/dev/null || true
}

# ── 業務線親和預填（org-design-lines-20260707 決議 #2，create 層合法實作，
# b3d7）：d5c3 揭示 cron 層親和違紅線（cron 不能寫欄位，relay 收件人 claim/
# verdict 時權限檢查讀的是真實欄位，永遠不符）；Anya 裁決換層——create 本身
# 就是任務檔的合法寫手，缺省欄位在建檔當下直接寫入業務線慣用值，天生沒有
# 「假裝欄位已寫」的問題。$1=builder|reviewer，查 IDENTITY（本次 create 呼叫
# 者＝task 的 created_by）對應線，查無 fallback lines.default。
get_create_affinity_default() {
  local field="$1"
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  jq -r --arg cb "$IDENTITY" --arg field "$field" \
    '(.lines[$cb][$field] // .lines.default[$field] // empty)' "$FATQ_DISPATCH_AFFINITY" 2>/dev/null
}

# ── 身份聲明解析 ─────────────────────────────────────────────────────────
IDENTITY=""
resolve_identity() {
  # --as 優先於環境變數 FATQ_IDENTITY
  if [[ -n "${CLI_AS:-}" ]]; then
    IDENTITY="$(lc "$CLI_AS")"
  elif [[ -n "${FATQ_IDENTITY:-}" ]]; then
    IDENTITY="$(lc "$FATQ_IDENTITY")"
  else
    exit_usage "身份未聲明：需要 --as <identity> 或環境變數 FATQ_IDENTITY"
  fi

  if ! is_known_identity "$IDENTITY"; then
    exit_perm "identity 未知：$IDENTITY 不在 team-config.json 的 assistants/shared_pools/external_identities 任一名單中"
  fi
}

# ── task 檔查找 ──────────────────────────────────────────────────────────
# 回傳 task 檔完整路徑（在 CORE_STATE_DIRS 中搜尋），找不到則回傳空字串
find_task_file() {
  local task_id="$1" d f
  for d in "${CORE_STATE_DIRS[@]}"; do
    f="${FATQ_ROOT}/${d}/${task_id}.json"
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  echo ""
  return 1
}

current_state_of() {
  # 從路徑推導目錄名（狀態名）
  basename "$(dirname "$1")"
}

# ── flock 包住 read-modify-rename（§1.4.2 / §1.5，沿 fatq-dispatch.sh §6.6 慣例） ──
# 用法：with_task_lock <task_file> <callback_fn> [extra args passed to callback]
# callback 收到 lock 後的路徑，並需自行重驗＋處理 mv。
with_task_lock() {
  local task_file="$1"; shift
  local callback="$1"; shift
  local lock_fd

  exec {lock_fd}<"$task_file" 2>/dev/null || return 9  # 9 = 檔案在拿鎖前就消失
  flock -x "$lock_fd"

  if [[ ! -e "$task_file" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}<&- 2>/dev/null || true
    return 9
  fi

  "$callback" "$task_file" "$@"
  local rc=$?

  flock -u "$lock_fd"
  exec {lock_fd}<&- 2>/dev/null || true
  return $rc
}

# b8f4（Bella 硬紅線③）：project 檔的鎖——task JSON 用 flock-on-fd（with_task_lock），
# 但 project 檔還有 mvp-server.ts（TS/Bun，非本腳本）這個第二寫手同時會 PATCH
# member_bots/歸檔，兩邊必須用同一套跨語言都好實作的協定才會真的互斥，不能各自
# flock 自己的 fd（flock 只在同一 inode 上才會真的擋到對方，這裡選最簡單、
# bash/TS 都能原生做、不需額外套件的 mkdir 互斥鎖：mkdir 本身就是原子的
# check-and-create，兩邊用同一個 <project_file>.lock 目錄名即可互斥）。
# 用法：with_project_lock <project_file> <callback_fn> [extra args]
# callback 收到 project_file 路徑，需自行重讀＋處理 temp+rename 寫回。
with_project_lock() {
  local project_file="$1"; shift
  local callback="$1"; shift
  local lock_dir="${project_file}.lock"
  local waited=0
  local max_wait_ms=5000
  while ! mkdir "$lock_dir" 2>/dev/null; do
    # 陳舊鎖防死鎖：持鎖方若已崩潰，鎖目錄會卡住不放——鎖齡超過 30s 視為陳舊，強制搶回
    if [[ -d "$lock_dir" ]]; then
      local age_ms
      age_ms=$(( $(date +%s%3N) - $(stat -c %Y "$lock_dir" 2>/dev/null || echo 0)*1000 ))
      if [[ $age_ms -gt 30000 ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
        continue
      fi
    fi
    sleep 0.05
    waited=$(( waited + 50 ))
    [[ $waited -ge $max_wait_ms ]] && return 6  # E_CONFLICT：搶鎖逾時
  done

  if [[ ! -e "$project_file" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 7  # E_NOTFOUND：拿鎖前檔案就消失
  fi

  "$callback" "$project_file" "$@"
  local rc=$?

  rmdir "$lock_dir" 2>/dev/null || true
  return $rc
}


# 建立標準化 history 條目 JSON（§1.4.3）
# args: action from to [reason]
build_history_entry() {
  local action="$1" from="$2" to="$3" reason="${4:-}" issue_type="${5:-}"
  if [[ -n "$reason" ]]; then
    jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg action "$action" \
      --arg from "$from" --arg to "$to" --arg reason "$reason" \
      --arg issue_type "$issue_type" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:$action, from:$from, to:$to, reason:$reason}
       + (if $issue_type != "" then {issue_type:$issue_type} else {} end)'
  else
    jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg action "$action" \
      --arg from "$from" --arg to "$to" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:$action, from:$from, to:$to}'
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# 子命令實作
# ═══════════════════════════════════════════════════════════════════════

# ── create：pending 建檔（§1.2 create） ─────────────────────────────────
cmd_create() {
  resolve_identity  # 任何已知 identity 可 create

  local title="" goal="" background="" context="" deliverables="" acceptance_criteria="" out_of_scope="" review_focus=""
  local assigned="" reviewer="" priority="P2" fast_track="false" verify_commands="[]"
  local skills="[]" graduated_invariant="[]"
  local slug="" project_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --goal) goal="$2"; shift 2 ;;
      --background) background="$2"; shift 2 ;;
      --context) context="$2"; shift 2 ;;
      --deliverables) deliverables="$2"; shift 2 ;;      # JSON array string
      --acceptance_criteria) acceptance_criteria="$2"; shift 2 ;; # JSON array string
      --out_of_scope) out_of_scope="$2"; shift 2 ;;       # JSON array string
      --review_focus) review_focus="$2"; shift 2 ;;
      --assigned) assigned="$2"; shift 2 ;;
      --reviewer) reviewer="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --fast_track) fast_track="$2"; shift 2 ;;
      --verify_commands) verify_commands="$2"; shift 2 ;;  # JSON array string
      --skills) skills="$2"; shift 2 ;;  # JSON array string
      --graduated_invariant) graduated_invariant="$2"; shift 2 ;;  # JSON array string
      --slug) slug="$2"; shift 2 ;;
      --project_id) project_id="$2"; shift 2 ;;  # b8f4：可選，task 屬於哪個專案（Bella 紅線②：CLI 當下寫入，非 web 事後改）
      --as) shift 2 ;;   # 已由外層解析，略過（帶值，shift 2）
      --json) shift ;;   # 已由外層解析，略過（不帶值，shift 1；Bella QA #1）
      *) exit_usage "create: 未知參數 $1" ;;
    esac
  done

  # b8f4：project_id 若給了，建檔前先驗證 project 真的存在——寧可建檔前擋，
  # 不要建完 task 才發現連不到專案（task 都已落地在 pending/，沒有簡單的
  # 回滾點；先驗證可以完全避免這個孤兒 task 情境）。
  local project_file=""
  if [[ -n "$project_id" ]]; then
    project_id="$(echo "$project_id" | tr -c '[:alnum:]-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"  # 消毒：只留字母數字與連字號，防路徑穿越（同 slug 消毒慣例，含去除 echo 換行造成的尾綴 -）
    project_file="${PROJECTS_ROOT}/${project_id}.json"
    [[ -f "$project_file" ]] || exit_usage "create: project_id 不存在或已歸檔：$project_id"
  fi

  # 必填欄位檢查（§1.2 create：goal/background/context/deliverables/acceptance_criteria/out_of_scope/review_focus 缺任一 exit 2）
  local missing=()
  [[ -z "$goal" ]] && missing+=(goal)
  [[ -z "$background" ]] && missing+=(background)
  [[ -z "$context" ]] && missing+=(context)
  [[ -z "$deliverables" ]] && missing+=(deliverables)
  [[ -z "$acceptance_criteria" ]] && missing+=(acceptance_criteria)
  [[ -z "$out_of_scope" ]] && missing+=(out_of_scope)
  [[ -z "$review_focus" ]] && missing+=(review_focus)
  if [[ ${#missing[@]} -gt 0 ]]; then
    exit_usage "create: 缺必填欄位: ${missing[*]}"
  fi

  # 驗證 array 欄位是合法 JSON array
  for fld_name in deliverables acceptance_criteria out_of_scope; do
    local val="${!fld_name}"
    if ! jq -e 'type=="array"' <<< "$val" >/dev/null 2>&1; then
      exit_usage "create: $fld_name 必須是合法 JSON array"
    fi
  done
  for fld_name in verify_commands skills graduated_invariant; do
    local val="${!fld_name}"
    if ! jq -e 'type=="array"' <<< "$val" >/dev/null 2>&1; then
      exit_usage "create: $fld_name 必須是合法 JSON array"
    fi
  done

  if [[ -z "$slug" ]]; then
    slug="task"
  fi
  # slug 消毒：僅留字母數字與連字號
  slug="$(echo "$slug" | tr -c '[:alnum:]-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"

  # 業務線親和預填（org-design #2，b3d7）：assigned/reviewer 缺省時依
  # created_by（=IDENTITY）預填慣用 builder/reviewer；明文傳入者一律尊重、
  # 完全不進這個分支。記下實際發生的欄位，稍後寫進 affinity_prefill history。
  local prefilled_assigned="" prefilled_reviewer=""
  if [[ -z "$assigned" ]]; then
    prefilled_assigned=$(get_create_affinity_default "builder")
    [[ -n "$prefilled_assigned" ]] && assigned="$prefilled_assigned"
  fi
  if [[ -z "$reviewer" ]]; then
    prefilled_reviewer=$(get_create_affinity_default "reviewer")
    [[ -n "$prefilled_reviewer" ]] && reviewer="$prefilled_reviewer"
  fi

  # 公共財偵測（org-design-lines-20260707 決議 #3）：81aa 精準化後，
  # goal 需明述修改基建行為；context/deliverables 需指向 shared/ 實際路徑。
  local infra_field_text="$context $(jq -r '.[]?' <<<"$deliverables" 2>/dev/null | tr '\n' ' ')"
  local infra_rewrite_original_reviewer="" infra_rewrite_pattern=""
  if is_infra_change "$goal" "$infra_field_text"; then
    infra_rewrite_original_reviewer="$reviewer"
    infra_rewrite_pattern="$INFRA_MATCH_PATTERN"
    if [[ -n "$reviewer" && "$(lc "$reviewer")" != "bella" ]]; then
      echo "$LOG_PREFIX NOTICE: create 偵測到公共財變動（pattern=${infra_rewrite_pattern:-unknown}），reviewer 由 '$reviewer' 強制改為 'bella'（org-design #3 機械守門）" >&2
    elif [[ -z "$reviewer" ]]; then
      echo "$LOG_PREFIX NOTICE: create 偵測到公共財變動（pattern=${infra_rewrite_pattern:-unknown}），reviewer 預設強制填 'bella'" >&2
    fi
    reviewer="bella"
  fi

  local ts hex task_id filename
  ts="$(TZ=Asia/Taipei date +%Y%m%d-%H%M)"
  hex="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  task_id="${ts}-${hex}-${slug}"
  filename="${FATQ_ROOT}/pending/${task_id}.json"

  if [[ -e "$filename" ]]; then
    exit_state "create: 檔名衝突 $filename（極罕見，重試）"
  fi

  local history_entry
  history_entry=$(build_history_entry "create" "" "pending/")

  # 業務線親和預填可稽核（b3d7 deliverable）：只在真的有欄位被預填時才加這行，
  # 明文指定或親和表查無對應（極端情形）都不產生此條，避免噪音。
  local history_array="[$history_entry]"
  if [[ -n "$prefilled_assigned" || -n "$prefilled_reviewer" ]]; then
    local prefill_entry
    prefill_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" \
      --arg assigned "$prefilled_assigned" --arg reviewer "$prefilled_reviewer" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"affinity_prefill"}
       + (if $assigned != "" then {prefilled_assigned:$assigned} else {} end)
       + (if $reviewer != "" then {prefilled_reviewer:$reviewer} else {} end)')
    history_array="[$history_entry, $prefill_entry]"
  fi
  if [[ -n "$infra_rewrite_pattern" && "$(lc "$infra_rewrite_original_reviewer")" != "bella" ]]; then
    local infra_rewrite_entry
    infra_rewrite_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" \
      --arg pattern "$infra_rewrite_pattern" --arg original_reviewer "$infra_rewrite_original_reviewer" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"infra_gate_rewrite",
        pattern:$pattern, original_reviewer:$original_reviewer, forced_reviewer:"bella"}')
    history_array="$(jq -c --argjson entry "$infra_rewrite_entry" '. + [$entry]' <<<"$history_array")"
  fi

  jq -n \
    --arg task_id "$task_id" --arg slug "$slug" --arg status "pending" \
    --arg priority "$priority" --arg assigned "$assigned" --arg reviewer "$(lc "$reviewer")" \
    --argjson fast_track "$([ "$fast_track" == "true" ] && echo true || echo false)" \
    --arg created_at "$(now_iso)" --arg created_by "$IDENTITY" \
    --arg goal "$goal" --arg background "$background" --arg context "$context" \
    --argjson deliverables "$deliverables" --argjson acceptance_criteria "$acceptance_criteria" \
    --argjson out_of_scope "$out_of_scope" --arg review_focus "$review_focus" \
    --argjson verify_commands "$verify_commands" --argjson skills "$skills" \
    --argjson graduated_invariant "$graduated_invariant" \
    --argjson history "$history_array" \
    --argjson not_before null \
    --argjson project_id "$([ -n "$project_id" ] && jq -n --arg p "$project_id" '$p' || echo null)" \
    '{
      task_id: $task_id, slug: $slug, status: $status, priority: $priority,
      assigned: $assigned, reviewer: $reviewer, fast_track: $fast_track,
      created_at: $created_at, created_by: $created_by,
      goal: $goal, background: $background, context: $context,
      deliverables: $deliverables, acceptance_criteria: $acceptance_criteria,
      out_of_scope: $out_of_scope, verify_commands: $verify_commands,
      skills: $skills,
      graduated_invariant: $graduated_invariant,
      review_focus: $review_focus, not_before: $not_before,
      project_id: $project_id,
      history: $history
    }' > "$filename"

  if [[ -n "$infra_rewrite_pattern" && "$(lc "$infra_rewrite_original_reviewer")" != "bella" ]]; then
    write_infra_gate_rewrite_relay "$task_id" "$filename" "$IDENTITY" "$infra_rewrite_original_reviewer" "$infra_rewrite_pattern"
  fi

  # b8f4（Bella 紅線③）：project_id 給了就把 task_id 掛回專案檔的 task_ids——
  # 跟 web 層 PATCH member_bots/歸檔可能同時發生，走 with_project_lock（跨語言
  # mkdir 互斥鎖，mvp-server.ts 那邊的 PATCH 也走同一協定）避免 lost update。
  # task 本身已經落地在 pending/，這一步是「軟性」關聯——失敗只警告不回滾
  # （task 建立成功才是主要契約，專案 roll-up 關聯是次要，且 project_file
  # 已於上方預先驗證存在，這裡失敗機率極低）。
  if [[ -n "$project_id" ]]; then
    _append_task_to_project_locked() {
      local pf="$1" tid="$2"
      local tmp
      tmp="$(mktemp "$(dirname "$pf")/.fatq-cli.XXXXXX")"
      local entry
      entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg task_id "$tid" \
        '{ts:$ts, by:$by, via:"fatq-cli", action:"task_created", task_id:$task_id}')
      if ! jq --arg tid "$tid" --argjson entry "$entry" \
          '.task_ids = ((.task_ids // []) + [$tid]) | .history = ((.history // []) + [$entry])' \
          "$pf" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
      fi
      mv -f "$tmp" "$pf"
      return 0
    }
    if ! with_project_lock "$project_file" _append_task_to_project_locked "$task_id"; then
      echo "$LOG_PREFIX WARNING: task $task_id 已建立，但掛回 project $project_id 的 task_ids 失敗（專案 roll-up 可能短暫不完整，task 本身不受影響）" >&2
    fi
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "" "pending/" true
  else
    echo "$LOG_PREFIX create OK: $task_id -> pending/"
  fi
  exit 0
}

# ── 通用轉移執行器 ───────────────────────────────────────────────────────
# 在鎖內執行：重驗 (狀態/assigned/reviewer 條件) → append history → mv
# 因為 bash 函式無法乾淨回傳「原因字串」給外層做 exit code 分派，
# 這裡採用「callback 直接寫 TRANSFER_RESULT/TRANSFER_MSG 全域變數」的模式。
TRANSFER_RESULT=""
TRANSFER_MSG=""
TRANSFER_FROM=""
TRANSFER_VERIFY_OUT=""

# 純粹的 mutate+mv（假設呼叫端已在鎖內完成權限/狀態檢查）。供下面 claim/submit/
# verdict 的鎖內合一檢查+轉移共用，避免重複 jq/mv 邏輯。
_perform_mutation_locked() {
  local task_file="$1" from_dir="$2" to_dir="$3" action="$4" reason="${5:-}" issue_type="${6:-}"

  local history_entry
  history_entry=$(build_history_entry "$action" "${from_dir}/" "${to_dir}/" "$reason" "$issue_type")

  local dest_dir dest_file dir tmp
  dest_dir="${FATQ_ROOT}/${to_dir}"
  dest_file="${dest_dir}/$(basename "$task_file")"
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

  if ! jq --argjson entry "$history_entry" --arg status "$to_dir" \
      '.history = ((.history // []) + [$entry]) | .status = $status' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    TRANSFER_RESULT="error"
    TRANSFER_MSG="jq 寫入失敗（任務檔可能損毀）"
    return 4
  fi

  enforce_history_monotonic "$tmp"
  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -f "$task_file" "$dest_file"

  TRANSFER_RESULT="ok"
  TRANSFER_MSG="$dest_file"
  return 0
}

# ── claim 鎖內合一檢查+轉移（Bella QA REJECT ③：權限/狀態重驗必須跟轉移同一次
# 鎖內讀，不能在鎖外先讀一次——鎖外讀撞上「檔案剛好被贏家 mv 走」時，assigned
# 讀到空字串會被誤判成 E_PERM，但正確分類應該是 E_CONFLICT。§1.4/§1.5 鎖-重驗
# 的本意就是「整段檢查+動作在同一把鎖內」，不是只有最後的目錄重驗。） ────────
claim_locked() {
  local task_file="$1" identity="$2"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir assigned
  actual_dir="$(current_state_of "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file" 2>/dev/null)"
  TRANSFER_FROM="$actual_dir"

  if ! is_builder_pool "$identity"; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="claim: identity $identity 不得執行 claim（規則：builder 類轉移僅限 builder pool ∪ {mac-agent}）"
    return 3
  fi
  if [[ "$(lc "$assigned")" != "$identity" ]]; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="claim: identity $identity 不得執行 claim（規則：僅 task assigned 本人可 claim，此任務 assigned=${assigned:-<empty>}）"
    return 3
  fi
  if [[ "$actual_dir" != "pending" && "$actual_dir" != "rejected" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="claim: 任務目前在 ${actual_dir}/，claim 只允許 pending→in_progress 或 rejected→in_progress"
    return 4
  fi

  _perform_mutation_locked "$task_file" "$actual_dir" "in_progress" "claim" ""
}

# ── submit 鎖內合一檢查+轉移（同上理由） ─────────────────────────────────
submit_locked() {
  local task_file="$1" identity="$2"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir assigned
  actual_dir="$(current_state_of "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file" 2>/dev/null)"
  TRANSFER_FROM="$actual_dir"

  if ! is_builder_pool "$identity"; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="submit: identity $identity 不得執行 submit（規則：builder 類轉移僅限 builder pool ∪ {mac-agent}）"
    return 3
  fi
  if [[ "$(lc "$assigned")" != "$identity" ]]; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="submit: identity $identity 不得執行 submit（規則：僅 task assigned 本人可 submit，此任務 assigned=${assigned:-<empty>}）"
    return 3
  fi
  if [[ "$actual_dir" != "in_progress" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="submit: 任務目前在 ${actual_dir}/，submit 只允許 in_progress→review"
    return 4
  fi

  # verify gate 在鎖內跑（鎖住的檔案不會在檢查期間被移走）
  local verify_out verify_rc
  verify_out="$("$FATQ_VERIFY_SH" "$task_file" 2>&1)"
  verify_rc=$?
  if [[ $verify_rc -ne 0 ]]; then
    TRANSFER_RESULT="verify"
    TRANSFER_MSG="submit: verify gate 未過（fatq-verify.sh exit $verify_rc）"
    TRANSFER_VERIFY_OUT="$verify_out"
    return 5
  fi

  _perform_mutation_locked "$task_file" "$actual_dir" "review" "submit" ""
}

# ── verdict 鎖內合一檢查+轉移（同上理由） ────────────────────────────────
# args: task_file sub(approve|reject) identity reason
verdict_locked() {
  local task_file="$1" sub="$2" identity="$3" reason="${4:-}" issue_type="${5:-}"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir assigned reviewer
  actual_dir="$(current_state_of "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file" 2>/dev/null)"
  reviewer="$(jq -r '.reviewer // ""' "$task_file" 2>/dev/null)"
  TRANSFER_FROM="$actual_dir"

  if [[ "$(lc "$assigned")" == "$identity" ]]; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="verdict $sub: 禁自審——identity $identity 同時是此任務 assigned，不得審自己的任務"
    return 3
  fi
  local allowed=0
  if [[ "$(lc "$reviewer")" == "$identity" ]]; then
    allowed=1
  elif [[ "$identity" == "bella" || "$identity" == "anya" ]]; then
    allowed=1
  fi
  if [[ $allowed -eq 0 ]]; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="verdict $sub: identity $identity 不得執行 verdict $sub（規則：僅 task reviewer 欄位者($reviewer) 或 bella/anya 可 verdict）"
    return 3
  fi
  if [[ "$actual_dir" != "review" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="verdict $sub: 任務目前在 ${actual_dir}/，verdict 只允許 review→done/rejected"
    return 4
  fi

  if [[ "$sub" == "approve" ]]; then
    local verify_out verify_rc
    verify_out="$("$FATQ_VERIFY_SH" "$task_file" 2>&1)"
    verify_rc=$?
    if [[ $verify_rc -ne 0 ]]; then
      TRANSFER_RESULT="verify"
      TRANSFER_MSG="verdict approve: verify gate 未過（fatq-verify.sh exit $verify_rc），任一 fail 直接攔下不進 approve"
      TRANSFER_VERIFY_OUT="$verify_out"
      return 5
    fi
  fi

  local to_dir action
  if [[ "$sub" == "approve" ]]; then
    to_dir="done"; action="verdict_approve"
  else
    to_dir="rejected"; action="verdict_reject"
  fi
  _perform_mutation_locked "$task_file" "$actual_dir" "$to_dir" "$action" "$reason" "$issue_type"
}

# ── claim：pending|rejected → in_progress（§1.2 claim） ─────────────────
cmd_claim() {
  local task_id=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;   # 已由外層解析，略過（帶值，shift 2；Bella QA #2）
      --json) shift ;;   # 已由外層解析，略過（不帶值，shift 1）
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "claim: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "claim: 找不到任務 $task_id"

  # 權限＋狀態＋轉移全部在鎖內單次讀完成（Bella QA REJECT ③：鎖外預讀會在
  # 「檔案剛好被贏家 mv 走」時把 assigned 讀成空字串，誤判成 E_PERM 而非
  # E_CONFLICT——對 web 呼叫端是 403 vs 409 語義互換的實際傷害）。
  local rc
  with_task_lock "$task_file" claim_locked "$IDENTITY"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "claim: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "claim: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "claim: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${TRANSFER_FROM}/" "in_progress/" true
  else
    echo "$LOG_PREFIX claim OK: $task_id ${TRANSFER_FROM}/ -> in_progress/"
  fi
  exit 0
}

# ── submit：in_progress → review，內建 verify gate（§1.2 submit） ───────
cmd_submit() {
  local task_id=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;   # 已由外層解析，略過（帶值，shift 2；Bella QA #2）
      --json) shift ;;   # 已由外層解析，略過（不帶值，shift 1）
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "submit: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "submit: 找不到任務 $task_id"

  # 權限＋狀態＋verify gate＋轉移全部在鎖內單次讀完成（同 claim，Bella QA REJECT ③）
  local rc
  with_task_lock "$task_file" submit_locked "$IDENTITY"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "submit: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "submit: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "submit: $TRANSFER_MSG" ;;
    verify)
      err "$TRANSFER_MSG"
      echo "$TRANSFER_VERIFY_OUT" >&2
      if [[ $JSON_MODE -eq 1 ]]; then
        jq -n --arg code "E_VERIFY" --arg message "$TRANSFER_MSG" --arg detail "$TRANSFER_VERIFY_OUT" \
          '{ok:false, code:$code, message:$message, detail:$detail}'
      fi
      exit 5
      ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${TRANSFER_FROM}/" "review/" true
  else
    echo "$LOG_PREFIX submit OK: $task_id ${TRANSFER_FROM}/ -> review/ (verify gate passed)"
  fi
  exit 0
}

# ── verdict approve|reject：review → done|rejected（§1.2 verdict） ─────
cmd_verdict() {
  local sub="${1:-}"; shift || true
  [[ "$sub" != "approve" && "$sub" != "reject" ]] && exit_usage "verdict: 需要 approve 或 reject 子動作"

  local task_id="" reason="" issue_type=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --reason) reason="$2"; shift 2 ;;
      --issue_type) issue_type="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "verdict $sub: 需要 task_id"

  resolve_identity

  if [[ "$sub" == "reject" && -z "$reason" ]]; then
    exit_usage "verdict reject: --reason 必填"
  fi
  if [[ "$sub" == "reject" && -n "$issue_type" ]]; then
    case "$issue_type" in
      execution_error|spec_conflict|escalate_strategist|reviewer_error|duplicate|not_reproducible) ;;
      *) exit_usage "verdict reject: --issue_type 不支援：$issue_type" ;;
    esac
  fi

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "verdict $sub: 找不到任務 $task_id"

  # 權限＋狀態＋（approve 的）verify gate＋轉移全部在鎖內單次讀完成
  # （同 claim/submit，Bella QA REJECT ③）
  local rc
  with_task_lock "$task_file" verdict_locked "$sub" "$IDENTITY" "$reason" "$issue_type"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "verdict $sub: 任務檔在取鎖前已消失（已被移走）"
  fi
  local to_dir
  [[ "$sub" == "approve" ]] && to_dir="done" || to_dir="rejected"
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "verdict $sub: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "verdict $sub: $TRANSFER_MSG" ;;
    verify)
      err "$TRANSFER_MSG"
      echo "$TRANSFER_VERIFY_OUT" >&2
      if [[ $JSON_MODE -eq 1 ]]; then
        jq -n --arg code "E_VERIFY" --arg message "$TRANSFER_MSG" --arg detail "$TRANSFER_VERIFY_OUT" \
          '{ok:false, code:$code, message:$message, detail:$detail}'
      fi
      exit 5
      ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${TRANSFER_FROM}/" "${to_dir}/" true
  else
    echo "$LOG_PREFIX verdict $sub OK: $task_id ${TRANSFER_FROM}/ -> ${to_dir}/"
  fi
  exit 0
}

# ── reassign：任何狀態 → pending（僅 anya）（§1.2 reassign） ────────────
cmd_reassign() {
  local task_id="" new_assignee=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --to) new_assignee="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "reassign: 需要 task_id"

  resolve_identity

  if [[ "$IDENTITY" != "anya" ]]; then
    exit_perm "reassign: identity $IDENTITY 不得執行 reassign（規則：僅 anya 可 reassign，此為最高特助權限）"
  fi

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "reassign: 找不到任務 $task_id"

  local from_dir
  from_dir="$(current_state_of "$task_file")"
  if [[ "$from_dir" == "done" || "$from_dir" == "cancelled" || "$from_dir" == "wont_do" ]]; then
    exit_state "reassign: 任務已在終態 ${from_dir}/，不可 reassign"
  fi

  # reassign 邏輯：先更新 assigned 欄位（清空或改寫），再走轉移
  reassign_locked() {
    local task_file="$1" expected_from="$2"
    local actual_dir
    actual_dir="$(current_state_of "$task_file")"
    if [[ "$actual_dir" != "$expected_from" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務已不在 ${expected_from}/（現於 ${actual_dir}/）"
      return 6
    fi

    local history_entry
    history_entry=$(build_history_entry "reassign" "${expected_from}/" "pending/" "")

    local dest_dir dest_file dir tmp new_assignee_lc
    new_assignee_lc="$(lc "$new_assignee")"
    dest_dir="${FATQ_ROOT}/pending"
    dest_file="${dest_dir}/$(basename "$task_file")"
    dir=$(dirname "$task_file")
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

    if ! jq --argjson entry "$history_entry" --arg assigned "$new_assignee_lc" \
        '.history = ((.history // []) + [$entry]) | .status = "pending" | .assigned = $assigned' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi
    enforce_history_monotonic "$tmp"
    mv -f "$tmp" "$task_file"
    mkdir -p "$dest_dir"
    mv -f "$task_file" "$dest_file"
    TRANSFER_RESULT="ok"
    TRANSFER_MSG="$dest_file"
    return 0
  }

  local rc
  with_task_lock "$task_file" reassign_locked "$from_dir"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "reassign: 任務檔在取鎖前已消失"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "reassign: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "reassign: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "pending/" true
  else
    echo "$LOG_PREFIX reassign OK: $task_id ${from_dir}/ -> pending/ (assigned=${new_assignee:-<cleared>})"
  fi
  exit 0
}

# ── comment：append history，不動狀態（§1.2 comment） ──────────────────
cmd_comment() {
  local task_id="" text=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --text) text="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "comment: 需要 task_id"
  [[ -z "$text" ]] && exit_usage "comment: --text 必填"

  resolve_identity  # 任何已知 identity 可 comment

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "comment: 找不到任務 $task_id"

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  comment_locked() {
    local task_file="$1"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local history_entry dir tmp
    history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg text "$text" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"comment", text:$text}')
    dir=$(dirname "$task_file")
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    if ! jq --argjson entry "$history_entry" '.history = ((.history // []) + [$entry])' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi
    enforce_history_monotonic "$tmp"
    mv -f "$tmp" "$task_file"
    TRANSFER_RESULT="ok"
    return 0
  }

  local rc
  with_task_lock "$task_file" comment_locked
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "comment: 任務檔在取鎖前已消失"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "comment: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "comment: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "${from_dir}/" true
  else
    echo "$LOG_PREFIX comment OK: $task_id"
  fi
  exit 0
}

# ── attach：附件清單（d1c9，需求單附圖檔/文件）─────────────────────────
# 檔案本體由呼叫端（mvp-server.ts）驗證型別/大小並落地到 tasks/attachments/
# 之後才呼叫這裡——本指令只負責把「已經落地的檔案」metadata 記進 task JSON，
# 跟 comment 一樣是純附加、不動 status/不跨目錄 mv，同一套鎖+history 慣例。
cmd_attach() {
  local task_id="" file="" name="" mime="" size=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --file) file="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --mime) mime="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "attach: 需要 task_id"
  [[ -z "$file" ]] && exit_usage "attach: --file 必填（已落地的儲存檔名）"
  [[ -z "$name" ]] && exit_usage "attach: --name 必填（原始檔名，僅供顯示）"
  [[ -z "$mime" ]] && exit_usage "attach: --mime 必填"
  [[ -z "$size" ]] && exit_usage "attach: --size 必填（bytes）"
  [[ "$size" =~ ^[0-9]+$ ]] || exit_usage "attach: --size 必須是整數"
  # file 只接受安全落地檔名（呼叫端自己產生的 uuid.ext），不接受路徑字元——
  # 這裡是防禦第二層，呼叫端（mvp-server.ts）已經先擋過一次路徑穿越，這裡
  # 再確認一次，不讓任何非預期呼叫方式把路徑字元寫進 task JSON。
  [[ "$file" =~ ^[A-Za-z0-9._-]+$ ]] || exit_usage "attach: --file 含不允許字元（防路徑穿越）"

  resolve_identity  # 任何已知 identity 可 attach（同 comment；唯讀 identity=NULL 在 mvp-server.ts 那層已被 requireIdentity 擋掉，不會走到這裡）

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "attach: 找不到任務 $task_id"

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  attach_locked() {
    local task_file="$1"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local history_entry dir tmp
    history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg file "$file" --arg name "$name" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"attachment_added", file:$file, name:$name}')
    dir=$(dirname "$task_file")
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    if ! jq --argjson entry "$history_entry" --arg file "$file" --arg name "$name" --arg mime "$mime" \
        --argjson size "$size" --arg by "$IDENTITY" --arg ts "$(now_iso)" \
        '.attachments = ((.attachments // []) + [{file:$file, name:$name, mime:$mime, size:$size, uploaded_by:$by, uploaded_at:$ts}])
         | .history = ((.history // []) + [$entry])' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi
    enforce_history_monotonic "$tmp"
    mv -f "$tmp" "$task_file"
    TRANSFER_RESULT="ok"
    return 0
  }

  local rc
  with_task_lock "$task_file" attach_locked
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "attach: 任務檔在取鎖前已消失"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "attach: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "attach: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "${from_dir}/" true
  else
    echo "$LOG_PREFIX attach OK: $task_id ($name)"
  fi
  exit 0
}

# ── hold：寫 not_before（既有欄位，E8）（§1.2 hold） ────────────────────
cmd_hold() {
  local task_id="" until_val="" clear_flag=0
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --until) until_val="$2"; shift 2 ;;
      --clear) clear_flag=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "hold: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "hold: 找不到任務 $task_id"

  local assigned
  assigned="$(jq -r '.assigned // ""' "$task_file")"

  # 允許身份：anya + task assigned 本人
  if [[ "$IDENTITY" != "anya" && "$(lc "$assigned")" != "$IDENTITY" ]]; then
    exit_perm "hold: identity $IDENTITY 不得執行 hold（規則：僅 anya 或 task assigned 本人 ($assigned) 可 hold）"
  fi

  local new_not_before=""
  if [[ $clear_flag -eq 1 || "$until_val" == "now" ]]; then
    new_not_before="null"
  else
    [[ -z "$until_val" ]] && exit_usage "hold: 需要 --until <ISO8601> 或 --clear"
    # 驗證 ISO8601 格式（寬鬆檢查：可被 date -d 解析）
    if ! date -d "$until_val" >/dev/null 2>&1; then
      exit_usage "hold: --until 不是合法 ISO8601 時間：$until_val"
    fi
    new_not_before="\"$until_val\""
  fi

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  hold_locked() {
    local task_file="$1"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local history_entry dir tmp action_name
    if [[ "$new_not_before" == "null" ]]; then
      action_name="hold_clear"
    else
      action_name="hold"
    fi
    history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg action "$action_name" \
      --argjson nb "$new_not_before" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:$action, not_before:$nb}')
    dir=$(dirname "$task_file")
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    if ! jq --argjson entry "$history_entry" --argjson nb "$new_not_before" \
        '.history = ((.history // []) + [$entry]) | .not_before = $nb' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi
    enforce_history_monotonic "$tmp"
    mv -f "$tmp" "$task_file"
    TRANSFER_RESULT="ok"
    return 0
  }

  local rc
  with_task_lock "$task_file" hold_locked
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "hold: 任務檔在取鎖前已消失"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "hold: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "hold: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "${from_dir}/" true
  else
    echo "$LOG_PREFIX hold OK: $task_id not_before=${until_val:-cleared}"
  fi
  exit 0
}

# ── update-field：受控欄位更新（e5b8：skills / graduated_invariant） ─────
cmd_update_field() {
  local task_id="" field="" value_json=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --value) value_json="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  field="${positional[1]:-}"
  [[ -z "$task_id" ]] && exit_usage "update-field: 需要 task_id"
  [[ -z "$field" ]] && exit_usage "update-field: 需要 field"
  [[ -z "$value_json" ]] && exit_usage "update-field: --value 必填（JSON array）"

  case "$field" in
    skills|graduated_invariant) ;;
    *) exit_usage "update-field: 只允許 skills 或 graduated_invariant，得到 $field" ;;
  esac
  if ! jq -e 'type=="array"' <<< "$value_json" >/dev/null 2>&1; then
    exit_usage "update-field: --value 必須是合法 JSON array"
  fi

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "update-field: 找不到任務 $task_id"

  local from_dir assigned reviewer created_by
  from_dir="$(current_state_of "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file")"
  reviewer="$(jq -r '.reviewer // ""' "$task_file")"
  created_by="$(jq -r '.created_by // ""' "$task_file")"

  if [[ "$field" == "skills" ]]; then
    # skills 由建單/調度側標注；允許 Anya 與建單者補欄，不允許 builder/reviewer 自報膨脹。
    if [[ "$IDENTITY" != "anya" && "$(lc "$created_by")" != "$IDENTITY" ]]; then
      exit_perm "update-field skills: 僅 anya 或 created_by($created_by) 可更新"
    fi
  else
    # graduated_invariant 可由建單者、builder submit 前、reviewer approve 前補填。
    local allowed=0
    [[ "$IDENTITY" == "anya" || "$(lc "$created_by")" == "$IDENTITY" ]] && allowed=1
    [[ "$from_dir" == "in_progress" && "$(lc "$assigned")" == "$IDENTITY" ]] && allowed=1
    if [[ "$from_dir" == "review" ]]; then
      [[ "$(lc "$reviewer")" == "$IDENTITY" || "$IDENTITY" == "bella" || "$IDENTITY" == "anya" ]] && allowed=1
    fi
    [[ "$allowed" -eq 1 ]] || exit_perm "update-field graduated_invariant: 僅建單者、assigned(in_progress) 或 reviewer(review) 可更新"
  fi

  update_field_locked() {
    local task_file="$1"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local history_entry dir tmp
    history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg field "$field" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"update_field", field:$field}')
    dir=$(dirname "$task_file")
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    if ! jq --arg field "$field" --argjson value "$value_json" --argjson entry "$history_entry" \
        '.[$field] = $value | .history = ((.history // []) + [$entry])' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi
    enforce_history_monotonic "$tmp"
    mv -f "$tmp" "$task_file"
    TRANSFER_RESULT="ok"
    return 0
  }

  local rc
  with_task_lock "$task_file" update_field_locked
  rc=$?
  if [[ $rc -eq 9 ]]; then
    exit_conflict "update-field: 任務檔在取鎖前已消失"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "update-field: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "update-field: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "${from_dir}/" true
  else
    echo "$LOG_PREFIX update-field OK: $task_id $field"
  fi
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Part 2 — approval 子命令組（handover/fatq-cli-and-approval-spec-20260707.md §2）
# ═══════════════════════════════════════════════════════════════════════════

APPROVAL_DOMAINS=(security funds data cross-bot-infra)

is_valid_domain() {
  local d="$1" x
  for x in "${APPROVAL_DOMAINS[@]}"; do [[ "$x" == "$d" ]] && return 0; done
  return 1
}

# approvers 名單（§2.4 MVP：四域 approver 全＝老兔）
domain_approvers_json() {
  jq -n '["laotu"]'
}

# 接受相對式（"48h"/"24h"）或絕對 ISO8601；回傳絕對 ISO8601（+08:00）
parse_expires() {
  local v="$1"
  if [[ "$v" =~ ^([0-9]+)h$ ]]; then
    local hours="${BASH_REMATCH[1]}" now
    now=$(now_epoch)
    TZ=Asia/Taipei date -d "@$((now + hours*3600))" '+%Y-%m-%dT%H:%M:%S+08:00'
    return 0
  fi
  if date -d "$v" >/dev/null 2>&1; then
    echo "$v"
    return 0
  fi
  return 1
}

# ── approval request：任何狀態 → approval_pending（§2.5） ────────────────
cmd_approval_request() {
  local task_id="" domain="" expires_raw="" reason=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --domain) domain="$2"; shift 2 ;;
      --expires) expires_raw="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "approval request: 需要 task_id"
  [[ -z "$domain" ]] && exit_usage "approval request: --domain 必填（${APPROVAL_DOMAINS[*]}）"
  if ! is_valid_domain "$domain"; then
    exit_usage "approval request: --domain 必須是 ${APPROVAL_DOMAINS[*]} 之一，得到 $domain"
  fi
  [[ -z "$expires_raw" ]] && exit_usage "approval request: --expires 必填（如 48h 或 ISO8601）"
  local expires_iso
  if ! expires_iso="$(parse_expires "$expires_raw")"; then
    exit_usage "approval request: --expires 無法解析：$expires_raw"
  fi

  resolve_identity  # 任何已知 identity 可 request（§2.5）

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "approval request: 找不到任務 $task_id"

  local rc
  with_task_lock "$task_file" approval_request_locked "$IDENTITY" "$domain" "$expires_iso" "$reason"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "approval request: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "approval request: $TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "approval request: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${TRANSFER_FROM}/" "approval_pending/" true
  else
    echo "$LOG_PREFIX approval request OK: $task_id ${TRANSFER_FROM}/ -> approval_pending/ (domain=$domain, expires=$expires_iso)"
  fi
  exit 0
}

approval_request_locked() {
  local task_file="$1" identity="$2" domain="$3" expires_iso="$4" reason="$5"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir
  actual_dir="$(current_state_of "$task_file")"
  TRANSFER_FROM="$actual_dir"
  if [[ "$actual_dir" == "approval_pending" || "$actual_dir" == "done" || "$actual_dir" == "cancelled" || "$actual_dir" == "wont_do" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="approval request: 任務目前在 ${actual_dir}/，不可再次送審或審批已終態任務"
    return 4
  fi

  local approvers_json history_entry
  approvers_json="$(domain_approvers_json)"
  history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --arg domain "$domain" \
    --arg expires "$expires_iso" --arg reason "$reason" --arg from "${actual_dir}/" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:"approval_request", from:$from, to:"approval_pending/", domain:$domain, expires:$expires, reason:$reason}')

  local approval_obj
  approval_obj=$(jq -n --arg status "pending" --arg domain "$domain" --arg requested_by "$identity" \
    --argjson approvers "$approvers_json" --arg expires "$expires_iso" --arg return_state "$actual_dir" \
    --arg reason "$reason" \
    '{status:$status, domain:$domain, requested_by:$requested_by, approvers:$approvers,
      decided_by:null, decided_at:null, decision:null, reason:$reason, evidence:null,
      expires:$expires, return_state:$return_state}')

  local dest_dir dest_file dir tmp
  dest_dir="${FATQ_ROOT}/approval_pending"
  dest_file="${dest_dir}/$(basename "$task_file")"
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

  if ! jq --argjson entry "$history_entry" --argjson approval "$approval_obj" \
      '.history = ((.history // []) + [$entry]) | .status = "approval_pending" | .approval = $approval' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"
    return 4
  fi

  enforce_history_monotonic "$tmp"
  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -f "$task_file" "$dest_file"
  TRANSFER_RESULT="ok"; TRANSFER_MSG="$dest_file"
  return 0
}

# ── approval approve|reject：approval_pending → return_state|rejected（§2.5） ──
cmd_approval_verdict() {
  local sub="$1"; shift
  local task_id="" evidence="" reason=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --evidence) evidence="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "approval $sub: 需要 task_id"
  [[ -z "$evidence" ]] && exit_usage "approval $sub: --evidence 必填（決策憑據，如 tg:<message_id> 或 web:<request-id>）"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "approval $sub: 找不到任務 $task_id"

  local rc
  with_task_lock "$task_file" approval_verdict_locked "$sub" "$IDENTITY" "$evidence" "$reason"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "approval $sub: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "approval $sub: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "approval $sub: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "approval_pending/" "${TRANSFER_TO}/" true
  else
    echo "$LOG_PREFIX approval $sub OK: $task_id approval_pending/ -> ${TRANSFER_TO}/"
  fi
  exit 0
}

TRANSFER_TO=""

approval_verdict_locked() {
  local task_file="$1" sub="$2" identity="$3" evidence="$4" reason="$5"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir approvers_json status
  actual_dir="$(current_state_of "$task_file")"
  approvers_json="$(jq -c '.approval.approvers // []' "$task_file" 2>/dev/null)"
  status="$(jq -r '.approval.status // ""' "$task_file" 2>/dev/null)"

  # 先權限後狀態（沿 Part 1 mac-bridge 20260707-120500 裁決③c 一致做法）
  if ! jq -e --arg id "$identity" '. as $a | ($a // []) | index($id) != null' <<<"$approvers_json" >/dev/null 2>&1; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="approval $sub: identity $identity 不得執行（規則：僅 task approval.approvers($approvers_json) 可決策）"
    return 3
  fi

  if [[ "$actual_dir" != "approval_pending" || "$status" != "pending" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="approval $sub: 任務目前在 ${actual_dir}/（approval.status=$status），只有 approval_pending/+status=pending 可決策"
    return 4
  fi

  local return_state decision
  return_state="$(jq -r '.approval.return_state // "pending"' "$task_file")"
  if [[ "$sub" == "approve" ]]; then
    decision="approve"
    TRANSFER_TO="$return_state"
  else
    decision="reject"
    TRANSFER_TO="rejected"
  fi

  local history_entry
  history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --arg decision "$decision" \
    --arg evidence "$evidence" --arg reason "$reason" --arg to "${TRANSFER_TO}/" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:("approval_" + $decision), from:"approval_pending/", to:$to, evidence:$evidence, reason:$reason}')

  local dest_dir dest_file dir tmp new_status
  [[ "$sub" == "approve" ]] && new_status="approved" || new_status="rejected"
  dest_dir="${FATQ_ROOT}/${TRANSFER_TO}"
  dest_file="${dest_dir}/$(basename "$task_file")"
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

  if ! jq --argjson entry "$history_entry" --arg status "$([ "$sub" == "approve" ] && echo "$return_state" || echo "rejected")" \
      --arg approval_status "$new_status" --arg decided_by "$identity" --arg decided_at "$(now_iso)" \
      --arg decision "$decision" --arg evidence "$evidence" --arg reason "$reason" \
      '.history = ((.history // []) + [$entry])
       | .status = $status
       | .approval.status = $approval_status
       | .approval.decided_by = $decided_by
       | .approval.decided_at = $decided_at
       | .approval.decision = $decision
       | .approval.evidence = $evidence
       | .approval.reason = (if $reason == "" then .approval.reason else $reason end)' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"
    return 4
  fi

  enforce_history_monotonic "$tmp"
  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -f "$task_file" "$dest_file"

  # reject 通知 requester（含 reason，§2.5）——approve 不需要，任務直接恢復原流程
  # AC3 硬要求：任一 approval 通知路徑必產 TG relay 檔，不得因查無映射就靜默丟
  # （Bella QA REJECT：requester=anya 時原本 rc=0 但零 relay 產出，已修）。
  # ⚠️FATQ_RELAY_DIR 預設是「真」relay/，不像 FATQ_ROOT 那樣天然隨 fixture 隔離——
  # 過去 fixture/互動測試若只覆寫 FATQ_ROOT 忘了同時覆寫 FATQ_RELAY_DIR，reject 通知
  # 會真的送到 TG（a1d5 視覺測試事故，7/8）。同 fatq-dispatch.sh 的 mm_post 慣例，
  # 補上 FATQ_MATTERMOST_DISABLE 閘門：=1 時完全跳過寫檔，測試/互動 QA 該設就設。
  if [[ "$sub" == "reject" ]]; then
    local requester relay_text relay_content relay_file recipient handle
    requester="$(jq -r '.approval.requested_by // ""' "$dest_file" 2>/dev/null)"
    local mapped
    if [[ -n "$requester" ]] && mapped=$(lookup_bot_for_relay "$requester"); then
      recipient="${mapped%%|*}"; handle="${mapped##*|}"
      relay_text="[FATQ 審批·REJECT] 任務 $(jq -r '.task_id' "$dest_file") 的審批被 REJECT。\n原因：${reason:-<未填>}\n任務檔：${dest_file}\n${handle}"
    else
      # 查無映射（requester 為空或不在名單）→ fallback 給 Anya 人工轉達，不得靜默丟
      recipient=""
      relay_text="[FATQ 審批·REJECT] 任務 $(jq -r '.task_id' "$dest_file") 的審批被 REJECT，但 requester='${requester:-<空>}' 查無 bot 映射，無法直接通知。\n原因：${reason:-<未填>}\n任務檔：${dest_file}\n@Anyachl_bot 請人工轉達 ${requester:-<空>}。"
    fi
    if [[ "${FATQ_MATTERMOST_DISABLE:-0}" != "1" ]]; then
      relay_content=$(jq -n --arg from "fatq-cli" --arg recipient "$recipient" --arg text "$relay_text" \
        --arg ts "$(now_iso)" --arg tid "$(jq -r '.task_id' "$dest_file")" \
        '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}')
      relay_file="fatq-approval-reject-$(date +%s%N 2>/dev/null || echo $$).json"
      mkdir -p "$FATQ_RELAY_DIR" 2>/dev/null || true
      printf '%s' "$relay_content" > "${FATQ_RELAY_DIR}/${relay_file}" 2>/dev/null || true
    fi
  fi

  TRANSFER_RESULT="ok"; TRANSFER_MSG="$dest_file"
  return 0
}

# bot 名稱映射（Bella QA REJECT：完整鏡像 fatq-dispatch.sh §4.3 的 BOT_MAP，
# 不再是精簡子集——原本漏 anya/interns 導致 requester=anya 時查無映射、
# 通知靜默丟失，違反 AC3。查無映射時回傳非 0，呼叫端改為 fallback 給 Anya
# 人工轉達，不再靜默略過）
lookup_bot_for_relay() {
  local raw="$1" lower
  lower=$(lc "$raw")
  case "$lower" in
    anna) echo "anna|@annadesu_bot" ;;
    sancai) echo "sancai|@threedishes_bot" ;;
    eric|ron-builder) echo "eric|@Ron0002_bot" ;;
    bella) echo "Bella|@Bellalovechl_Bot" ;;
    yitang) echo "yitang|@onesoup_bot" ;;
    ron-reviewer) echo "ron-reviewer|@ron0003_bot" ;;
    twinkle|星星人) echo "twinkle|@TwinkleCHL_bot" ;;
    interns) echo "interns|@WuTung_bot" ;;
    anya) echo "|@Anyachl_bot" ;;  # 不在 pod BOTS，recipient 留空，靠 text @handle 由常駐 plugin 自撿（同 dispatch 慣例）
    *) return 1 ;;
  esac
}

# ── approval expire：逾時回收（僅 anya，§2.6，由 cron 通知後人工執行） ──
cmd_approval_expire() {
  local task_id=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "approval expire: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "approval expire: 找不到任務 $task_id"

  local rc
  with_task_lock "$task_file" approval_expire_locked "$IDENTITY"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "approval expire: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "approval expire: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "approval expire: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "approval_pending/" "${TRANSFER_TO}/" true
  else
    echo "$LOG_PREFIX approval expire OK: $task_id approval_pending/ -> ${TRANSFER_TO}/ (status=expired, decision=null)"
  fi
  exit 0
}

approval_expire_locked() {
  local task_file="$1" identity="$2"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  # 僅 anya 可執行回收（§2.6：cron 只偵測通知，回收動作是人親手執行）
  if [[ "$identity" != "anya" ]]; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="approval expire: identity $identity 不得執行（規則：僅 anya 可執行逾時回收，§2.6）"
    return 3
  fi

  local actual_dir status expires_iso expires_epoch now
  actual_dir="$(current_state_of "$task_file")"
  status="$(jq -r '.approval.status // ""' "$task_file" 2>/dev/null)"
  expires_iso="$(jq -r '.approval.expires // ""' "$task_file" 2>/dev/null)"
  now=$(now_epoch)
  expires_epoch=$(date -d "$expires_iso" +%s 2>/dev/null || echo "$now")

  if [[ "$actual_dir" != "approval_pending" || "$status" != "pending" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="approval expire: 任務目前在 ${actual_dir}/（approval.status=$status），只有 approval_pending/+status=pending 可回收"
    return 4
  fi
  if [[ "$expires_epoch" -gt "$now" ]]; then
    TRANSFER_RESULT="state"
    TRANSFER_MSG="approval expire: 尚未逾時（expires=$expires_iso），不可提前回收"
    return 4
  fi

  local return_state history_entry
  return_state="$(jq -r '.approval.return_state // "pending"' "$task_file")"
  TRANSFER_TO="$return_state"
  history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --arg to "${return_state}/" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:"approval_expire", from:"approval_pending/", to:$to}')

  local dest_dir dest_file dir tmp
  dest_dir="${FATQ_ROOT}/${return_state}"
  dest_file="${dest_dir}/$(basename "$task_file")"
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

  if ! jq --argjson entry "$history_entry" --arg status "$return_state" \
      '.history = ((.history // []) + [$entry])
       | .status = $status
       | .approval.status = "expired"
       | .approval.decision = null' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"
    return 4
  fi

  enforce_history_monotonic "$tmp"
  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -f "$task_file" "$dest_file"
  TRANSFER_RESULT="ok"; TRANSFER_MSG="$dest_file"
  return 0
}

# ── approval：子命令分派（§1.2 main 表新增） ────────────────────────────
cmd_approval() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    request) cmd_approval_request "$@" ;;
    approve) cmd_approval_verdict "approve" "$@" ;;
    reject) cmd_approval_verdict "reject" "$@" ;;
    expire) cmd_approval_expire "$@" ;;
    *) exit_usage "approval: 未知子命令 '$sub'（需要 request|approve|reject|expire）" ;;
  esac
}

# 凍結契約 query --json schema（§1.4 尾段，2026-07-07 補）：九欄 + updated_at 衍生欄位。
# 只增不改不刪（forward-compatible）；history 預設不含，--full 才帶。
# $1=task_file $2=state $3=full(0/1)
task_to_schema_json() {
  local f="$1" state="$2" full="$3"
  jq --arg state "$state" --arg full "$full" '
    {
      task_id: (.task_id // .id // null),
      state: $state,
      assigned: (.assigned // .assigned_to // null),
      reviewer: (.reviewer // null),
      priority: (.priority // null),
      goal: (.goal // null),
      not_before: (.not_before // null),
      approval: (.approval // null),
      created_at: (.created_at // null),
      updated_at: ((.history // []) as $h | if ($h|length) > 0 then ($h[-1].ts // null) else null end)
    }
    + (if $full == "1" then {history: (.history // [])} else {} end)
  ' "$f"
}

# ── query：唯讀（§1.2 query） ────────────────────────────────────────────
cmd_query() {
  local task_id="" state_filter="" assigned_filter="" full_flag=0
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --task-id) task_id="$2"; shift 2 ;;
      --state) state_filter="$2"; shift 2 ;;
      --assigned) assigned_filter="$2"; shift 2 ;;
      --full) full_flag=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ -z "$task_id" ]] && task_id="${positional[0]:-}"

  # query 不需要身份聲明其實 spec 沒有明講 query 要不要 --as；「任何人」允許，
  # 但為一致性仍嘗試 resolve identity（若未帶則不強制，因為 query 是唯讀便利工具）
  if [[ -n "${CLI_AS:-}" || -n "${FATQ_IDENTITY:-}" ]]; then
    resolve_identity
  fi

  if [[ -n "$task_id" ]]; then
    local task_file
    task_file="$(find_task_file "$task_id")"
    if [[ -z "$task_file" ]]; then
      exit_notfound "query: 找不到任務 $task_id"
    fi
    if [[ $JSON_MODE -eq 1 ]]; then
      local item
      item="$(task_to_schema_json "$task_file" "$(current_state_of "$task_file")" "$full_flag")"
      jq -n --argjson item "$item" '{ok:true, count:1, tasks:[$item]}'
    else
      cat "$task_file"
    fi
    exit 0
  fi

  # 列表模式：--state / --assigned 篩選（過濾參數不影響單筆 schema）
  local results="[]"
  local search_dirs=("${CORE_STATE_DIRS[@]}")
  if [[ -n "$state_filter" ]]; then
    search_dirs=("$state_filter")
  fi

  for d in "${search_dirs[@]}"; do
    local dir_path="${FATQ_ROOT}/${d}"
    [[ -d "$dir_path" ]] || continue
    while IFS= read -r -d '' f; do
      if ! jq empty "$f" >/dev/null 2>&1; then
        continue  # non-task JSON（壞 JSON），E1：略過
      fi
      if ! jq -e '(.task_id // .id // empty) != ""' "$f" >/dev/null 2>&1; then
        continue  # 無 task_id/id，E1：非 task（drafts/proposals 混居），略過不解析
      fi
      if [[ -n "$assigned_filter" ]]; then
        local a
        a="$(jq -r '.assigned // .assigned_to // ""' "$f")"
        [[ "$(lc "$a")" != "$(lc "$assigned_filter")" ]] && continue
      fi
      local item
      item="$(task_to_schema_json "$f" "$d" "$full_flag")"
      results=$(jq --argjson item "$item" '. + [$item]' <<< "$results")
    done < <(find "$dir_path" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
  done

  if [[ $JSON_MODE -eq 1 ]]; then
    jq --argjson tasks "$results" '{ok:true, count:($tasks|length), tasks:$tasks}' <<< "{}"
  else
    jq -r '.[] | "\(.task_id // "?")\t\(.state)\t\(.assigned // "-")\t\(.priority // "-")"' <<< "$results"
  fi
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════
# 主程式：解析全域 flag（--as / --json）後 dispatch 子命令
# ═══════════════════════════════════════════════════════════════════════

main() {
  local sub="${1:-}"
  [[ -z "$sub" ]] && exit_usage "需要子命令：create|claim|submit|verdict|reassign|comment|query|hold|update-field|approval"
  shift || true

  # 掃過全部 argv 抓 --as / --json（不消耗，讓子命令自己的 loop 也能看到並跳過）
  CLI_AS=""
  local args=("$@")
  local i
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--as" ]]; then
      CLI_AS="${args[$((i+1))]:-}"
    elif [[ "${args[$i]}" == "--json" ]]; then
      JSON_MODE=1
    fi
  done

  case "$sub" in
    create) cmd_create "$@" ;;
    claim) cmd_claim "$@" ;;
    submit) cmd_submit "$@" ;;
    verdict) cmd_verdict "$@" ;;
    reassign) cmd_reassign "$@" ;;
    comment) cmd_comment "$@" ;;
    attach) cmd_attach "$@" ;;
    query) cmd_query "$@" ;;
    hold) cmd_hold "$@" ;;
    update-field) cmd_update_field "$@" ;;
    approval) cmd_approval "$@" ;;
    *)
      exit_usage "未知子命令：$sub"
      ;;
  esac
}

main "$@"

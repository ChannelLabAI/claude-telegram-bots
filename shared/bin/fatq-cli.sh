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
#              reassign, comment, query, hold
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
FATQ_DISPATCH_AFFINITY="${FATQ_DISPATCH_AFFINITY:-/home/oldrabbit/.claude-bots/shared/lib/dispatch-affinity.json}"  # org-design #3 公共財偵測表
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"  # approval reject 通知 requester 用（§2.5，request 的通知交給 dispatch/watch 偵測 approval_pending 產生）

# §1.2 核心狀態目錄（CLI 狀態機只認這些 + approval_pending，E1）
CORE_STATE_DIRS=(pending in_progress review done rejected cancelled wont_do approval_pending)

# 附加身份名單（E5：team-config.json 之外，spec 明文列出）
EXTRA_IDENTITIES=(mac-agent laotu)

LOG_PREFIX="[fatq-cli]"

# ── 小工具 ──────────────────────────────────────────────────────────────
lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

now_iso() {
  if [[ -n "$FATQ_NOW_ISO" ]]; then
    echo "$FATQ_NOW_ISO"
    return
  fi
  TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"
}

now_epoch() {
  if [[ -n "$FATQ_NOW_ISO" ]]; then
    date -d "$FATQ_NOW_ISO" +%s 2>/dev/null && return
  fi
  date +%s
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
# 合法身份名單 = team-config.json 的 bot 名單 ∪ {mac-agent, laotu}
# team-config.json 結構：assistants[].state_dir ∪ shared_pools.*[].state_dir
known_identities() {
  jq -r '
    [ (.assistants // [])[].state_dir,
      (.shared_pools // {} | to_entries[] | .value[]?.state_dir) ]
    | .[]
  ' "$FATQ_TEAM_CONFIG" 2>/dev/null
}

is_known_identity() {
  local ident_lc
  ident_lc="$(lc "$1")"
  for extra in "${EXTRA_IDENTITIES[@]}"; do
    [[ "$(lc "$extra")" == "$ident_lc" ]] && return 0
  done
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
  local ident_lc
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
  local ident_lc
  ident_lc="$(lc "$1")"
  [[ "$ident_lc" == "mac-agent" ]] && return 0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$(lc "$name")" == "$ident_lc" ]] && return 0
  done < <(builder_pool_identities)
  return 1
}

# ── 公共財路徑偵測（org-design-lines-20260707 決議 #3，create 建單補遺） ──
# goal/context/deliverables 文字命中 shared/lib/dispatch-affinity.json 的
# infra_patterns 任一子字串 → 視為公共財變動。防漏優先於防誤（機械守門，
# 寧可誤觸發不漏放），命中即強制 reviewer=bella，不論呼叫端傳了什麼。
is_infra_change() {
  local text="$1"
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if [[ "$text" == *"$pattern"* ]]; then
      return 0
    fi
  done < <(jq -r '.infra_patterns[]?' "$FATQ_DISPATCH_AFFINITY" 2>/dev/null)
  return 1
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
    exit_perm "identity 未知：$IDENTITY 不在 team-config.json 名單或附加名單 {mac-agent, laotu} 中"
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

# 原子性寫入 JSON（同目錄 tmp → mv 覆蓋），$1=task_file $2=jq filter $3.. = jq --argjson 等額外參數已包在 filter 呼叫端
atomic_write_json() {
  local task_file="$1" tmp dir
  shift
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
  if ! jq "$@" "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$task_file"
  return 0
}

# 建立標準化 history 條目 JSON（§1.4.3）
# args: action from to [reason]
build_history_entry() {
  local action="$1" from="$2" to="$3" reason="${4:-}"
  if [[ -n "$reason" ]]; then
    jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg action "$action" \
      --arg from "$from" --arg to "$to" --arg reason "$reason" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:$action, from:$from, to:$to, reason:$reason}'
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
  local slug=""

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
      --slug) slug="$2"; shift 2 ;;
      --as) shift 2 ;;   # 已由外層解析，略過（帶值，shift 2）
      --json) shift ;;   # 已由外層解析，略過（不帶值，shift 1；Bella QA #1）
      *) exit_usage "create: 未知參數 $1" ;;
    esac
  done

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
  if ! jq -e 'type=="array"' <<< "$verify_commands" >/dev/null 2>&1; then
    exit_usage "create: verify_commands 必須是合法 JSON array"
  fi

  if [[ -z "$slug" ]]; then
    slug="task"
  fi
  # slug 消毒：僅留字母數字與連字號
  slug="$(echo "$slug" | tr -c '[:alnum:]-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"

  # 公共財偵測（org-design-lines-20260707 決議 #3）：goal/context/deliverables
  # 命中 infra_patterns → 強制 reviewer=bella，覆蓋呼叫端傳入的任何值
  local infra_probe_text="$goal $context $(jq -r '.[]?' <<<"$deliverables" 2>/dev/null | tr '\n' ' ')"
  if is_infra_change "$infra_probe_text"; then
    if [[ -n "$reviewer" && "$(lc "$reviewer")" != "bella" ]]; then
      echo "$LOG_PREFIX NOTICE: create 偵測到公共財變動（shared/crontab/systemd/gateway 等關鍵字），reviewer 由 '$reviewer' 強制改為 'bella'（org-design #3 機械守門）" >&2
    elif [[ -z "$reviewer" ]]; then
      echo "$LOG_PREFIX NOTICE: create 偵測到公共財變動，reviewer 預設強制填 'bella'" >&2
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

  jq -n \
    --arg task_id "$task_id" --arg slug "$slug" --arg status "pending" \
    --arg priority "$priority" --arg assigned "$assigned" --arg reviewer "$(lc "$reviewer")" \
    --argjson fast_track "$([ "$fast_track" == "true" ] && echo true || echo false)" \
    --arg created_at "$(now_iso)" --arg created_by "$IDENTITY" \
    --arg goal "$goal" --arg background "$background" --arg context "$context" \
    --argjson deliverables "$deliverables" --argjson acceptance_criteria "$acceptance_criteria" \
    --argjson out_of_scope "$out_of_scope" --arg review_focus "$review_focus" \
    --argjson verify_commands "$verify_commands" \
    --argjson history "[$history_entry]" \
    --argjson not_before null \
    '{
      task_id: $task_id, slug: $slug, status: $status, priority: $priority,
      assigned: $assigned, reviewer: $reviewer, fast_track: $fast_track,
      created_at: $created_at, created_by: $created_by,
      goal: $goal, background: $background, context: $context,
      deliverables: $deliverables, acceptance_criteria: $acceptance_criteria,
      out_of_scope: $out_of_scope, verify_commands: $verify_commands,
      review_focus: $review_focus, not_before: $not_before,
      history: $history
    }' > "$filename"

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
  local task_file="$1" from_dir="$2" to_dir="$3" action="$4" reason="${5:-}"

  local history_entry
  history_entry=$(build_history_entry "$action" "${from_dir}/" "${to_dir}/" "$reason")

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
  local task_file="$1" sub="$2" identity="$3" reason="${4:-}"

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
  _perform_mutation_locked "$task_file" "$actual_dir" "$to_dir" "$action" "$reason"
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

  local task_id="" reason=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --reason) reason="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "verdict $sub: 需要 task_id"

  resolve_identity

  if [[ "$sub" == "reject" && -z "$reason" ]]; then
    exit_usage "verdict reject: --reason 必填"
  fi

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "verdict $sub: 找不到任務 $task_id"

  # 權限＋狀態＋（approve 的）verify gate＋轉移全部在鎖內單次讀完成
  # （同 claim/submit，Bella QA REJECT ③）
  local rc
  with_task_lock "$task_file" verdict_locked "$sub" "$IDENTITY" "$reason"
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

  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -f "$task_file" "$dest_file"

  # reject 通知 requester（含 reason，§2.5）——approve 不需要，任務直接恢復原流程
  if [[ "$sub" == "reject" ]]; then
    local requester relay_text relay_content relay_file
    requester="$(jq -r '.approval.requested_by // ""' "$dest_file" 2>/dev/null)"
    if [[ -n "$requester" ]]; then
      local mapped recipient handle
      if mapped=$(lookup_bot_for_relay "$requester"); then
        recipient="${mapped%%|*}"; handle="${mapped##*|}"
        relay_text="[FATQ 審批·REJECT] 任務 $(jq -r '.task_id' "$dest_file") 的審批被 REJECT。\n原因：${reason:-<未填>}\n任務檔：${dest_file}\n${handle}"
        relay_content=$(jq -n --arg from "fatq-cli" --arg recipient "$recipient" --arg text "$relay_text" \
          --arg ts "$(now_iso)" --arg tid "$(jq -r '.task_id' "$dest_file")" \
          '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}')
        relay_file="fatq-approval-reject-$(date +%s%N 2>/dev/null || echo $$).json"
        mkdir -p "$FATQ_RELAY_DIR" 2>/dev/null || true
        printf '%s' "$relay_content" > "${FATQ_RELAY_DIR}/${relay_file}" 2>/dev/null || true
      fi
    fi
  fi

  TRANSFER_RESULT="ok"; TRANSFER_MSG="$dest_file"
  return 0
}

# 極簡 bot 名稱映射（沿 fatq-dispatch.sh §4.3 的精神，供 approval reject 通知用；
# 查無映射時回傳非 0，呼叫端略過通知而非報錯——approval 決策本身不因通知失敗而失敗）
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
    *) exit_usage "approval: 需要子動作 request|approve|reject|expire" ;;
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
  [[ -z "$sub" ]] && exit_usage "需要子命令：create|claim|submit|verdict|reassign|comment|query|hold"
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
    query) cmd_query "$@" ;;
    hold) cmd_hold "$@" ;;
    approval) cmd_approval "$@" ;;
    *)
      exit_usage "未知子命令：$sub"
      ;;
  esac
}

main "$@"

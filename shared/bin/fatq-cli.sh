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
      --as|--json) shift 2 2>/dev/null || shift ;;  # 已由外層解析，略過
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

# do_transfer: 在拿到 flock 之後執行。
# args: task_file expected_from_dir to_dir action reason(optional, 可空字串)
do_transfer_locked() {
  local task_file="$1" expected_from="$2" to_dir="$3" action="$4" reason="${5:-}"

  # 重驗：檔案仍在預期目錄
  local actual_dir
  actual_dir="$(current_state_of "$task_file")"
  if [[ "$actual_dir" != "$expected_from" ]]; then
    TRANSFER_RESULT="conflict"
    TRANSFER_MSG="任務已不在 ${expected_from}/（現於 ${actual_dir}/），可能已被其他進程動走"
    return 6
  fi

  local history_entry
  history_entry=$(build_history_entry "$action" "${expected_from}/" "${to_dir}/" "$reason")

  local dest_dir dest_file dir tmp
  dest_dir="${FATQ_ROOT}/${to_dir}"
  dest_file="${dest_dir}/$(basename "$task_file")"
  dir=$(dirname "$task_file")
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

  local jq_extra_status=""
  case "$to_dir" in
    in_progress) jq_extra_status="in_progress" ;;
    review) jq_extra_status="review" ;;
    done) jq_extra_status="done" ;;
    rejected) jq_extra_status="rejected" ;;
    pending) jq_extra_status="pending" ;;
  esac

  if ! jq --argjson entry "$history_entry" --arg status "$jq_extra_status" \
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

# ── claim：pending|rejected → in_progress（§1.2 claim） ─────────────────
cmd_claim() {
  local task_id=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as|--json) shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "claim: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "claim: 找不到任務 $task_id"

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  # 先權限後狀態（mac-bridge 20260707-120500 裁決③c：未授權者不應探知任務狀態）
  if ! is_builder_pool "$IDENTITY"; then
    exit_perm "claim: identity $IDENTITY 不得執行 claim（規則：builder 類轉移僅限 builder pool ∪ {mac-agent}）"
  fi
  local assigned
  assigned="$(jq -r '.assigned // ""' "$task_file")"
  if [[ "$(lc "$assigned")" != "$IDENTITY" ]]; then
    exit_perm "claim: identity $IDENTITY 不得執行 claim（規則：僅 task assigned 本人可 claim，此任務 assigned=${assigned:-<empty>}）"
  fi

  if [[ "$from_dir" != "pending" && "$from_dir" != "rejected" ]]; then
    exit_state "claim: 任務目前在 ${from_dir}/，claim 只允許 pending→in_progress 或 rejected→in_progress"
  fi

  local rc
  with_task_lock "$task_file" do_transfer_locked "$from_dir" "in_progress" "claim" ""
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "claim: 任務檔在取鎖前已消失（已被移走）"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "claim: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "claim: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "in_progress/" true
  else
    echo "$LOG_PREFIX claim OK: $task_id ${from_dir}/ -> in_progress/"
  fi
  exit 0
}

# ── submit：in_progress → review，內建 verify gate（§1.2 submit） ───────
cmd_submit() {
  local task_id=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as|--json) shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "submit: 需要 task_id"

  resolve_identity

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "submit: 找不到任務 $task_id"

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  # 先權限後狀態（mac-bridge 20260707-120500 裁決③c）
  if ! is_builder_pool "$IDENTITY"; then
    exit_perm "submit: identity $IDENTITY 不得執行 submit（規則：builder 類轉移僅限 builder pool ∪ {mac-agent}）"
  fi
  local assigned
  assigned="$(jq -r '.assigned // ""' "$task_file")"
  if [[ "$(lc "$assigned")" != "$IDENTITY" ]]; then
    exit_perm "submit: identity $IDENTITY 不得執行 submit（規則：僅 task assigned 本人可 submit，此任務 assigned=${assigned:-<empty>}）"
  fi

  if [[ "$from_dir" != "in_progress" ]]; then
    exit_state "submit: 任務目前在 ${from_dir}/，submit 只允許 in_progress→review"
  fi

  # verify gate：exit 非 0 一律不放行（E6）
  local verify_out verify_rc
  verify_out="$("$FATQ_VERIFY_SH" "$task_file" 2>&1)"
  verify_rc=$?
  if [[ $verify_rc -ne 0 ]]; then
    err "submit: verify gate 未過（fatq-verify.sh exit $verify_rc）"
    echo "$verify_out" >&2
    if [[ $JSON_MODE -eq 1 ]]; then
      jq -n --arg code "E_VERIFY" --arg message "verify gate failed (exit $verify_rc)" --arg detail "$verify_out" \
        '{ok:false, code:$code, message:$message, detail:$detail}'
    fi
    exit 5
  fi

  local rc
  with_task_lock "$task_file" do_transfer_locked "in_progress" "review" "submit" ""
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "submit: 任務檔在取鎖前已消失（已被移走）"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "submit: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "submit: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "in_progress/" "review/" true
  else
    echo "$LOG_PREFIX submit OK: $task_id in_progress/ -> review/ (verify gate passed)"
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

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  local assigned reviewer
  assigned="$(jq -r '.assigned // ""' "$task_file")"
  reviewer="$(jq -r '.reviewer // ""' "$task_file")"

  # 先權限後狀態（mac-bridge 20260707-120500 裁決③c）
  # 禁自審：identity == assigned → exit 3 無例外（§1.2 verdict approve）
  if [[ "$(lc "$assigned")" == "$IDENTITY" ]]; then
    exit_perm "verdict $sub: 禁自審——identity $IDENTITY 同時是此任務 assigned，不得審自己的任務"
  fi

  # 允許身份 = task reviewer 欄位者 ∪ {bella, anya}（E4 reviewer-of-record 模型）
  local allowed=0
  if [[ "$(lc "$reviewer")" == "$IDENTITY" ]]; then
    allowed=1
  elif [[ "$IDENTITY" == "bella" || "$IDENTITY" == "anya" ]]; then
    allowed=1
  fi
  if [[ $allowed -eq 0 ]]; then
    exit_perm "verdict $sub: identity $IDENTITY 不得執行 verdict $sub（規則：僅 task reviewer 欄位者($reviewer) 或 bella/anya 可 verdict）"
  fi

  if [[ "$from_dir" != "review" ]]; then
    exit_state "verdict $sub: 任務目前在 ${from_dir}/，verdict 只允許 review→done/rejected"
  fi

  if [[ "$sub" == "approve" ]]; then
    # approve 時 CLI 自動再跑一次 fatq-verify.sh（reviewer SOP 第一步的機器保證）
    local verify_out verify_rc
    verify_out="$("$FATQ_VERIFY_SH" "$task_file" 2>&1)"
    verify_rc=$?
    if [[ $verify_rc -ne 0 ]]; then
      err "verdict approve: verify gate 未過（fatq-verify.sh exit $verify_rc），任一 fail 直接攔下不進 approve"
      echo "$verify_out" >&2
      if [[ $JSON_MODE -eq 1 ]]; then
        jq -n --arg code "E_VERIFY" --arg message "verify gate failed (exit $verify_rc)" --arg detail "$verify_out" \
          '{ok:false, code:$code, message:$message, detail:$detail}'
      fi
      exit 5
    fi
  fi

  local to_dir action
  if [[ "$sub" == "approve" ]]; then
    to_dir="done"; action="verdict_approve"
  else
    to_dir="rejected"; action="verdict_reject"
  fi

  local rc
  with_task_lock "$task_file" do_transfer_locked "review" "$to_dir" "$action" "$reason"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "verdict $sub: 任務檔在取鎖前已消失（已被移走）"
  elif [[ "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "verdict $sub: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "verdict $sub: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "review/" "${to_dir}/" true
  else
    echo "$LOG_PREFIX verdict $sub OK: $task_id review/ -> ${to_dir}/"
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
    approval)
      exit_usage "approval 子命令屬 Part 2（審批狀態機），本版 CLI（Part 1）不實作"
      ;;
    *)
      exit_usage "未知子命令：$sub"
      ;;
  esac
}

main "$@"

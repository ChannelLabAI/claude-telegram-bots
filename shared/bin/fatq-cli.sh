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
#              reassign, archive, comment, query, hold, update-field,
#              closeout,
#              approval request, approval approve, approval reject, approval expire,
#              force-mv, validate
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
FATQ_OVERRIDE_AUDIT="${FATQ_OVERRIDE_AUDIT:-${FATQ_ROOT}/override-audit.jsonl}"
FATQ_TRUST_LEDGER_AUDIT="${FATQ_TRUST_LEDGER_AUDIT:-/home/oldrabbit/.claude-bots/shared/loops/trust-ledger/trust-ledger.audit.jsonl}"
FATQ_ENFORCEMENT_KILL_SWITCH="${FATQ_ENFORCEMENT_KILL_SWITCH:-${FATQ_ROOT}/.fatq-enforcement-off}"
FATQ_TRANSITION_TOKEN_SECRET="${FATQ_TRANSITION_TOKEN_SECRET:-fatq-local-transition-token-v1}"
FATQ_BLOCKING_LIB="${FATQ_BLOCKING_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fatq-blocking.sh}"

# shellcheck source=../lib/fatq-blocking.sh
source "$FATQ_BLOCKING_LIB" || {
  echo "[fatq-cli] ERROR: 無法載入 FATQ 阻斷判斷：$FATQ_BLOCKING_LIB" >&2
  exit 4
}
FATQ_HISTORY_TS_MAX_SKEW_SECS="${FATQ_HISTORY_TS_MAX_SKEW_SECS:-60}"

# §1.2 核心狀態目錄（CLI 狀態機只認這些 + approval_pending，E1）
CORE_STATE_DIRS=(pending in_progress review done rejected cancelled wont_do approval_pending)
ARCHIVE_STATE_DIR="archived"

# 附加身份名單（Q5 裁決落地，2026-07-07）：不再寫死在腳本，改讀
# team-config.json 的 external_identities 段——單一權威源，mac-agent 的
# users.db 身份映射與本 CLI 共用同一份名單，不會漂移。

LOG_PREFIX="[fatq-cli]"

# ── 小工具 ──────────────────────────────────────────────────────────────
lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

# verify_commands run in the builder's current checkout.  These checks are
# deliberately lexical: create-time validation must never execute a verifier,
# but it can reject targets that necessarily escape to production.
verify_command_production_target_violation() {
  local commands_json="$1"
  jq -r '
    to_entries[]
    | .key as $idx
    | .value.cmd as $cmd
    | ($cmd | join(" ")) as $text
    | ([ $cmd[]
        | select(test("^/home/oldrabbit/\\.claude-bots(?:/|$)|^/etc(?:/|$)|^/opt(?:/|$)|(?:^|/)site-packages(?:/|$)"))
      ][0] // "") as $absolute
    | if $absolute != "" then
        "verify_commands[\($idx)] targets production path \($absolute): \($text)"
      elif ($text | test("(^|[[:space:];&|])cd[[:space:]]+[\\\"\u0027]?(/home/oldrabbit/\\.claude-bots|/etc|/opt|[^[:space:]\\\"\u0027]*/site-packages)(/|[\\\"\u0027[:space:];&|]|$)")) then
        "verify_commands[\($idx)] changes directory to a production path: \($text)"
      elif ($text | test("(https?://)?(127\\.0\\.0\\.1|localhost|0\\.0\\.0\\.0):8090(?:/|[[:space:]]|$)|MVP_PORT=8090|--port[=[:space:]]+8090"; "i")) then
        "verify_commands[\($idx)] targets production port 8090: \($text)"
      else empty end
  ' <<< "$commands_json"
}

# A live probe is evidence, not a deployment hook.  Reject shell constructs
# outside the small syntax Gate D models before checking known mutations.  This
# guard covers accidental misfills: leading whitespace, VAR=/sudo/env prefixes,
# nested shell -c, substitutions, newlines/continuations, and common wrappers.
# Deliberate bypasses (for example stdbuf, setsid, chrt, or another unlisted
# wrapper) are out of scope: a denylist cannot be exhaustive, and the threat
# model is accidental misuse rather than hostile input.  If hostile-input
# protection is needed, sandbox Gate C instead of extending this wrapper list.
live_probe_unmodeled_violation() {
  local commands_json="$1"
  jq -r '
    def base: split("/")[-1] | ascii_downcase;
    def command_start:
      "(^[[:space:]]*|[;&|][[:space:]]*)"
      + "([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*"
      + "(sudo[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*)?"
      + "(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*)?";
    to_entries[]
    | .key as $idx
    | .value.cmd as $cmd
    | (($cmd[0] // "") | base) as $program
    | ($cmd[2] // "") as $script
    | if (($program == "bash" or $program == "sh") and (($cmd[1] // "") == "-c")) then
        if ($script | test("\\\\\\r?\\n")) then "backslash line continuation"
        elif ($script | test("[\\r\\n]")) then "embedded newline"
        elif (($script | contains("$(")) or ($script | contains("`"))) then "command substitution"
        elif ($script | test("(^|[;&|[:space:]])(bash|sh)[[:space:]]+-c([[:space:]]|$)"; "i")) then "nested shell -c"
        elif ($script | test(command_start + "(nohup|timeout|nice|xargs|command|eval)([[:space:];&|]|$)"; "i")) then "unsupported command wrapper"
        else empty end
      else empty end
    | "live_verify_commands[\($idx)] uses unmodeled shell syntax (\(.))"
  ' <<< "$commands_json"
}

# Keep the mutation denylist focused on command positions so documentation or
# grep literals such as "deploy.sh" do not get mistaken for execution.
live_probe_mutation_violation() {
  local commands_json="$1"
  jq -r '
    def base: split("/")[-1] | ascii_downcase;
    def has_token($cmd; $pattern):
      any($cmd[]; (ascii_downcase | test($pattern)));
    def readonly_service_probe($program; $cmd):
      if $program == "systemctl" then
        has_token($cmd[1:]; "^(is-active|is-enabled|status|show|list-units)$")
        and (has_token($cmd[1:]; "^(start|stop|restart|reload|enable|disable|mask|unmask|isolate|daemon-reload|edit|set-default|link|preset|revert|kill|cancel|import-environment|set-environment|unset-environment)$") | not)
      elif $program == "service" then
        has_token($cmd[1:]; "^status$")
        and (has_token($cmd[1:]; "^(start|stop|restart|reload|force-reload)$") | not)
      else false end;
    # Accept ordinary shell formatting before a command: leading whitespace,
    # repeated VAR=value assignments, sudo with optional assignments after it,
    # and env with optional assignments.  Gate D runs before Gate C, so missing
    # these prefixes would let the verifier execute an obvious mutator.
    def command_start:
      "(^[[:space:]]*|[;&|][[:space:]]*)"
      + "([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*"
      + "(sudo[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*)?"
      + "(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+)*)?";
    to_entries[]
    | .key as $idx
    | .value.cmd as $cmd
    | (($cmd[0] // "") | base) as $program
    | ($cmd | join(" ")) as $text
    | ($text | ascii_downcase) as $lower
    | ((($program == "systemctl" or $program == "service")
        and (readonly_service_probe($program; $cmd) | not))
       or $program == "host-apply" or $program == "host-apply.sh"
       or ($program | test("deploy\\.sh$"))
       or (($program | test("^(pip|pip3)$")) and (($cmd[1] // "") | ascii_downcase) == "install")
       or (($program | test("^python[0-9.]*$")) and ($lower | test("(^|[[:space:]])-m[[:space:]]+pip[[:space:]]+install([[:space:]]|$)")))
       or ($program == "git" and (($cmd[1] // "") | ascii_downcase) == "push")
       or (($program == "bash" or $program == "sh") and (($cmd[1] // "") != "-c")
           and ((($cmd[1] // "") | ascii_downcase) | test("(^|/)(deploy|host-apply)(\\.sh)?$")))
       or (($program == "bash" or $program == "sh") and (($cmd[1] // "") == "-c")
           and (($cmd[2] // "") | ascii_downcase
             | test(command_start + "((bash|sh)[[:space:]]+)?[^[:space:];&|]*(deploy\\.sh|host-apply(\\.sh)?)([[:space:];&|]|$)"
                    + "|" + command_start + "(systemctl|service)[^;&|]*[[:space:]]+(start|stop|restart|reload|force-reload|enable|disable|mask|unmask|isolate|daemon-reload|edit|set-default|link|preset|revert|kill|cancel|import-environment|set-environment|unset-environment)([[:space:];&|]|$)"
                    + "|" + command_start + "((pip|pip3)[[:space:]]+install|python[0-9.]*[[:space:]]+-m[[:space:]]+pip[[:space:]]+install|git[[:space:]]+push)([[:space:];&|]|$)"))))
    | select(.)
    | "live_verify_commands[\($idx)] contains a production mutation: \($text)"
  ' <<< "$commands_json"
}

reject_mutating_live_probes() {
  local context="$1" commands_json="$2" violation
  if ! violation="$(live_probe_unmodeled_violation "$commands_json")"; then
    exit_state "$context: Gate D fail-closed 靜態檢查器執行失敗；拒絕寫入"
  fi
  if [[ -n "$violation" ]]; then
    exit_usage "$context: Gate D rejected $violation. Gate C 不會執行無法可靠解析的 shell；請改寫成單層、無命令替換的直接 argv。可直接改成：--live_verify_commands '[{\"cmd\":[\"curl\",\"-fsS\",\"http://127.0.0.1:8090/health\"],\"expect_exit\":0}]'"
  fi
  if ! violation="$(live_probe_mutation_violation "$commands_json")"; then
    exit_state "$context: Gate D 靜態檢查器執行失敗；拒絕寫入"
  fi
  [[ -z "$violation" ]] && return 0
  exit_usage "$context: Gate D rejected $violation. live probe 只能觀測、不能 deploy/host-apply/systemctl/pip install/git push。可直接改成：--live_verify_commands '[{\"cmd\":[\"curl\",\"-fsS\",\"http://127.0.0.1:8090/health\"],\"expect_exit\":0}]'"
}

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

SPEC_HASH_FIELDS=(goal context acceptance_criteria deliverables out_of_scope)

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

build_spec_hash_patch() {
  local task_file="$1" hash field_hashes
  hash="$(spec_payload_hash "$task_file")"
  field_hashes="$(spec_field_hashes_json "$task_file")"
  jq -n --arg hash "$hash" \
    --argjson fields "$(printf '%s\n' "${SPEC_HASH_FIELDS[@]}" | jq -R . | jq -s .)" \
    --argjson field_hashes "$field_hashes" \
    '{spec_hash_algorithm:"sha256", spec_fields:$fields, spec_hash:$hash, field_hashes:$field_hashes}'
}

# 時戳防呆（f7d9 + 35e2）：對已組好、尚未寫入磁碟的 tmp 檔內容操作——若最新一筆
# history 的 ts 早於前一筆，或超前 now+skew，改用系統時鐘覆寫該筆 ts，並插入
# 一筆 clock_warn 記錄異常（attempted_ts＝原本要寫入但被拒的值）。
# 統一在每個 mv -f 前呼叫。
# 只比較「新寫入的這一筆」跟「它前面那一筆」——兩者都已在同一支 tmp 檔內，
# 不需要額外重讀任務檔，天然跟 flock 持鎖區段一致，不引入新的併發窗口。
enforce_history_monotonic() {
  local tmp_file="$1"
  local n
  n=$(jq '.history | length' "$tmp_file" 2>/dev/null)
  [[ -z "$n" || "$n" -lt 2 ]] && return 0

  local last_ts prev_ts last_epoch prev_epoch now_ep
  last_ts=$(jq -r '.history[-1].ts' "$tmp_file")
  prev_ts=$(jq -r '.history[-2].ts' "$tmp_file")
  last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
  prev_epoch=$(date -d "$prev_ts" +%s 2>/dev/null)
  now_ep="$(now_epoch)"
  [[ -z "$last_epoch" || -z "$prev_epoch" || -z "$now_ep" ]] && return 0

  local warn_note=""
  if [[ "$last_epoch" -lt "$prev_epoch" ]]; then
    warn_note="history append 單調性防呆：偵測到新條目 ts 早於前一筆，已改用系統時鐘"
  elif [[ "$last_epoch" -gt $((now_ep + FATQ_HISTORY_TS_MAX_SKEW_SECS)) ]]; then
    warn_note="history append 未來時戳防呆：偵測到新條目 ts 超前系統時間超過 ${FATQ_HISTORY_TS_MAX_SKEW_SECS}s，已改用系統時鐘"
  fi

  if [[ -n "$warn_note" ]]; then
    local corrected_ts warn_entry fixed
    corrected_ts="$(TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00")"
    warn_entry=$(jq -n --arg ts "$corrected_ts" --arg attempted "$last_ts" --arg note "$warn_note" \
      '{ts:$ts, by:"fatq-cli", via:"fatq-cli", action:"clock_warn",
        attempted_ts:$attempted,
        note:$note}')
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

# Canonical delivery targets are bot state_dir values only. Human/external
# identities are intentionally excluded because v1 delivery is bot-mediated.
# Print the canonical configured spelling only when exactly one entry matches.
canonical_delivery_identity() {
  local ident_lc
  ident_lc="$(lc "$1")"
  jq -r --arg ident "$ident_lc" '
    [ (.assistants // [])[]?.state_dir,
      (.shared_pools // {} | to_entries[] | .value[]?.state_dir) ]
    | map(select(type == "string" and (ascii_downcase == $ident)))
    | if length == 1 then .[0] else empty end
  ' "$FATQ_TEAM_CONFIG" 2>/dev/null
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

# 工作池身份清單（builder ∪ designer 的 state_dir）＋附加 mac-agent（③a 裁決：fail-closed）
# 用於權限矩陣判斷「合法工作池」轉移（claim/submit）——這一層只驗身份池資格；
# task assigned 本人的檢查仍由 claim_locked/submit_locked 獨立把關，不得弱化。
builder_pool_identities() {
  jq -r '[(.shared_pools.builder // [])[], (.shared_pools.designer // [])[]] | .[].state_dir' "$FATQ_TEAM_CONFIG" 2>/dev/null
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

is_balanced_infra_reviewer() {
  local reviewer
  reviewer="$(lc "$1")"
  [[ "$reviewer" == "bella" || "$reviewer" == "yitang" ]]
}

# daemon / security / deployment gates remain Bella-only. This runs only after
# is_infra_change() succeeds, so descriptive mentions in docs do not become a
# gate by themselves.
is_bella_priority_infra() {
  local text text_lc
  text="$1"
  text_lc="$(lc "$text")"
  [[ "$text_lc" == *"daemon"* || "$text_lc" == *"systemd"* \
    || "$text_lc" == *"security"* || "$text_lc" == *"oauth"* \
    || "$text_lc" == *"credential"* || "$text_lc" == *"secret"* \
    || "$text_lc" == *"permission"* || "$text_lc" == *"authz"* \
    || "$text_lc" == *"deploy"* || "$text_lc" == *"deployment"* \
    || "$text_lc" == *"rollout"* || "$text_lc" == *"release"* \
    || "$text_lc" == *"production"* || "$text" == *"資安"* \
    || "$text" == *"憑證"* || "$text" == *"權限"* \
    || "$text" == *"部署"* || "$text" == *"上線"* || "$text" == *"生產"* ]]
}

reviewer_task_count() {
  local reviewer="$1" scope="$2" state f count=0
  local states=(review)
  [[ "$scope" == "active" ]] && states=(pending in_progress review)
  for state in "${states[@]}"; do
    for f in "$FATQ_ROOT/$state/"*.json; do
      [[ -f "$f" ]] || continue
      if [[ "$(lc "$(jq -r '.reviewer // ""' "$f" 2>/dev/null)")" == "$reviewer" ]]; then
        count=$((count + 1))
      fi
    done
  done
  echo "$count"
}

# Primary signal is review/ work in flight. Active work is only the tie-breaker
# so a burst of creates does not all pick the same reviewer before any task
# reaches review/. The caller holds FATQ_ROOT/.locks/reviewer-pool.lock.
select_balanced_infra_reviewer() {
  local preferred="${1:-bella}"
  local bella_review yitang_review bella_active yitang_active
  bella_review="$(reviewer_task_count bella review)"
  yitang_review="$(reviewer_task_count yitang review)"
  if (( bella_review < yitang_review )); then echo bella; return; fi
  if (( yitang_review < bella_review )); then echo yitang; return; fi

  bella_active="$(reviewer_task_count bella active)"
  yitang_active="$(reviewer_task_count yitang active)"
  if (( bella_active < yitang_active )); then echo bella; return; fi
  if (( yitang_active < bella_active )); then echo yitang; return; fi

  if is_balanced_infra_reviewer "$preferred"; then
    lc "$preferred"
  else
    echo bella
  fi
}

build_yitang_infra_probation_entry() {
  local task_id="$1" sequence sample=false
  local existing=0
  if [[ -f "$FATQ_TRUST_LEDGER_AUDIT" ]]; then
    existing="$(jq -s '
      [.[] | select(.event == "infra_reviewer_probation_assignment"
        and .subject_id == "yitang") | .task_id] | unique | length
    ' "$FATQ_TRUST_LEDGER_AUDIT" 2>/dev/null || echo 0)"
  fi
  sequence=$((existing + 1))
  (( sequence <= 10 )) || return 0
  [[ "$sequence" == "1" || "$sequence" == "4" || "$sequence" == "7" ]] && sample=true
  jq -cn --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg task_id "$task_id" \
    --argjson sequence "$sequence" --argjson sample "$sample" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:"infra_reviewer_probation",
      reviewer:"yitang", probation_sequence:$sequence,
      bella_recheck_sample:$sample, advisory_only:true, task_id:$task_id}'
}

write_infra_gate_rewrite_relay() {
  local task_id="$1" task_file="$2" creator="$3" original_reviewer="$4" pattern="$5" forced_reviewer="${6:-bella}"
  [[ "${FATQ_MATTERMOST_DISABLE:-0}" == "1" ]] && return 0

  local recipient="" handle="" mapped relay_text relay_content relay_file
  if [[ -n "$creator" ]] && mapped=$(lookup_bot_for_relay "$creator"); then
    recipient="${mapped%%|*}"
    handle="${mapped##*|}"
  else
    handle="@Anyachl_bot"
  fi

  relay_text="[FATQ infra-gate] 任務 ${task_id} 命中公共財守門，reviewer 已由 '${original_reviewer:-<空>}' 強制改為 '${forced_reviewer}'。\npattern：${pattern:-<unknown>}\n任務檔：${task_file}\n${handle}"
  relay_content=$(jq -n --arg from "fatq-cli" --arg recipient "$recipient" --arg text "$relay_text" \
    --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}')
  relay_file="fatq-infra-gate-rewrite-$(date +%s%N 2>/dev/null || echo $$).json"
  mkdir -p "$FATQ_RELAY_DIR" 2>/dev/null || true
  printf '%s' "$relay_content" > "${FATQ_RELAY_DIR}/${relay_file}" 2>/dev/null || true
}

record_yitang_probation_verdict() {
  local task_file="$1" verdict="$2" marker task_id sequence sample audit_entry
  marker="$(jq -c '
    [.history[]? | select(.action == "infra_reviewer_probation"
      and .reviewer == "yitang")] | last // empty
  ' "$task_file" 2>/dev/null)"
  [[ -n "$marker" ]] || return 0

  task_id="$(jq -r '.task_id' "$task_file")"
  sequence="$(jq -r '.probation_sequence' <<<"$marker")"
  sample="$(jq -r '.bella_recheck_sample' <<<"$marker")"
  audit_entry="$(jq -cn --arg ts "$(now_iso)" --arg task_id "$task_id" \
    --arg verdict "$verdict" --argjson sequence "$sequence" --argjson sample "$sample" \
    '{ts:$ts, event:"infra_reviewer_probation_verdict", subject_id:"yitang",
      category:"infra", task_id:$task_id, verdict:$verdict,
      probation_sequence:$sequence, bella_recheck_sample:$sample,
      advisory_only:true}')"

  mkdir -p "$(dirname "$FATQ_TRUST_LEDGER_AUDIT")" 2>/dev/null || true
  local audit_fd
  exec {audit_fd}> "${FATQ_TRUST_LEDGER_AUDIT}.lock" || return 0
  flock -x "$audit_fd" || { exec {audit_fd}>&-; return 0; }
  printf '%s\n' "$audit_entry" >> "$FATQ_TRUST_LEDGER_AUDIT" 2>/dev/null || true
  flock -u "$audit_fd"
  exec {audit_fd}>&-

  [[ "$sample" == "true" ]] || return 0
  [[ "${FATQ_MATTERMOST_DISABLE:-0}" == "1" ]] && return 0
  local relay_file relay_tmp relay_text
  relay_file="fatq-yitang-infra-recheck-${task_id}.json"
  relay_text="[FATQ advisory recheck] Yitang 已對 infra probation #${sequence} 任務 ${task_id} 作出 ${verdict} verdict；此單命中前 10 抽 3，請 Bella 覆核。覆核為 advisory-only，不回滾、不阻塞既有 verdict。"
  mkdir -p "$FATQ_RELAY_DIR/.tmp" 2>/dev/null || return 0
  relay_tmp="$(mktemp "$FATQ_RELAY_DIR/.tmp/yitang-recheck.XXXXXX")" || return 0
  jq -n --arg from "fatq-cli" --arg recipient "bella" --arg text "$relay_text" \
    --arg ts "$(now_iso)" --arg tid "$task_id" \
    '{from_bot:$from, recipient:$recipient, text:$text, ts:$ts, fatq_task_id:$tid}' > "$relay_tmp"
  mv -f "$relay_tmp" "$FATQ_RELAY_DIR/$relay_file"
}

# ── 業務線親和預填（org-design-lines-20260707 決議 #2，create 層合法實作，
# b3d7）：d5c3 揭示 cron 層親和違紅線（cron 不能寫欄位，relay 收件人 claim/
# verdict 時權限檢查讀的是真實欄位，永遠不符）；Anya 裁決換層——create 本身
# 就是任務檔的合法寫手，缺省欄位在建檔當下直接寫入業務線慣用值，天生沒有
# 「假裝欄位已寫」的問題。$1=builder|reviewer，查 IDENTITY（本次 create 呼叫
# 者＝task 的 created_by）對應線，查無 fallback lines.default。
get_create_affinity_default() {
  local field="$1" preferred
  preferred="$(get_affinity_default_for_creator "$IDENTITY" "$field")"
  if [[ "$field" == "reviewer" ]] && is_balanced_infra_reviewer "$preferred"; then
    select_balanced_infra_reviewer "$preferred"
  else
    echo "$preferred"
  fi
}

get_affinity_default_for_creator() {
  local creator="$1" field="$2"
  [[ -f "$FATQ_DISPATCH_AFFINITY" ]] || return 1
  jq -r --arg cb "$creator" --arg field "$field" \
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
  local task_id="$1" d f first_match="" match_count=0
  for d in "${CORE_STATE_DIRS[@]}"; do
    f="${FATQ_ROOT}/${d}/${task_id}.json"
    if [[ -f "$f" ]]; then
      [[ -n "$first_match" ]] || first_match="$f"
      match_count=$((match_count + 1))
    fi
  done
  if [[ "$match_count" -gt 1 ]]; then
    echo "$LOG_PREFIX WARNING: task $task_id exists in $match_count state directories; using $first_match by CORE_STATE_DIRS priority" >&2
  fi
  if [[ -n "$first_match" ]]; then
    echo "$first_match"
    return 0
  fi
  echo ""
  return 1
}

advisor_checkpoint_missing() {
  local task_file="$1"
  jq -e '
    (.advisor_required == true)
    and (
      [(.history // [])[]
       | select((.action // "") == "comment")
       | select((.text // "") | startswith("[advisor]"))]
      | length == 0
    )
  ' "$task_file" >/dev/null 2>&1
}

find_archived_task_file() {
  local task_id="$1" f
  f="${FATQ_ROOT}/${ARCHIVE_STATE_DIR}/${task_id}.json"
  if [[ -f "$f" ]]; then
    echo "$f"
    return 0
  fi
  echo ""
  return 1
}

current_state_of() {
  # 從路徑推導目錄名（狀態名）
  basename "$(dirname "$1")"
}

# ── stable task lock 包住 read-modify-rename（§1.4.2 / §1.5） ────────────
# 不鎖 task inode 本身：每次 atomic rename 都會換 inode，dispatch 與 claim
# 可能各自鎖到不同 inode。鎖檔以 task basename 為 key，跨 state 目錄不變。
task_lock_file_for() {
  local task_file="$1" lock_dir task_name
  lock_dir="${FATQ_ROOT}/.locks"
  task_name="$(basename "$task_file" .json)"
  mkdir -p "$lock_dir" 2>/dev/null || return 1
  printf '%s/%s.lock\n' "$lock_dir" "$task_name"
}

# 用法：with_task_lock <task_file> <callback_fn> [extra args passed to callback]
# callback 收到 lock 後的路徑，並需自行重驗＋處理 mv。
with_task_lock() {
  local task_file="$1"; shift
  local callback="$1"; shift
  local lock_fd lock_file

  lock_file="$(task_lock_file_for "$task_file")" || return 9
  exec {lock_fd}>"$lock_file" || return 9
  flock -x "$lock_fd" || {
    exec {lock_fd}>&- || true
    return 9
  }

  if [[ ! -e "$task_file" ]]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&- || true
    return 9
  fi

  "$callback" "$task_file" "$@"
  local rc=$?

  flock -u "$lock_fd"
  exec {lock_fd}>&- || true
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

# Caller provenance is best-effort forensic context, not authentication.  The
# declarative --as value remains authoritative for the existing permission
# model and a missing/mismatched signal must never block an operation or alter
# its exit status.  Walk the real parent chain instead of trusting this
# process's TELEGRAM_STATE_DIR or cwd, both of which a child can trivially
# replace.  Residual boundary: the same uid can edit tasks/ directly and bypass
# this CLI, ptrace_scope=0 permits same-uid process tampering, a same-uid process
# can spoof comm="claude" (for example with prctl(PR_SET_NAME)), and setsid can
# detach a caller from the useful ancestry altogether.  A hostile-input model
# therefore needs an OS trust boundary; these fields only improve post-incident
# attribution for accidental misuse.
caller_provenance_json() {
  local pid="${PPID:-}" comm parent pid_sid start_sid env_file cwd_link env_text="" workspace="" cwd_path="" cwd_bot="" session_id=""
  local found=0 chain_ok=0 hops=0

  # Do not cross a session boundary while walking ancestors.  In particular,
  # `setsid -f -w` leaves a waiting parent in the old session; without this
  # check the walk can pass through it and falsely attribute an unrelated
  # claude process above the boundary.  Use ps instead of parsing /proc/PID/stat
  # because a comm value may itself contain spaces or parentheses.
  start_sid="$(ps -o sid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
  [[ "$start_sid" =~ ^[0-9]+$ ]] || start_sid=""

  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$hops" -lt 128 ]]; do
    [[ -n "$start_sid" ]] || break
    pid_sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ "$pid_sid" =~ ^[0-9]+$ && "$pid_sid" == "$start_sid" ]] || break
    comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "claude" ]]; then
      found=1
      env_file="/proc/${pid}/environ"
      cwd_link="/proc/${pid}/cwd"
      if [[ -r "$env_file" ]] \
          && cwd_path="$(readlink "$cwd_link" 2>/dev/null)" \
          && env_text="$(tr '\0' '\n' < "$env_file" 2>/dev/null)"; then
        workspace="$(awk -F= '$1 == "TELEGRAM_STATE_DIR" {sub(/^[^=]*=/, ""); print; exit}' <<< "$env_text")"
        session_id="$(awk -F= '$1 == "CLAUDE_CODE_SESSION_ID" {sub(/^[^=]*=/, ""); print; exit}' <<< "$env_text")"
        [[ -n "$workspace" ]] && workspace="$(basename -- "${workspace%/}")"
        [[ -n "$cwd_path" ]] && cwd_bot="$(basename -- "${cwd_path%/}")"
        chain_ok=1
      fi
      break
    fi
    parent="$(awk '/^PPid:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
    [[ "$parent" =~ ^[0-9]+$ && "$parent" != "$pid" ]] || break
    pid="$parent"
    hops=$((hops + 1))
  done

  if [[ "$found" -eq 1 && "$chain_ok" -eq 1 ]]; then
    jq -cn --arg workspace "$workspace" --arg cwd_bot "$cwd_bot" --arg session_id "$session_id" \
      '{workspace:(if $workspace == "" then null else $workspace end),
        cwd_bot:(if $cwd_bot == "" then null else $cwd_bot end),
        session_id:(if $session_id == "" then null else $session_id end),
        pid_chain_ok:true}' 2>/dev/null \
      || printf '%s\n' '{"workspace":null,"cwd_bot":null,"session_id":null,"pid_chain_ok":false}'
  else
    printf '%s\n' '{"workspace":null,"cwd_bot":null,"session_id":null,"pid_chain_ok":false}'
  fi
}

history_entry_with_caller() {
  local entry="$1" declared_identity="$2" caller
  caller="$(caller_provenance_json 2>/dev/null)" \
    || caller='{"workspace":null,"cwd_bot":null,"session_id":null,"pid_chain_ok":false}'
  jq -cn --argjson entry "$entry" --argjson caller "$caller" --arg declared "$(lc "$declared_identity")" '
    $entry + {caller:$caller}
    + (if (($caller.workspace // "") | length) > 0
          and (($caller.workspace | ascii_downcase) != $declared)
       then {identity_mismatch:true}
       else {}
       end)' 2>/dev/null || printf '%s\n' "$entry"
}

is_admin_identity() {
  local ident
  ident="$(lc "$1")"
  [[ "$ident" == "anya" || "$ident" == "bella" ]]
}

is_archive_admin_identity() {
  local ident
  ident="$(lc "$1")"
  [[ "$ident" == "anya" || "$ident" == "laotu" ]]
}

is_review_assigned_exception() {
  local task_file="$1" identity="$2"
  local assigned
  assigned="$(jq -r '.assigned // ""' "$task_file" 2>/dev/null)"
  [[ "$(lc "$assigned")" == "$(lc "$identity")" ]] || return 1

  jq -e '
    [(.skills // [])[] | ascii_downcase]
    | any(. == "review" or . == "spec-review" or . == "fatq-ops")
  ' "$task_file" >/dev/null 2>&1
}

can_builder_transition() {
  local task_file="$1" identity="$2"
  is_builder_pool "$identity" && return 0
  is_review_assigned_exception "$task_file" "$identity" && return 0
  return 1
}

transition_token_for_file() {
  local task_file="$1"
  jq -rc --arg secret "$FATQ_TRANSITION_TOKEN_SECRET" '
    {
      secret: $secret,
      task_id: (.task_id // ""),
      status: (.status // ""),
      last_history: ((.history // [])[-1] // {})
    }
  ' "$task_file" 2>/dev/null | sha256sum | awk '{print $1}'
}

stamp_transition_token() {
  local tmp_file="$1" token fixed
  token="$(transition_token_for_file "$tmp_file")" || return 0
  fixed=$(jq --arg token "$token" '.transition_token = $token' "$tmp_file") \
    && printf '%s' "$fixed" > "$tmp_file"
}

append_override_audit() {
  local actor="$1" rule="$2" task_id="$3" from_state="$4" to_state="$5" reason="$6"
  local audit_dir entry
  audit_dir="$(dirname "$FATQ_OVERRIDE_AUDIT")"
  mkdir -p "$audit_dir" 2>/dev/null || true
  entry=$(jq -cn --arg ts "$(now_iso)" --arg actor "$actor" --arg rule "$rule" \
    --arg task_id "$task_id" --arg reason "$reason" --arg from "$from_state" --arg to "$to_state" \
    '{ts:$ts, actor:$actor, overridden_rule:$rule, task_id:$task_id,
      reason:$reason, from_state:$from, to_state:$to}')
  printf '%s\n' "$entry" >> "$FATQ_OVERRIDE_AUDIT"
}

is_core_state() {
  local state="$1" d
  for d in "${CORE_STATE_DIRS[@]}"; do
    [[ "$d" == "$state" ]] && return 0
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════
# 子命令實作
# ═══════════════════════════════════════════════════════════════════════

# ── create：pending 建檔（§1.2 create） ─────────────────────────────────
cmd_create() {
  resolve_identity  # 任何已知 identity 可 create

  local title="" goal="" background="" context="" deliverables="" acceptance_criteria="" out_of_scope="" review_focus=""
  local assigned="" reviewer="" priority="P2" fast_track="false" verify_commands="[]" live_verify_commands="[]"
  local no_live_verify_reason="" no_live_verify_explicit=0
  local reviewer_explicit=0
  local skills="[]" graduated_invariant="[]"
  local slug="" project_id="" deliver_to="$IDENTITY"

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
      --reviewer) reviewer="$2"; reviewer_explicit=1; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --fast_track) fast_track="$2"; shift 2 ;;
      --verify_commands) verify_commands="$2"; shift 2 ;;  # JSON array string
      --live_verify_commands) live_verify_commands="$2"; shift 2 ;;  # JSON array string；僅建單入口可定義
      --no-live-verify) no_live_verify_reason="$2"; no_live_verify_explicit=1; shift 2 ;;  # 明確承諾本單不產生部署 commit；理由會永久留痕
      --skills) skills="$2"; shift 2 ;;  # JSON array string
      --graduated_invariant) graduated_invariant="$2"; shift 2 ;;  # JSON array string
      --slug) slug="$2"; shift 2 ;;
      --project_id) project_id="$2"; shift 2 ;;  # b8f4：可選，task 屬於哪個專案（Bella 紅線②：CLI 當下寫入，非 web 事後改）
      --deliver_to) deliver_to="$2"; shift 2 ;;
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

  deliver_to="$(canonical_delivery_identity "$deliver_to")"
  [[ -n "$deliver_to" ]] \
    || exit_usage "create: deliver_to 必須是 FATQ_TEAM_CONFIG 中唯一、非空的 bot state_dir"
  deliver_to="$(lc "$deliver_to")"

  # 驗證 array 欄位是合法 JSON array
  for fld_name in deliverables acceptance_criteria out_of_scope; do
    local val="${!fld_name}"
    if ! jq -e 'type=="array"' <<< "$val" >/dev/null 2>&1; then
      exit_usage "create: $fld_name 必須是合法 JSON array"
    fi
  done
  for fld_name in verify_commands live_verify_commands skills graduated_invariant; do
    local val="${!fld_name}"
    if ! jq -e 'type=="array"' <<< "$val" >/dev/null 2>&1; then
      exit_usage "create: $fld_name 必須是合法 JSON array"
    fi
  done
  local command_field command_value verify_error
  for command_field in verify_commands live_verify_commands; do
    command_value="${!command_field}"
    verify_error="$(
    jq -r '
      to_entries[]
      | if (.value | type) != "object" then
          "create: COMMAND_FIELD[\(.key)] must be object, got \(.value | type)"
        elif (.value.cmd | type) != "array" then
          "create: COMMAND_FIELD[\(.key)].cmd must be non-empty string array, got \(.value.cmd | type)"
        elif (.value.cmd | length) == 0 then
          "create: COMMAND_FIELD[\(.key)].cmd must be non-empty string array"
        elif ([.value.cmd[] | select((type) != "string")] | length) > 0 then
          "create: COMMAND_FIELD[\(.key)].cmd must be string array"
        elif ((.value | has("expect_exit")) and ((.value.expect_exit | type) != "number")) then
          "create: COMMAND_FIELD[\(.key)].expect_exit must be number, got \(.value.expect_exit | type)"
        else
          empty
        end
    ' <<< "$command_value" | sed "s/COMMAND_FIELD/$command_field/g" | head -n 1
    )"
    if [[ -n "$verify_error" ]]; then
      exit_usage "$verify_error"
    fi
  done

  local production_target_violation verify_canonical live_verify_canonical
  if ! production_target_violation="$(verify_command_production_target_violation "$verify_commands")"; then
    exit_state "create: Gate A 靜態檢查器執行失敗；拒絕建單"
  fi
  if [[ -n "$production_target_violation" ]]; then
    exit_usage "create: Gate A rejected $production_target_violation. 可直接改成 worktree 寫法：--verify_commands '[{\"cmd\":[\"bash\",\"-c\",\"cd \\\"\$(git rev-parse --show-toplevel)\\\" && bash shared/tests/fatq-cli-test.sh\"],\"expect_exit\":0}]'；若本來要驗 host-apply 後的生產狀態，請改放 --live_verify_commands。"
  fi

  verify_canonical="$(jq -S -c '.' <<< "$verify_commands")"
  live_verify_canonical="$(jq -S -c '.' <<< "$live_verify_commands")"
  if [[ "$(jq -r 'length' <<< "$verify_commands")" -gt 0 && "$verify_canonical" == "$live_verify_canonical" ]]; then
    exit_usage "create: Gate B rejected identical verify_commands and live_verify_commands. verify_commands 在 builder worktree 跑，live_verify_commands 在 host-apply 後驗 production，不能複製同一份。可直接改成：--verify_commands '[{\"cmd\":[\"bash\",\"-c\",\"cd \\\"\$(git rev-parse --show-toplevel)\\\" && bash shared/tests/fatq-cli-test.sh\"],\"expect_exit\":0}]' --live_verify_commands '[{\"cmd\":[\"curl\",\"-fsS\",\"http://127.0.0.1:8090/health\"],\"expect_exit\":0}]'"
  fi

  reject_mutating_live_probes "create" "$live_verify_commands"

  # 5b1a：每張新單在任何 lock、task file 或 project backlink 寫入前，必須
  # 二擇一：預先定義主機探針，或明確承諾本單不產生部署 commit 並留下理由。
  # opt-out 不是 closeout bypass；若日後真的產生 commit，仍須走專用的
  # set-live-verify 補填路徑，且 closed 前由 reviewer-live 覆署。
  local live_verify_count
  live_verify_count="$(jq -r 'length' <<< "$live_verify_commands")"
  if [[ "$no_live_verify_explicit" -eq 1 && ! "$no_live_verify_reason" =~ [^[:space:]] ]]; then
    exit_usage "create: --no-live-verify 理由 trim 後不可為空；請說明為何本單預期不產生部署 commit"
  fi
  if [[ "$live_verify_count" -gt 0 && "$no_live_verify_explicit" -eq 1 ]]; then
    exit_usage "create: --live_verify_commands 與 --no-live-verify 互斥；請只選一條路"
  fi
  if [[ "$live_verify_count" -eq 0 && "$no_live_verify_explicit" -eq 0 ]]; then
    exit_usage 'create: 必須二擇一：提供 --live_verify_commands '\''[{"cmd":["curl","-fsS","https://service/health"],"expect_exit":0}]'\''；或對預期不產生部署 commit 的研究/文件單提供 --no-live-verify "不部署的具體理由"'
  fi
  if [[ "$no_live_verify_explicit" -eq 1 ]]; then
    no_live_verify_reason="$(jq -rn --arg reason "$no_live_verify_reason" '$reason | gsub("^\\s+|\\s+$"; "")')"
  fi

  if [[ -z "$slug" ]]; then
    slug="task"
  fi
  # slug 消毒：僅留字母數字與連字號
  slug="$(echo "$slug" | tr -c '[:alnum:]-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"

  # Serialize reviewer selection through task creation. review/ load is the
  # primary selector; holding this lock until the new pending file exists makes
  # the active-work tie-breaker race-safe for concurrent creates.
  local reviewer_selection_fd
  mkdir -p "$FATQ_ROOT/.locks" || exit_state "create: 無法建立 reviewer pool lock 目錄"
  exec {reviewer_selection_fd}> "$FATQ_ROOT/.locks/reviewer-pool.lock" \
    || exit_state "create: 無法開啟 reviewer pool lock"
  flock -x "$reviewer_selection_fd" || exit_state "create: 無法取得 reviewer pool lock"

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
  local infra_rewrite_original_reviewer="" infra_rewrite_pattern="" is_infra=0
  local bella_priority_rewrite=0 self_review_by_gate=0
  if is_infra_change "$goal" "$infra_field_text"; then
    is_infra=1
    infra_rewrite_pattern="$INFRA_MATCH_PATTERN"
    # The critical gate outranks caller-controlled reviewer input: an explicit
    # --reviewer may choose within the normal infra pool, but cannot bypass the
    # Bella-only daemon/security/deployment subset.
    if is_bella_priority_infra "$goal $infra_field_text"; then
      bella_priority_rewrite=1
      infra_rewrite_original_reviewer="$reviewer"
      reviewer="bella"
      [[ "$reviewer_explicit" -eq 0 ]] && prefilled_reviewer="bella"
    elif [[ "$reviewer_explicit" -eq 0 ]]; then
      reviewer="$(select_balanced_infra_reviewer "$reviewer")"
      prefilled_reviewer="$reviewer"
    fi
    if [[ -n "$infra_rewrite_original_reviewer" && "$(lc "$infra_rewrite_original_reviewer")" != "$reviewer" ]]; then
      echo "$LOG_PREFIX NOTICE: create 偵測到 Bella 優先 gate（pattern=${infra_rewrite_pattern:-unknown}），reviewer 由 '$infra_rewrite_original_reviewer' 強制改為 '$reviewer'" >&2
    fi
  fi

  # Governance precedence (Anya 2026-07-28):
  # bella-priority-infra forced rewrite > self-review prohibition
  #   > affinity prefill > explicit --reviewer.
  # The only exception is causal, not identity-based: this create must have
  # actually entered the Bella-priority rewrite branch. All other final
  # reviewer==created_by cases remain hard failures.
  if [[ -n "$reviewer" && "$(lc "$reviewer")" == "$IDENTITY" ]]; then
    if [[ "$bella_priority_rewrite" -eq 1 ]]; then
      self_review_by_gate=1
      echo "$LOG_PREFIX NOTICE: create 的 Bella 優先 gate 強制 reviewer 與 created_by 同為 '$IDENTITY'（pattern=${infra_rewrite_pattern:-unknown}）；依 gate 優先序放行並寫入 self_review_by_gate 留痕" >&2
    else
      exit_usage "create: reviewer 不得與 created_by 相同（$IDENTITY）；請用 --reviewer 改指獨立 reviewer"
    fi
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
  history_entry=$(history_entry_with_caller "$history_entry" "$IDENTITY")

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
  if [[ -n "$infra_rewrite_original_reviewer" && "$(lc "$infra_rewrite_original_reviewer")" != "$reviewer" ]]; then
    local infra_rewrite_entry
    infra_rewrite_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" \
      --arg pattern "$infra_rewrite_pattern" --arg original_reviewer "$infra_rewrite_original_reviewer" \
      --arg forced_reviewer "$reviewer" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"infra_gate_rewrite",
        pattern:$pattern, original_reviewer:$original_reviewer, forced_reviewer:$forced_reviewer}')
    history_array="$(jq -c --argjson entry "$infra_rewrite_entry" '. + [$entry]' <<<"$history_array")"
  fi
  if [[ "$self_review_by_gate" -eq 1 ]]; then
    local self_review_by_gate_entry
    self_review_by_gate_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" \
      --arg pattern "$infra_rewrite_pattern" --arg created_by "$IDENTITY" \
      --arg original_reviewer "$infra_rewrite_original_reviewer" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"self_review_by_gate",
        pattern:$pattern, created_by:$created_by, original_reviewer:$original_reviewer}')
    history_array="$(jq -c --argjson entry "$self_review_by_gate_entry" '. + [$entry]' <<<"$history_array")"
  fi
  local probation_entry=""
  if [[ "$is_infra" -eq 1 && "$(lc "$reviewer")" == "yitang" ]]; then
    probation_entry="$(build_yitang_infra_probation_entry "$task_id")"
    if [[ -n "$probation_entry" ]]; then
      history_array="$(jq -c --argjson entry "$probation_entry" '. + [$entry]' <<<"$history_array")"
    fi
  fi

  jq -n \
    --arg task_id "$task_id" --arg slug "$slug" --arg title "$title" --arg status "pending" \
    --arg priority "$priority" --arg assigned "$assigned" --arg reviewer "$(lc "$reviewer")" \
    --argjson fast_track "$([ "$fast_track" == "true" ] && echo true || echo false)" \
    --arg created_at "$(now_iso)" --arg created_by "$IDENTITY" --arg deliver_to "$deliver_to" \
    --arg goal "$goal" --arg background "$background" --arg context "$context" \
    --argjson deliverables "$deliverables" --argjson acceptance_criteria "$acceptance_criteria" \
    --argjson out_of_scope "$out_of_scope" --arg review_focus "$review_focus" \
    --argjson verify_commands "$verify_commands" --argjson live_verify_commands "$live_verify_commands" \
    --argjson skills "$skills" \
    --argjson graduated_invariant "$graduated_invariant" \
    --argjson history "$history_array" \
    --argjson not_before null \
    --argjson project_id "$([ -n "$project_id" ] && jq -n --arg p "$project_id" '$p' || echo null)" \
    --arg no_live_verify_reason "$no_live_verify_reason" \
    --arg opt_out_by "$IDENTITY" --arg opt_out_ts "$(now_iso)" \
    '{
      task_id: $task_id, slug: $slug,
      title: (if $title == "" then null else $title end),
      status: $status, priority: $priority,
      assigned: $assigned, reviewer: $reviewer, fast_track: $fast_track,
      created_at: $created_at, created_by: $created_by, deliver_to: $deliver_to,
      goal: $goal, background: $background, context: $context,
      deliverables: $deliverables, acceptance_criteria: $acceptance_criteria,
      out_of_scope: $out_of_scope, verify_commands: $verify_commands,
      live_verify_commands: $live_verify_commands,
      skills: $skills,
      graduated_invariant: $graduated_invariant,
      review_focus: $review_focus, not_before: $not_before,
      project_id: $project_id,
      closeout: ({state:"pending", host_effect_policy:"required_for_commits"}
        + (if $no_live_verify_reason != "" then
            {live_verify_opt_out:{reason:$no_live_verify_reason, by:$opt_out_by, ts:$opt_out_ts}}
          else {} end)),
      history: $history
    }' > "$filename"
  stamp_transition_token "$filename"

  if [[ -n "$probation_entry" ]]; then
    mkdir -p "$(dirname "$FATQ_TRUST_LEDGER_AUDIT")" 2>/dev/null || true
    if ! jq -cn --argjson entry "$probation_entry" \
      '$entry + {event:"infra_reviewer_probation_assignment", subject_id:"yitang", category:"infra"}' \
      >> "$FATQ_TRUST_LEDGER_AUDIT"; then
      echo "$LOG_PREFIX WARNING: yitang infra probation 已寫入 task history，但 trust ledger audit append 失敗" >&2
    fi
  fi

  if [[ -n "$infra_rewrite_original_reviewer" && "$(lc "$infra_rewrite_original_reviewer")" != "$reviewer" ]]; then
    write_infra_gate_rewrite_relay "$task_id" "$filename" "$IDENTITY" "$infra_rewrite_original_reviewer" "$infra_rewrite_pattern" "$reviewer"
  fi
  flock -u "$reviewer_selection_fd"
  exec {reviewer_selection_fd}>&-

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
  if [[ "$action" == "claim" && "$to_dir" == "in_progress" ]]; then
    local spec_hash_patch
    spec_hash_patch="$(build_spec_hash_patch "$task_file")"
    history_entry="$(jq -c --argjson patch "$spec_hash_patch" '. + $patch' <<< "$history_entry")"
  fi

  local dest_dir dest_file dir tmp
  dest_dir="${FATQ_ROOT}/${to_dir}"
  dest_file="${dest_dir}/$(basename "$task_file")"
  if [[ -e "$dest_file" ]]; then
    TRANSFER_RESULT="conflict"
    TRANSFER_MSG="目標已存在，拒絕覆蓋活檔：$dest_file"
    return 6
  fi
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
  stamp_transition_token "$tmp"
  mv -f "$tmp" "$task_file"
  mkdir -p "$dest_dir"
  mv -n "$task_file" "$dest_file"
  if [[ -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"
    TRANSFER_MSG="目標在轉移期間出現，拒絕覆蓋活檔：$dest_file"
    return 6
  fi

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

  if ! can_builder_transition "$task_file" "$identity"; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="claim: identity $identity 不得執行 claim（規則：工作池轉移僅限 builder pool ∪ designer pool ∪ {mac-agent}；review/spec-review 型任務允許 assigned 本人）"
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

# Submit verification may run a broad suite for several minutes.  Holding the
# stable task lock for that whole process deadlocks any verifier which
# legitimately re-enters fatq-cli for the same task (for example to append an
# audit checkpoint).  Snapshot the transition-relevant task state under lock,
# verify the snapshot without the lock, then compare this signature again in
# the commit lock.  Ordinary comments/dispatch bookkeeping do not invalidate a
# successful gate, but every state transition and every non-derived task field
# does. transition_token is derived from history and changes with audit-only
# writes, so it must not invalidate the verification snapshot.
submit_transition_signature() {
  local task_file="$1"
  jq -S -c '{
    task: del(.history, .transition_token),
    transitions: [
      (.history // [])[]
      | select(
          (.from? != null) or (.to? != null)
          or ((.action // "") | IN(
            "create", "claim", "submit", "verdict_approve",
            "verdict_reject", "reassign", "force_mv", "archive"
          ))
        )
    ]
  }' "$task_file" | sha256sum | awk '{print $1}'
}

submit_check_locked() {
  local task_file="$1" identity="$2"

  if [[ ! -e "$task_file" ]]; then
    TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
    return 6
  fi

  local actual_dir assigned
  actual_dir="$(current_state_of "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file" 2>/dev/null)"
  TRANSFER_FROM="$actual_dir"

  if ! can_builder_transition "$task_file" "$identity"; then
    TRANSFER_RESULT="perm"
    TRANSFER_MSG="submit: identity $identity 不得執行 submit（規則：工作池轉移僅限 builder pool ∪ designer pool ∪ {mac-agent}；review/spec-review 型任務允許 assigned 本人）"
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
  return 0
}

SUBMIT_PREFLIGHT_SIGNATURE=""
submit_reject_blocked_locked() {
  local task_file="$1" identity="$2" not_before entry dir tmp
  fatq_task_is_blocked "$task_file" "$(now_epoch)" || return 1
  not_before="$(fatq_task_block_until "$task_file")"
  entry="$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --arg until "$not_before" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:"submit_blocked",
      reason:"hold:not_before", not_before:$until,
      from:"in_progress/", to:"in_progress/"}')"
  dir="$(dirname "$task_file")"
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
  if ! jq --argjson entry "$entry" '.history = ((.history // []) + [$entry])' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    TRANSFER_RESULT="error"
    TRANSFER_MSG="submit: 無法記錄被 hold 擋下的嘗試"
    return 4
  fi
  enforce_history_monotonic "$tmp"
  stamp_transition_token "$tmp"
  mv -f "$tmp" "$task_file"
  TRANSFER_RESULT="state"
  TRANSFER_MSG="submit: 任務 hold 生效中（not_before=$not_before）；submit 已拒絕。只有 fatq-cli hold/not_before 是機器阻斷，[BLOCKED] comment 僅供說明、不會阻斷"
  return 4
}

submit_preflight_locked() {
  local task_file="$1" identity="$2" snapshot_file="$3"
  submit_check_locked "$task_file" "$identity" || return $?
  submit_reject_blocked_locked "$task_file" "$identity"
  case $? in
    1) ;;
    *) return 4 ;;
  esac
  cp -- "$task_file" "$snapshot_file" || {
    TRANSFER_RESULT="error"
    TRANSFER_MSG="submit: 無法建立 verify snapshot"
    return 4
  }
  SUBMIT_PREFLIGHT_SIGNATURE="$(submit_transition_signature "$task_file")" || {
    TRANSFER_RESULT="error"
    TRANSFER_MSG="submit: 無法計算 verify snapshot signature"
    return 4
  }
  TRANSFER_RESULT="preflight_ok"
  return 0
}

submit_commit_locked() {
  local task_file="$1" identity="$2" expected_signature="$3"
  submit_check_locked "$task_file" "$identity" || return $?
  submit_reject_blocked_locked "$task_file" "$identity"
  case $? in
    1) ;;
    *) return 4 ;;
  esac
  local actual_signature actual_dir
  actual_dir="$(current_state_of "$task_file")"
  actual_signature="$(submit_transition_signature "$task_file")" || {
    TRANSFER_RESULT="error"
    TRANSFER_MSG="submit: 無法重算 task signature"
    return 4
  }
  if [[ "$actual_signature" != "$expected_signature" ]]; then
    TRANSFER_RESULT="conflict"
    TRANSFER_MSG="verify 期間 task 的狀態或 gate 相關內容已變更；請重新 submit"
    return 6
  fi
  _perform_mutation_locked "$task_file" "$actual_dir" "review" "submit" ""
}

submit_verify_failed_locked() {
  local task_file="$1" identity="$2" expected_signature="$3" verify_rc="$4"
  submit_check_locked "$task_file" "$identity" || return $?
  local actual_signature
  actual_signature="$(submit_transition_signature "$task_file")" || return 4
  # A failure against an obsolete snapshot must not be attached to newer task
  # state. The caller still returns E_VERIFY for the gate it actually ran.
  [[ "$actual_signature" == "$expected_signature" ]] || return 0

  local entry dir tmp
  entry="$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --argjson rc "$verify_rc" \
    '{ts:$ts, by:$by, via:"fatq-cli", action:"submit_verify_failed",
      verify_exit:$rc, from:"in_progress/", to:"in_progress/"}')"
  dir="$(dirname "$task_file")"
  tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
  if ! jq --argjson entry "$entry" '.history = ((.history // []) + [$entry])' \
      "$task_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 4
  fi
  enforce_history_monotonic "$tmp"
  stamp_transition_token "$tmp"
  mv -f "$tmp" "$task_file"
  return 0
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

  local advisor_notice=0
  if advisor_checkpoint_missing "$task_file"; then
    advisor_notice=1
  fi
  if [[ $advisor_notice -eq 1 ]]; then
    echo "$LOG_PREFIX NOTICE: 本單標記 advisor_required，但 history 未見 [advisor] checkpoint 留痕；Bella 可據此 NB/REJECT（warn-only，submit 照常放行）" >&2
  fi

  # Phase 1: validate and freeze the exact gate input while holding the stable
  # task lock. The broad verifier itself runs lock-free; phase 2 rechecks the
  # signature before the atomic transition, preserving the original race guard.
  local rc submit_snapshot verify_log verify_rc verify_detail
  submit_snapshot="$(mktemp)"
  verify_log="$(mktemp)"
  with_task_lock "$task_file" submit_preflight_locked "$IDENTITY" "$submit_snapshot"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    rm -f "$submit_snapshot" "$verify_log"
    exit_conflict "submit: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) rm -f "$submit_snapshot" "$verify_log"; exit_conflict "submit: $TRANSFER_MSG" ;;
    perm) rm -f "$submit_snapshot" "$verify_log"; exit_perm "$TRANSFER_MSG" ;;
    state) rm -f "$submit_snapshot" "$verify_log"; exit_state "$TRANSFER_MSG" ;;
    error) rm -f "$submit_snapshot" "$verify_log"; exit_state "submit: $TRANSFER_MSG" ;;
  esac

  # tee makes verifier diagnostics visible even for non-TTY/headless callers;
  # PIPESTATUS preserves the verifier's exit rather than tee's.
  "$FATQ_VERIFY_SH" "$submit_snapshot" 2>&1 | tee "$verify_log" >&2
  verify_rc=${PIPESTATUS[0]}
  verify_detail="$(<"$verify_log")"
  if [[ $verify_rc -ne 0 ]]; then
    with_task_lock "$task_file" submit_verify_failed_locked \
      "$IDENTITY" "$SUBMIT_PREFLIGHT_SIGNATURE" "$verify_rc" >/dev/null 2>&1 || true
    TRANSFER_MSG="submit: verify gate 未過（fatq-verify.sh exit $verify_rc）"
    err "$TRANSFER_MSG"
    if [[ $JSON_MODE -eq 1 ]]; then
      jq -n --arg code "E_VERIFY" --arg message "$TRANSFER_MSG" --arg detail "$verify_detail" \
        '{ok:false, code:$code, message:$message, detail:$detail}'
    fi
    rm -f "$submit_snapshot" "$verify_log"
    exit 5
  fi

  with_task_lock "$task_file" submit_commit_locked \
    "$IDENTITY" "$SUBMIT_PREFLIGHT_SIGNATURE"
  rc=$?
  rm -f "$submit_snapshot" "$verify_log"
  if [[ $rc -eq 9 ]]; then
    exit_conflict "submit: verify 後任務檔已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "submit: $TRANSFER_MSG" ;;
    perm) exit_perm "$TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "submit: $TRANSFER_MSG" ;;
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

  local task_id="" reason="" issue_type="" external_ts=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --reason) reason="$2"; shift 2 ;;
      --issue_type) issue_type="$2"; shift 2 ;;
      --ts) external_ts="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "verdict $sub: 需要 task_id"

  resolve_identity

  if [[ -n "$external_ts" ]]; then
    exit_usage "verdict $sub: --ts 不允許；verdict ts 一律由系統 date 生成"
  fi

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

  if [[ "$IDENTITY" == "yitang" ]]; then
    record_yitang_probation_verdict "$TRANSFER_MSG" "$sub"
  fi

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
    stamp_transition_token "$tmp"
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

# ── archive：終態任務 → archived/（非狀態機新態，admin only） ────────
cmd_archive() {
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
  [[ -z "$task_id" ]] && exit_usage "archive: 需要 task_id"

  resolve_identity
  if ! is_archive_admin_identity "$IDENTITY"; then
    exit_perm "archive: identity $IDENTITY 不得執行 archive（規則：僅 anya/laotu 可歸檔）"
  fi

  local task_file archived_file
  task_file="$(find_task_file "$task_id")"
  if [[ -z "$task_file" ]]; then
    archived_file="$(find_archived_task_file "$task_id")"
    if [[ -n "$archived_file" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_ok "$task_id" "${ARCHIVE_STATE_DIR}/" "${ARCHIVE_STATE_DIR}/" false
      else
        echo "$LOG_PREFIX archive OK: $task_id already in ${ARCHIVE_STATE_DIR}/"
      fi
      exit 0
    fi
    exit_notfound "archive: 找不到任務 $task_id"
  fi

  local from_dir
  from_dir="$(current_state_of "$task_file")"

  archive_locked() {
    local task_file="$1" expected_from="$2"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi

    local actual_dir
    actual_dir="$(current_state_of "$task_file")"
    if [[ "$actual_dir" != "$expected_from" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務已不在 ${expected_from}/（現於 ${actual_dir}/）"
      return 6
    fi
    case "$actual_dir" in
      done|wont_do|cancelled|rejected) ;;
      *)
        TRANSFER_RESULT="state"
        TRANSFER_MSG="archive: 任務目前在 ${actual_dir}/，archive 僅允許 done/wont_do/cancelled/rejected 終態"
        return 4
        ;;
    esac

    local history_entry dest_dir dest_file dir tmp
    history_entry=$(build_history_entry "archive" "${actual_dir}/" "${ARCHIVE_STATE_DIR}/" "")
    history_entry=$(history_entry_with_caller "$history_entry" "$IDENTITY")
    dest_dir="${FATQ_ROOT}/${ARCHIVE_STATE_DIR}"
    dest_file="${dest_dir}/$(basename "$task_file")"
    dir="$(dirname "$task_file")"
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

    if ! jq --argjson entry "$history_entry" \
        '.history = ((.history // []) + [$entry])' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"
      TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi

    enforce_history_monotonic "$tmp"
    stamp_transition_token "$tmp"
    mv -f "$tmp" "$task_file"
    mkdir -p "$dest_dir"
    mv -f "$task_file" "$dest_file"
    TRANSFER_RESULT="ok"
    TRANSFER_MSG="$dest_file"
    return 0
  }

  local rc
  with_task_lock "$task_file" archive_locked "$from_dir"
  rc=$?

  if [[ $rc -eq 9 ]]; then
    exit_conflict "archive: 任務檔在取鎖前已消失"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "archive: $TRANSFER_MSG" ;;
    state) exit_state "$TRANSFER_MSG" ;;
    error) exit_state "archive: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${from_dir}/" "${ARCHIVE_STATE_DIR}/" true
  else
    echo "$LOG_PREFIX archive OK: $task_id ${from_dir}/ -> ${ARCHIVE_STATE_DIR}/"
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
    stamp_transition_token "$tmp"
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
    stamp_transition_token "$tmp"
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
    stamp_transition_token "$tmp"
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

# ── set-live-verify：事後補填主機探針（5b1a；專用、write-once） ──
# 只替原本明確 opt-out、後來確實需要部署的單補上探針。這不是通用
# update-field：assigned 永遠不能替自己的交付定義驗收，即使同時是 creator。
cmd_set_live_verify() {
  local task_id="" value_json="" reason=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --value) value_json="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -n "$task_id" ]] || exit_usage "set-live-verify: 需要 task_id"
  [[ -n "$value_json" ]] || exit_usage "set-live-verify: --value 必填（非空 live_verify_commands JSON array）"
  [[ "$reason" =~ [^[:space:]] ]] \
    || exit_usage "set-live-verify: --reason trim 後不可為空；請說明當初為何未在建單時定義"
  reason="$(jq -rn --arg reason "$reason" '$reason | gsub("^\\s+|\\s+$"; "")')"

  if ! jq -e 'type == "array" and length > 0' <<< "$value_json" >/dev/null 2>&1; then
    exit_usage "set-live-verify: --value 必須是非空 JSON array"
  fi
  local verify_error
  verify_error="$(
    jq -r '
      to_entries[]
      | if (.value | type) != "object" then
          "set-live-verify: live_verify_commands[\(.key)] must be object"
        elif (.value.cmd | type) != "array" or (.value.cmd | length) == 0 then
          "set-live-verify: live_verify_commands[\(.key)].cmd must be non-empty string array"
        elif ([.value.cmd[] | select(type != "string")] | length) > 0 then
          "set-live-verify: live_verify_commands[\(.key)].cmd must be string array"
        elif ((.value | has("expect_exit")) and ((.value.expect_exit | type) != "number")) then
          "set-live-verify: live_verify_commands[\(.key)].expect_exit must be number"
        else empty end
    ' <<< "$value_json" | head -n 1
  )"
  [[ -z "$verify_error" ]] || exit_usage "$verify_error"

  reject_mutating_live_probes "set-live-verify" "$value_json"

  resolve_identity
  local task_file assigned created_by closeout_state
  task_file="$(find_task_file "$task_id")"
  [[ -n "$task_file" ]] || exit_notfound "set-live-verify: 找不到任務 $task_id"
  assigned="$(lc "$(jq -r '.assigned // .assigned_to // ""' "$task_file")")"
  created_by="$(lc "$(jq -r '.created_by // ""' "$task_file")")"
  if [[ "$IDENTITY" != "anya" && ( "$IDENTITY" != "$created_by" || "$IDENTITY" == "$assigned" ) ]]; then
    exit_perm "set-live-verify: 僅 anya 或非 assigned 的 created_by($created_by) 可補填；assigned($assigned) 不得定義自己的主機驗收"
  fi
  jq -e '.closeout | type == "object"' "$task_file" >/dev/null 2>&1 \
    || exit_state "set-live-verify: 此任務沒有 closeout schema（legacy 任務不在本路徑回填）"
  closeout_state="$(jq -r '.closeout.state // "pending"' "$task_file")"
  [[ "$closeout_state" != "closed" ]] || exit_state "set-live-verify: closeout 已 closed，不可補填"
  jq -e '(.live_verify_commands // []) | length == 0' "$task_file" >/dev/null 2>&1 \
    || exit_state "set-live-verify: live_verify_commands 已非空；write-once，不可覆寫"

  # Gate C runs only after authorization and the first write-once check, but
  # before any task mutation.  Reuse fatq-verify.sh so expect_exit/defaults and
  # argv execution remain identical to closeout verification.
  local probe_fixture probe_output probe_rc
  probe_fixture="$(mktemp "${TMPDIR:-/tmp}/fatq-live-probe.XXXXXX.json")" \
    || exit_state "set-live-verify: 無法建立 Gate C 暫存檔"
  if ! jq -n --argjson commands "$value_json" '{live_verify_commands:$commands}' > "$probe_fixture"; then
    rm -f "$probe_fixture"
    exit_state "set-live-verify: 無法建立 Gate C payload"
  fi
  probe_output="$("$FATQ_VERIFY_SH" --field live_verify_commands "$probe_fixture" 2>&1)"
  probe_rc=$?
  rm -f "$probe_fixture"
  if [[ "$probe_rc" -ne 0 ]]; then
    printf '%s\n' "$probe_output" >&2
    exit_verify "set-live-verify: Gate C rejected probe（fatq-verify.sh exit $probe_rc）；上方列出失敗項與實際 exit，live_verify_commands 尚未寫入、write-once 額度未消耗。修正後可直接重跑：fatq-cli.sh set-live-verify $task_id --as $IDENTITY --value '$value_json' --reason '$reason'"
  fi

  set_live_verify_locked() {
    local locked_file="$1"
    [[ -e "$locked_file" ]] || { TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"; return 6; }
    if [[ "$(jq -r '.closeout.state // "pending"' "$locked_file")" == "closed" ]]; then
      TRANSFER_RESULT="state"; TRANSFER_MSG="closeout 已 closed，不可補填"; return 4
    fi
    if ! jq -e '(.live_verify_commands // []) | length == 0' "$locked_file" >/dev/null 2>&1; then
      TRANSFER_RESULT="state"; TRANSFER_MSG="live_verify_commands 已非空；write-once，不可覆寫"; return 4
    fi

    local dir tmp ts history_entry
    dir="$(dirname "$locked_file")"
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    ts="$(now_iso)"
    history_entry="$(jq -n --arg ts "$ts" --arg by "$IDENTITY" --arg reason "$reason" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"set_live_verify", reason:$reason}')"
    if ! jq --argjson value "$value_json" --arg ts "$ts" --arg by "$IDENTITY" \
        --arg reason "$reason" --argjson entry "$history_entry" '
          .live_verify_commands = $value
          | .closeout.live_verify_backfill = {by:$by, ts:$ts, reason:$reason}
          | .history = ((.history // []) + [$entry])
        ' "$locked_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"; return 4
    fi
    enforce_history_monotonic "$tmp"
    stamp_transition_token "$tmp"
    mv -f "$tmp" "$locked_file"
    TRANSFER_RESULT="ok"; TRANSFER_MSG="$locked_file"
    return 0
  }

  local rc
  with_task_lock "$task_file" set_live_verify_locked
  rc=$?
  if [[ $rc -eq 9 || "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "set-live-verify: ${TRANSFER_MSG:-任務檔在取鎖前已消失}"
  elif [[ "$TRANSFER_RESULT" == "state" || "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "set-live-verify: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    jq --arg task_id "$task_id" '{ok:true, task_id:$task_id, live_verify_commands:.live_verify_commands, closeout:.closeout}' "$task_file"
  else
    echo "$LOG_PREFIX set-live-verify OK: $task_id by=$IDENTITY"
  fi
  exit 0
}

# ── closeout：閉環證據專用寫入層（3be1 / closed-loop pipeline v1.1） ──
# `--as` 在目前 FATQ CLI 架構中仍是宣告式身份；本入口將可用身份縮到
# deploy-pipeline/anya，並以獨立 via/action 留下可稽核紀錄。不得把 closeout.*
# 加進 update-field allowlist。
HOST_EFFECT_PROOF_JSON=""

verify_host_effect_or_die() {
  local task_file="$1" deploy_evidence="$2"
  local policy commit_count command_count capture_dir output_file output_sha
  local idx entry expect_exit actual_exit command_failed=0
  local stdout_file stderr_file stdout_sample stderr_sample
  local stdout_bytes stderr_bytes stdout_sha stderr_sha
  local stdout_truncated stderr_truncated command_proof command_proofs='[]'
  local -a cmd_array=()

  # Rollout boundary: pre-47f1 tasks have no policy key and retain their old
  # closeout behavior.  New tasks receive this key atomically at create time,
  # so no migration can reopen or strand already-active work (including 47f1).
  policy="$(jq -r '.closeout.host_effect_policy // "legacy"' "$task_file")"
  [[ "$policy" == "required_for_commits" ]] || return 0

  commit_count="$(jq -r '(.commits // []) | length' <<< "$deploy_evidence")"
  [[ "$commit_count" -gt 0 ]] || return 0

  command_count="$(jq -r '(.live_verify_commands // []) | length' "$task_file")"
  [[ "$command_count" -gt 0 ]] \
    || exit_state "closeout: host_effect_policy=required_for_commits 且有部署 commit 時，建單者必須預先定義非空 live_verify_commands；commit 存在不等於主機已生效"

  # Execute each probe directly as an argv array (never eval).  Hash the full
  # observed stdout followed by stderr for every command, in command order.
  # Persist only the first 8 KiB of each stream plus byte counts and truncation
  # flags so a noisy probe cannot inflate every task file without bound.
  capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/fatq-host-effect.XXXXXX")" \
    || exit_state "closeout: 無法建立主機生效探針輸出暫存目錄"
  output_file="$capture_dir/combined"
  : > "$output_file"
  for idx in $(seq 0 $((command_count - 1))); do
    entry="$(jq -c --argjson idx "$idx" '.live_verify_commands[$idx]' "$task_file")"
    if ! jq -e '
      type == "object"
      and (.cmd | type) == "array"
      and (.cmd | length) > 0
      and ([.cmd[] | select(type != "string")] | length) == 0
      and ((has("expect_exit") | not) or (.expect_exit | type) == "number")
    ' <<< "$entry" >/dev/null 2>&1; then
      rm -rf "$capture_dir"
      exit_state "closeout: live_verify_commands[$idx] 格式錯誤；cmd 必須是非空字串陣列，expect_exit 必須是數字"
    fi
    expect_exit="$(jq -r '.expect_exit // 0' <<< "$entry")"
    mapfile -t cmd_array < <(jq -r '.cmd[]' <<< "$entry")
    stdout_file="$capture_dir/$idx.stdout"
    stderr_file="$capture_dir/$idx.stderr"
    stdout_sample="$capture_dir/$idx.stdout.sample"
    stderr_sample="$capture_dir/$idx.stderr.sample"
    actual_exit=0
    "${cmd_array[@]}" > "$stdout_file" 2> "$stderr_file" || actual_exit=$?
    cat "$stdout_file" "$stderr_file" >> "$output_file"

    stdout_bytes="$(wc -c < "$stdout_file" | tr -d ' ')"
    stderr_bytes="$(wc -c < "$stderr_file" | tr -d ' ')"
    stdout_sha="$(sha256sum "$stdout_file" | awk '{print $1}')"
    stderr_sha="$(sha256sum "$stderr_file" | awk '{print $1}')"
    head -c 8192 "$stdout_file" > "$stdout_sample"
    head -c 8192 "$stderr_file" > "$stderr_sample"
    stdout_truncated=false
    stderr_truncated=false
    [[ "$stdout_bytes" -gt 8192 ]] && stdout_truncated=true
    [[ "$stderr_bytes" -gt 8192 ]] && stderr_truncated=true

    command_proof="$(jq -cn \
      --argjson index "$idx" --argjson expected_exit "$expect_exit" \
      --argjson actual_exit "$actual_exit" \
      --arg stdout_sha256 "$stdout_sha" --arg stderr_sha256 "$stderr_sha" \
      --argjson stdout_bytes "$stdout_bytes" --argjson stderr_bytes "$stderr_bytes" \
      --argjson stdout_truncated "$stdout_truncated" --argjson stderr_truncated "$stderr_truncated" \
      --rawfile stdout "$stdout_sample" --rawfile stderr "$stderr_sample" \
      '{index:$index, expected_exit:$expected_exit, actual_exit:$actual_exit,
        stdout:{sample:$stdout, bytes:$stdout_bytes, truncated:$stdout_truncated, sha256:$stdout_sha256},
        stderr:{sample:$stderr, bytes:$stderr_bytes, truncated:$stderr_truncated, sha256:$stderr_sha256}}')"
    command_proofs="$(jq -cn --argjson proofs "$command_proofs" --argjson proof "$command_proof" '$proofs + [$proof]')"

    if [[ "$actual_exit" -ne "$expect_exit" ]]; then
      command_failed=1
      echo "[fatq-cli] live_verify_commands[$idx] diagnostic (stdout first 8192 bytes; truncated=$stdout_truncated):" >&2
      cat "$stdout_sample" >&2
      echo >&2
      echo "[fatq-cli] live_verify_commands[$idx] diagnostic (stderr first 8192 bytes; truncated=$stderr_truncated):" >&2
      cat "$stderr_sample" >&2
      echo >&2
    fi
  done
  if [[ "$command_failed" -ne 0 ]]; then
    rm -rf "$capture_dir"
    exit_state "closeout: 主機生效探針失敗：至少一條 live_verify_commands 未達預期 exit code"
  fi

  output_sha="$(sha256sum "$output_file" | awk '{print $1}')"
  rm -rf "$capture_dir"
  HOST_EFFECT_PROOF_JSON="$(jq -cn \
    --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg verifier "fatq-cli:direct-array-exec" \
    --arg output_sha256 "$output_sha" --argjson command_count "$command_count" \
    --argjson commands "$command_proofs" \
    '{verified_at:$ts, triggered_by:$by, verifier:$verifier,
      field:"live_verify_commands", command_count:$command_count,
      result:"pass", output_sha256:$output_sha256,
      output_sha256_semantics:"sha256(command[0].stdout || command[0].stderr || ...)",
      sample_limit_bytes_per_stream:8192, commands:$commands}')"
}

cmd_closeout() {
  local task_id="" deploy_json="" live_json="" target_state=""
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as) shift 2 ;;
      --json) shift ;;
      --deploy-evidence) deploy_json="$2"; shift 2 ;;
      --live-check) live_json="$2"; shift 2 ;;
      --state) target_state="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  task_id="${positional[0]:-}"
  [[ -z "$task_id" ]] && exit_usage "closeout: 需要 task_id"
  [[ -z "${CLI_AS:-}" ]] && exit_usage "closeout: 必須明確傳入 --as deploy-pipeline|anya（不接受環境 fallback）"
  IDENTITY="$(lc "$CLI_AS")"
  case "$IDENTITY" in
    deploy-pipeline) ;;
    anya)
      is_known_identity "$IDENTITY" || exit_perm "closeout: anya 不在 team-config identity 名單"
      ;;
    *) exit_perm "closeout: identity $IDENTITY 不得寫入（僅 deploy-pipeline/anya）" ;;
  esac

  case "$target_state" in
    pending|closed) ;;
    *) exit_usage "closeout: --state 必須是 pending 或 closed" ;;
  esac
  [[ -n "$deploy_json" || -n "$live_json" ]] || exit_usage "closeout: 至少需要 --deploy-evidence 或 --live-check"

  if [[ -n "$deploy_json" ]]; then
    jq -e '
      type == "object"
      and ((keys_unsorted - ["commits","services_restarted","not_applicable","reason"]) | length == 0)
      and (.commits | type == "array")
      and (.services_restarted | type == "array")
      and (all(.commits[]; type == "string" and length > 0))
      and (all(.services_restarted[]; type == "string" and length > 0))
      and (
        if (.commits | length) == 0 then
          .not_applicable == true
          and (.reason | type == "string" and test("\\S"))
        else
          (has("not_applicable") | not)
          and (has("reason") | not)
        end
      )
    ' <<< "$deploy_json" >/dev/null 2>&1 \
      || exit_usage "closeout: --deploy-evidence 必須含 commits[]、services_restarted[]；commits 空時必須另含 not_applicable:true 與非空 reason，commits 非空時禁帶兩鍵；其他鍵拒絕，by/ts 由 CLI 寫入"
  fi
  if [[ -n "$live_json" ]]; then
    jq -e '
      type == "object"
      and ((keys_unsorted - ["verified_by","method","evidence"]) | length == 0)
      and (.verified_by | type == "string" and length > 0)
      and (.method == "auto-probe" or .method == "reviewer-live")
      and (.evidence | type == "string" and length > 0)
    ' <<< "$live_json" >/dev/null 2>&1 \
      || exit_usage "closeout: --live-check 必須只含 verified_by、method(auto-probe|reviewer-live)、非空 evidence；ts 由 CLI 寫入"
  fi

  local task_file current_state reviewer
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "closeout: 找不到任務 $task_id"
  current_state="$(current_state_of "$task_file")"
  [[ "$current_state" == "done" ]] || exit_state "closeout: 只有 done/ 任務可寫閉環證據（目前 ${current_state}/）"
  jq -e '.closeout | type == "object"' "$task_file" >/dev/null 2>&1 \
    || exit_state "closeout: 此任務沒有 closeout schema（歷史 done 單不回填）"

  reviewer="$(lc "$(jq -r '.reviewer // ""' "$task_file")")"
  if [[ -n "$live_json" ]]; then
    local live_method verified_by
    live_method="$(jq -r '.method' <<< "$live_json")"
    verified_by="$(lc "$(jq -r '.verified_by' <<< "$live_json")")"
    if [[ "$live_method" == "auto-probe" ]]; then
      [[ "$IDENTITY" == "deploy-pipeline" && "$verified_by" == "deploy-pipeline" ]] \
        || exit_perm "closeout: auto-probe 只能由 deploy-pipeline 寫入且 verified_by=deploy-pipeline"
    else
      [[ -n "$reviewer" && "$verified_by" == "$reviewer" ]] \
        || exit_perm "closeout: reviewer-live 的 verified_by 必須等於原 reviewer($reviewer)"
    fi
  fi

  if [[ "$target_state" == "closed" ]]; then
    local effective_deploy_json effective_live_json
    if [[ -n "$deploy_json" ]]; then
      effective_deploy_json="$deploy_json"
    else
      effective_deploy_json="$(jq -c '.closeout.deploy_evidence // {}' "$task_file")"
    fi
    if jq -e '.closeout.live_verify_backfill | type == "object"' "$task_file" >/dev/null 2>&1; then
      if [[ -n "$live_json" ]]; then
        effective_live_json="$live_json"
      else
        effective_live_json="$(jq -c '.closeout.live_check // {}' "$task_file")"
      fi
      [[ "$(jq -r '.method // ""' <<< "$effective_live_json")" == "reviewer-live" ]] \
        || exit_state "closeout: 事後補填的 live_verify_commands 必須由原 reviewer 以 live_check.method=reviewer-live 覆署；auto-probe 單獨不足"
    fi
    verify_host_effect_or_die "$task_file" "$effective_deploy_json" # HOST_EFFECT_GUARD
  fi

  closeout_locked() {
    local locked_file="$1"
    if [[ ! -e "$locked_file" ]]; then
      TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    if [[ "$(current_state_of "$locked_file")" != "done" ]]; then
      TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務已離開 done/"
      return 6
    fi
    if [[ "$(jq -r '.closeout.state // "pending"' "$locked_file")" == "closed" ]]; then
      TRANSFER_RESULT="state"; TRANSFER_MSG="closed 已封存，不可覆寫或降級"
      return 4
    fi
    if [[ -n "$deploy_json" ]] && jq -e '.closeout | has("deploy_evidence")' "$locked_file" >/dev/null 2>&1; then
      TRANSFER_RESULT="state"; TRANSFER_MSG="deploy_evidence 已存在，不可覆寫"
      return 4
    fi
    if [[ -n "$live_json" ]] && jq -e '.closeout | has("live_check")' "$locked_file" >/dev/null 2>&1; then
      TRANSFER_RESULT="state"; TRANSFER_MSG="live_check 已存在，不可覆寫"
      return 4
    fi
    if [[ "$target_state" == "closed" ]] && jq -e '.closeout.live_verify_backfill | type == "object"' "$locked_file" >/dev/null 2>&1; then
      local locked_live_method
      if [[ -n "$live_json" ]]; then
        locked_live_method="$(jq -r '.method // ""' <<< "$live_json")"
      else
        locked_live_method="$(jq -r '.closeout.live_check.method // ""' "$locked_file")"
      fi
      if [[ "$locked_live_method" != "reviewer-live" ]]; then
        TRANSFER_RESULT="state"; TRANSFER_MSG="事後補填的 live_verify_commands 必須由原 reviewer 以 reviewer-live 覆署；auto-probe 單獨不足"
        return 4
      fi
    fi

    local dir tmp history_entry has_deploy=false has_live=false has_host_effect=false
    [[ -n "$deploy_json" ]] && has_deploy=true
    [[ -n "$live_json" ]] && has_live=true
    [[ -n "$HOST_EFFECT_PROOF_JSON" ]] && has_host_effect=true
    dir="$(dirname "$locked_file")"
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"
    history_entry="$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg state "$target_state" \
      --argjson wrote_deploy "$has_deploy" --argjson wrote_live "$has_live" \
      --argjson wrote_host_effect "$has_host_effect" \
      '{ts:$ts, by:$by, via:"fatq-cli-closeout", action:"closeout_update",
        closeout_state:$state, wrote_deploy_evidence:$wrote_deploy, wrote_live_check:$wrote_live,
        wrote_host_effect_proof:$wrote_host_effect,
        identity_source:"--as (declarative; auditable)"}')"
    history_entry="$(history_entry_with_caller "$history_entry" "$IDENTITY")"

    if ! jq --arg identity "$IDENTITY" --arg ts "$(now_iso)" --arg state "$target_state" \
        --argjson has_deploy "$has_deploy" --argjson has_live "$has_live" \
        --argjson deploy "${deploy_json:-null}" --argjson live "${live_json:-null}" \
        --argjson host_effect "${HOST_EFFECT_PROOF_JSON:-null}" --argjson entry "$history_entry" '
          .closeout = (.closeout // {state:"pending"})
          | if $has_deploy then .closeout.deploy_evidence = ($deploy + {by:$identity, ts:$ts}) else . end
          | if $has_live then .closeout.live_check = ($live + {ts:$ts}) else . end
          | if $host_effect != null then .closeout.host_effect_proof = $host_effect else . end
          | .closeout.state = $state
          | .history = ((.history // []) + [$entry])
        ' "$locked_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi

    if [[ "$target_state" == "closed" ]] && ! jq -e --arg reviewer "$reviewer" '
      (.closeout.deploy_evidence | type == "object")
      and (.closeout.deploy_evidence.commits | type == "array")
      and (all(.closeout.deploy_evidence.commits[]; type == "string" and length > 0))
      and (.closeout.deploy_evidence.services_restarted | type == "array")
      and (all(.closeout.deploy_evidence.services_restarted[]; type == "string" and length > 0))
      and (
        if (.closeout.deploy_evidence.commits | length) == 0 then
          .closeout.deploy_evidence.not_applicable == true
          and (.closeout.deploy_evidence.reason | type == "string" and test("\\S"))
        else
          (.closeout.deploy_evidence | has("not_applicable") | not)
          and (.closeout.deploy_evidence | has("reason") | not)
        end
      )
      and (.closeout.deploy_evidence.by == "deploy-pipeline" or .closeout.deploy_evidence.by == "anya")
      and (.closeout.deploy_evidence.ts | type == "string" and length > 0)
      and (.closeout.live_check | type == "object")
      and (.closeout.live_check.evidence | type == "string" and length > 0)
      and (.closeout.live_check.ts | type == "string" and length > 0)
      and (
        (.closeout.live_check.method == "auto-probe" and .closeout.live_check.verified_by == "deploy-pipeline")
        or
        (.closeout.live_check.method == "reviewer-live" and ((.closeout.live_check.verified_by | ascii_downcase) == $reviewer))
      )
    ' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      TRANSFER_RESULT="state"; TRANSFER_MSG="state=closed 需要 deploy_evidence 與 live_check 兩證據齊備"
      return 4
    fi

    enforce_history_monotonic "$tmp"
    stamp_transition_token "$tmp"
    mv -f "$tmp" "$locked_file"
    TRANSFER_RESULT="ok"; TRANSFER_MSG="$locked_file"
    return 0
  }

  local rc
  with_task_lock "$task_file" closeout_locked
  rc=$?
  if [[ $rc -eq 9 || "$TRANSFER_RESULT" == "conflict" ]]; then
    exit_conflict "closeout: ${TRANSFER_MSG:-任務檔在取鎖前已消失}"
  elif [[ "$TRANSFER_RESULT" == "state" || "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "closeout: $TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    jq --arg task_id "$task_id" '{ok:true, task_id:$task_id, closeout:.closeout}' "$task_file"
  else
    echo "$LOG_PREFIX closeout OK: $task_id state=$target_state by=$IDENTITY"
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
  [[ -z "$value_json" ]] && exit_usage "update-field: --value 必填（JSON value）"

  case "$field" in
    skills|graduated_invariant|reviewer|deliver_to) ;;
    closeout|closeout.*) exit_usage "update-field: closeout.* 一律拒絕；只能使用 fatq-cli closeout 專用子命令" ;;
    *) exit_usage "update-field: 只允許 skills、graduated_invariant、reviewer 或 deliver_to，得到 $field" ;;
  esac
  if [[ "$field" == "reviewer" || "$field" == "deliver_to" ]]; then
    if ! jq -e 'type=="string" and length>0' <<< "$value_json" >/dev/null 2>&1; then
      exit_usage "update-field $field: --value 必須是非空 JSON string"
    fi
  elif ! jq -e 'type=="array"' <<< "$value_json" >/dev/null 2>&1; then
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

  if [[ "$field" == "deliver_to" ]]; then
    [[ "$from_dir" == "pending" || "$from_dir" == "in_progress" || "$from_dir" == "rejected" ]] \
      || exit_state "update-field deliver_to: 僅允許 pending/in_progress/rejected，得到 $from_dir"
    if [[ "$IDENTITY" != "anya" && "$(lc "$created_by")" != "$IDENTITY" ]]; then
      exit_perm "update-field deliver_to: 僅 anya 或 created_by($created_by) 可更新"
    fi
    local requested_delivery
    requested_delivery="$(canonical_delivery_identity "$(jq -r '.' <<< "$value_json")")"
    [[ -n "$requested_delivery" ]] \
      || exit_usage "update-field deliver_to: 必須是 FATQ_TEAM_CONFIG 中唯一、非空的 bot state_dir"
    value_json="$(jq -cn --arg deliver_to "$(lc "$requested_delivery")" '$deliver_to')"
  elif [[ "$field" == "skills" ]]; then
    # skills 由建單/調度側標注；允許 Anya 與建單者補欄，不允許 builder/reviewer 自報膨脹。
    if [[ "$IDENTITY" != "anya" && "$(lc "$created_by")" != "$IDENTITY" ]]; then
      exit_perm "update-field skills: 僅 anya 或 created_by($created_by) 可更新"
    fi
  elif [[ "$field" == "graduated_invariant" ]]; then
    # graduated_invariant 可由建單者、builder submit 前、reviewer approve 前補填。
    local allowed=0
    [[ "$IDENTITY" == "anya" || "$(lc "$created_by")" == "$IDENTITY" ]] && allowed=1
    [[ "$from_dir" == "in_progress" && "$(lc "$assigned")" == "$IDENTITY" ]] && allowed=1
    if [[ "$from_dir" == "review" ]]; then
      [[ "$(lc "$reviewer")" == "$IDENTITY" || "$IDENTITY" == "bella" || "$IDENTITY" == "anya" ]] && allowed=1
    fi
    [[ "$allowed" -eq 1 ]] || exit_perm "update-field graduated_invariant: 僅建單者、assigned(in_progress) 或 reviewer(review) 可更新"
  else
    # Reviewer repair exists only for historical create-path defects. It is
    # creator/admin controlled and may only materialize the configured affinity
    # reviewer (infra tasks remain forced to Bella).
    if [[ "$IDENTITY" != "anya" && "$(lc "$created_by")" != "$IDENTITY" ]]; then
      exit_perm "update-field reviewer: 僅 anya 或 created_by($created_by) 可補填"
    fi
    local existing_reviewer requested_reviewer expected_reviewer infra_field_text
    existing_reviewer="$(jq -r '.reviewer // ""' "$task_file")"
    [[ -z "$existing_reviewer" ]] \
      || exit_perm "update-field reviewer: reviewer 已是 $existing_reviewer，此路徑僅供補缺，不可用於改派"
    requested_reviewer="$(lc "$(jq -r '.' <<< "$value_json")")"
    infra_field_text="$(jq -r '[(.context // "" | tostring), ((.deliverables // [])[]? | tostring)] | join(" ")' "$task_file" 2>/dev/null)"
    if is_infra_change "$(jq -r '.goal // ""' "$task_file")" "$infra_field_text"; then
      expected_reviewer="bella"
    else
      expected_reviewer="$(lc "$(get_affinity_default_for_creator "$created_by" reviewer)")"
    fi
    [[ -n "$expected_reviewer" ]] || exit_state "update-field reviewer: 找不到 created_by($created_by) 的 reviewer affinity"
    [[ "$requested_reviewer" == "$expected_reviewer" ]] \
      || exit_perm "update-field reviewer: 只能補 affinity reviewer($expected_reviewer)，得到 $requested_reviewer"
    value_json="$(jq -cn --arg reviewer "$requested_reviewer" '$reviewer')"
  fi

  update_field_locked() {
    local task_file="$1"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"
      TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local locked_state
    locked_state="$(current_state_of "$task_file")"
    if [[ "$field" == "deliver_to" ]]; then
      if [[ "$locked_state" != "pending" && "$locked_state" != "in_progress" && "$locked_state" != "rejected" ]]; then
        TRANSFER_RESULT="state"
        TRANSFER_MSG="update-field deliver_to: 僅允許 pending/in_progress/rejected，得到 $locked_state"
        return 4
      fi
      local locked_before locked_after
      locked_before="$(jq -r '.deliver_to // ""' "$task_file")"
      locked_after="$(jq -r '.' <<< "$value_json")"
      if [[ "$(lc "$locked_before")" == "$locked_after" ]]; then
        TRANSFER_RESULT="noop"
        return 0
      fi
    elif [[ "$field" == "reviewer" ]]; then
      local locked_existing_reviewer
      locked_existing_reviewer="$(jq -r '.reviewer // ""' "$task_file")"
      if [[ -n "$locked_existing_reviewer" ]]; then
        TRANSFER_RESULT="perm"
        TRANSFER_MSG="update-field reviewer: reviewer 已是 $locked_existing_reviewer，此路徑僅供補缺，不可用於改派"
        return 3
      fi
    fi
    local history_entry dir tmp
    if [[ "$field" == "deliver_to" ]]; then
      history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg field "$field" \
        --arg from_value "$locked_before" --arg to_value "$locked_after" \
        '{ts:$ts, by:$by, via:"fatq-cli", action:"update_field", field:$field,
          from_value:$from_value, to_value:$to_value}')
    else
      history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$IDENTITY" --arg field "$field" \
        '{ts:$ts, by:$by, via:"fatq-cli", action:"update_field", field:$field}')
    fi
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
    stamp_transition_token "$tmp"
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
  elif [[ "$TRANSFER_RESULT" == "perm" ]]; then
    exit_perm "$TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "error" ]]; then
    exit_state "update-field: $TRANSFER_MSG"
  elif [[ "$TRANSFER_RESULT" == "state" ]]; then
    exit_state "$TRANSFER_MSG"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    if [[ "$TRANSFER_RESULT" == "noop" ]]; then
      json_ok "$task_id" "${from_dir}/" "${from_dir}/" false
    else
      json_ok "$task_id" "${from_dir}/" "${from_dir}/" true
    fi
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
  stamp_transition_token "$tmp"
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
  stamp_transition_token "$tmp"
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
    bella) echo "bella|@Bellalovechl_Bot" ;;
    yitang) echo "yitang|@onesoup_bot" ;;
    kk) echo "kk|@ron0003_bot" ;;
    twinkle|星星人) echo "twinkle|@TwinkleCHL_bot" ;;
    orange) echo "orange|@WuTung_bot" ;;
    spark) echo "spark|" ;;
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
  stamp_transition_token "$tmp"
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
    local state_is_core=0 core_state
    for core_state in "${CORE_STATE_DIRS[@]}"; do
      if [[ "$state_filter" == "$core_state" ]]; then
        state_is_core=1
        break
      fi
    done
    if [[ "$state_is_core" -eq 1 ]]; then
      search_dirs=("$state_filter")
    else
      search_dirs=()
    fi
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

# ── force-mv：break-glass 轉移（admin + reason + override audit） ───────
cmd_force_mv() {
  local task_id="" to_state="" reason=""
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
  to_state="${positional[1]:-}"
  [[ -z "$task_id" || -z "$to_state" ]] && exit_usage "force-mv: 需要 task_id 與 to_state"
  [[ -z "$reason" ]] && exit_usage "force-mv: --reason 必填"
  is_core_state "$to_state" || exit_usage "force-mv: to_state 不支援：$to_state"

  resolve_identity
  is_admin_identity "$IDENTITY" || exit_perm "force-mv: identity $IDENTITY 不得執行（規則：僅 anya/bella 可破窗）"

  local task_file
  task_file="$(find_task_file "$task_id")"
  [[ -z "$task_file" ]] && exit_notfound "force-mv: 找不到任務 $task_id"

  force_mv_locked() {
    local task_file="$1" identity="$2" to_state="$3" reason="$4"
    if [[ ! -e "$task_file" ]]; then
      TRANSFER_RESULT="conflict"; TRANSFER_MSG="任務檔已消失"
      return 6
    fi
    local actual_dir task_id
    actual_dir="$(current_state_of "$task_file")"
    task_id="$(jq -r '.task_id // ""' "$task_file" 2>/dev/null)"
    TRANSFER_FROM="$actual_dir"

    local history_entry dest_dir dest_file dir tmp
    history_entry=$(jq -n --arg ts "$(now_iso)" --arg by "$identity" --arg from "${actual_dir}/" \
      --arg to "${to_state}/" --arg reason "$reason" \
      '{ts:$ts, by:$by, via:"fatq-cli", action:"force_mv", from:$from, to:$to,
        reason:$reason, overridden_rule:"fatq_state_machine"}')
    history_entry=$(history_entry_with_caller "$history_entry" "$identity")
    dest_dir="${FATQ_ROOT}/${to_state}"
    dest_file="${dest_dir}/$(basename "$task_file")"
    dir="$(dirname "$task_file")"
    tmp="$(mktemp "${dir}/.fatq-cli.XXXXXX")"

    if ! jq --argjson entry "$history_entry" --arg status "$to_state" \
        '.history = ((.history // []) + [$entry]) | .status = $status' \
        "$task_file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      TRANSFER_RESULT="error"; TRANSFER_MSG="jq 寫入失敗"
      return 4
    fi

    enforce_history_monotonic "$tmp"
    stamp_transition_token "$tmp"
    append_override_audit "$identity" "fatq_state_machine" "$task_id" "${actual_dir}/" "${to_state}/" "$reason"
    mv -f "$tmp" "$task_file"
    mkdir -p "$dest_dir"
    mv -f "$task_file" "$dest_file"
    TRANSFER_RESULT="ok"; TRANSFER_MSG="$dest_file"
    return 0
  }

  local rc
  with_task_lock "$task_file" force_mv_locked "$IDENTITY" "$to_state" "$reason"
  rc=$?
  if [[ $rc -eq 9 ]]; then
    exit_conflict "force-mv: 任務檔在取鎖前已消失（已被移走）"
  fi
  case "$TRANSFER_RESULT" in
    conflict) exit_conflict "force-mv: $TRANSFER_MSG" ;;
    error) exit_state "force-mv: $TRANSFER_MSG" ;;
  esac

  if [[ $JSON_MODE -eq 1 ]]; then
    json_ok "$task_id" "${TRANSFER_FROM}/" "${to_state}/" true
  else
    echo "$LOG_PREFIX force-mv OK: $task_id ${TRANSFER_FROM}/ -> ${to_state}/"
  fi
  exit 0
}

# ── validate：advisory enforcement scanner（fail-open + kill-switch） ────
cmd_validate() {
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

  if [[ -f "$FATQ_ENFORCEMENT_KILL_SWITCH" ]]; then
    [[ $JSON_MODE -eq 1 ]] && jq -n '{ok:true, mode:"disabled", violations:[]}'
    [[ $JSON_MODE -eq 0 ]] && echo "$LOG_PREFIX validate disabled by kill-switch"
    exit 0
  fi

  local violations="[]" task_inventory="[]" d f
  local search_dirs=("${CORE_STATE_DIRS[@]}")
  for d in "${search_dirs[@]}"; do
    [[ -d "${FATQ_ROOT}/${d}" ]] || continue
    while IFS= read -r -d '' f; do
      if ! jq empty "$f" >/dev/null 2>&1; then
        local bad
        bad=$(jq -cn --arg task_file "$f" --arg state "$d" --arg issue "invalid_json" \
          '{task_file:$task_file, state:$state, issue:$issue}')
        violations=$(jq --argjson v "$bad" '. + [$v]' <<<"$violations")
        continue
      fi
      local status token expected tid
      status="$(jq -r '.status // ""' "$f" 2>/dev/null)"
      tid="$(jq -r '.task_id // .id // ""' "$f" 2>/dev/null)"
      if [[ -n "$tid" ]]; then
        task_inventory=$(jq --arg task_id "$tid" --arg task_file "$f" --arg state "$d" \
          '. + [{task_id:$task_id, task_file:$task_file, state:$state}]' <<<"$task_inventory")
      fi
      token="$(jq -r '.transition_token // ""' "$f" 2>/dev/null)"
      expected="$(transition_token_for_file "$f" 2>/dev/null || true)"
      if [[ -n "$status" && "$status" != "$d" ]]; then
        local v
        v=$(jq -cn --arg task_id "$tid" --arg task_file "$f" --arg state "$d" --arg status "$status" \
          '{task_id:$task_id, task_file:$task_file, issue:"dir_status_mismatch", state:$state, status:$status}')
        violations=$(jq --argjson v "$v" '. + [$v]' <<<"$violations")
      fi
      if [[ -n "$token" && -n "$expected" && "$token" != "$expected" ]]; then
        local v
        v=$(jq -cn --arg task_id "$tid" --arg task_file "$f" \
          '{task_id:$task_id, task_file:$task_file, issue:"transition_token_mismatch"}')
        violations=$(jq --argjson v "$v" '. + [$v]' <<<"$violations")
      fi
    done < <(find "${FATQ_ROOT}/${d}" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
  done

  local duplicates
  duplicates=$(jq -c '
    sort_by(.task_id)
    | group_by(.task_id)[]
    | select(length > 1)
    | {
        task_id: .[0].task_id,
        issue: "duplicate_task_id",
        task_files: (map(.task_file)),
        states: (map(.state))
      }
  ' <<<"$task_inventory")
  while IFS= read -r duplicate; do
    [[ -n "$duplicate" ]] || continue
    violations=$(jq --argjson v "$duplicate" '. + [$v]' <<<"$violations")
  done <<<"$duplicates"

  # fail-open: validator never blocks queue movement; violations are advisory data.
  if [[ $JSON_MODE -eq 1 ]]; then
    jq --argjson violations "$violations" '{ok:true, mode:"advisory", violations:$violations}' <<<"{}"
  else
    jq -r '.[] | "\(.issue)\t\(.task_id // .task_file)"' <<<"$violations"
  fi
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════
# 主程式：解析全域 flag（--as / --json）後 dispatch 子命令
# ═══════════════════════════════════════════════════════════════════════

main() {
  local sub="${1:-}"
  [[ -z "$sub" ]] && exit_usage "需要子命令：create|claim|submit|verdict|reassign|archive|comment|query|hold|update-field|set-live-verify|closeout|approval|force-mv|validate"
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
    archive) cmd_archive "$@" ;;
    comment) cmd_comment "$@" ;;
    attach) cmd_attach "$@" ;;
    query) cmd_query "$@" ;;
    hold) cmd_hold "$@" ;;
    update-field) cmd_update_field "$@" ;;
    set-live-verify) cmd_set_live_verify "$@" ;;
    closeout) cmd_closeout "$@" ;;
    approval) cmd_approval "$@" ;;
    force-mv) cmd_force_mv "$@" ;;
    validate) cmd_validate "$@" ;;
    *)
      exit_usage "未知子命令：$sub"
      ;;
  esac
}

# Keep command execution explicit.  Sourcing this helper must only load its
# functions; otherwise a shell fixture can accidentally execute a CLI command
# against the default queue.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

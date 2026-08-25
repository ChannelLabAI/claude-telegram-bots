#!/usr/bin/env bash
# closeout-autoprobe.sh — run registered FATQ live probes as deploy-pipeline.
set -uo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_CLI_SH="${FATQ_CLI_SH:-/home/oldrabbit/.claude-bots/shared/bin/fatq-cli.sh}"
AUTOPROBE_STATE="${FATQ_AUTOPROBE_STATE:-/home/oldrabbit/.claude-bots/shared/.closeout-autoprobe-state.json}"
AUTOPROBE_LOG_DIR="${FATQ_AUTOPROBE_LOG_DIR:-/home/oldrabbit/.claude-bots/logs/closeout-autoprobe}"
AUTOPROBE_REPOS="${FATQ_AUTOPROBE_REPOS:-/home/oldrabbit/.claude-bots:/home/oldrabbit/.claude-bots/mvp:/home/oldrabbit/.claude-bots/gateway-builder:/home/oldrabbit/.claude-bots/pod-system:/home/oldrabbit/.claude-bots/shared/memocean-mcp:/home/oldrabbit/pm-hub}"

DRY_RUN=0
LIMIT=10
MAX_SECONDS=300
BACKOFF_SECONDS=21600
ONLY_TASK=""

usage() {
  cat >&2 <<'EOF'
Usage: closeout-autoprobe.sh [--dry-run] [--limit N] [--max-seconds N]
                             [--backoff-seconds N] [--task TASK_ID]
EOF
  exit 2
}

positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --limit) [[ $# -ge 2 ]] || usage; LIMIT="$2"; shift 2 ;;
    --max-seconds) [[ $# -ge 2 ]] || usage; MAX_SECONDS="$2"; shift 2 ;;
    --backoff-seconds) [[ $# -ge 2 ]] || usage; BACKOFF_SECONDS="$2"; shift 2 ;;
    --task) [[ $# -ge 2 && -n "$2" ]] || usage; ONLY_TASK="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

positive_integer "$LIMIT" || usage
positive_integer "$MAX_SECONDS" || usage
positive_integer "$BACKOFF_SECONDS" || usage
for required_command in jq git grep timeout flock sha256sum; do
  command -v "$required_command" >/dev/null 2>&1 \
    || { echo "[closeout-autoprobe] required command not found: $required_command" >&2; exit 2; }
done
[[ -x "$FATQ_CLI_SH" ]] || { echo "[closeout-autoprobe] fatq-cli not executable: $FATQ_CLI_SH" >&2; exit 2; }

# systemctl --user otherwise reports "No medium found" when a scheduler did
# not inherit this variable, which is indistinguishable from a real outage.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

mkdir -p "$AUTOPROBE_LOG_DIR" "$(dirname "$AUTOPROBE_STATE")"
RUN_STARTED_EPOCH="${FATQ_AUTOPROBE_NOW_EPOCH:-$(date +%s)}"
RUN_STARTED_ISO="$(date --iso-8601=seconds)"
RUN_LOG="$AUTOPROBE_LOG_DIR/$(date '+%Y%m%d-%H%M%S')-$$.log"
LOCK_FILE="${AUTOPROBE_STATE}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf '[closeout-autoprobe] another run holds %s; exit without work\n' "$LOCK_FILE"
  exit 0
fi

log() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$RUN_LOG"
}

STATE_JSON='{"failures":{}}'
if [[ -s "$AUTOPROBE_STATE" ]] && jq -e '.failures | type == "object"' "$AUTOPROBE_STATE" >/dev/null 2>&1; then
  STATE_JSON="$(jq -c '.' "$AUTOPROBE_STATE")"
fi

state_failure() {
  local task_id="$1" reason="$2" now_epoch="$3"
  STATE_JSON="$(jq -c --arg id "$task_id" --arg reason "$reason" --argjson at "$now_epoch" \
    '.failures[$id] = {failed_at:$at, reason:$reason}' <<<"$STATE_JSON")"
}

state_clear() {
  local task_id="$1"
  STATE_JSON="$(jq -c --arg id "$task_id" 'del(.failures[$id])' <<<"$STATE_JSON")"
}

write_state() {
  local dir tmp
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  dir="$(dirname "$AUTOPROBE_STATE")"
  tmp="$(mktemp "$dir/.closeout-autoprobe-state.XXXXXX")" || return 1
  if ! jq --arg ts "$(date --iso-8601=seconds)" '.updated_at=$ts' <<<"$STATE_JSON" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$AUTOPROBE_STATE"
}

declare -a REPOS=()
IFS=: read -r -a configured_repos <<<"$AUTOPROBE_REPOS"
for repo in "${configured_repos[@]}"; do
  [[ -n "$repo" ]] || continue
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPOS+=("$repo")
  fi
done

COMMITS_JSON='[]'
COMMIT_REPOS_JSON='[]'
COMMIT_REASON=""
COMMIT_METHOD=""
COMMIT_FALLBACK_REASON=""

resolve_task_id_commit() {
  local task_file="$1" short_id repo oid subject grep_pattern
  local saw_strict_match=0 resolved_entry

  short_id="$(basename "$task_file" .json)"
  if [[ ! "$short_id" =~ ^[0-9]{8}-[0-9]{4}-([0-9a-f]{4})(-|$) ]]; then
    COMMIT_REASON="invalid_task_short_id"
    return 1
  fi
  short_id="${BASH_REMATCH[1]}"
  grep_pattern="^[a-z][a-z0-9-]*\\(${short_id}\\)!?:[[:space:]]"

  for repo in "${REPOS[@]}"; do
    while IFS= read -r oid; do
      [[ -n "$oid" ]] || continue
      subject="$(git -C "$repo" show -s --format=%s "$oid" 2>/dev/null)" || continue
      # git log --grep searches the whole message. Re-check the subject so a
      # body-only mention cannot become deployment evidence.
      printf '%s\n' "$subject" | grep -Eq "${grep_pattern}.+" || continue
      saw_strict_match=1
      git -C "$repo" merge-base --is-ancestor "$oid" HEAD >/dev/null 2>&1 || continue
      resolved_entry="$(jq -cn --arg repo "$repo" --arg oid "$oid" '{repo:$repo,oid:$oid}')"
      COMMITS_JSON="$(jq -c --arg oid "$oid" \
        'if index($oid) then . else . + [$oid] end' <<<"$COMMITS_JSON")"
      COMMIT_REPOS_JSON="$(jq -c --argjson entry "$resolved_entry" \
        'if map(.oid) | index($entry.oid) then . else . + [$entry] end' <<<"$COMMIT_REPOS_JSON")"
    done < <(git -C "$repo" log --all --format=%H --extended-regexp --grep="$grep_pattern" 2>/dev/null)
  done

  if [[ "$(jq 'length' <<<"$COMMITS_JSON")" -gt 0 ]]; then
    COMMIT_METHOD="task_id_grep"
    return 0
  fi

  if [[ "$saw_strict_match" -eq 1 ]]; then
    COMMIT_REASON="not_on_production_head"
  else
    COMMIT_REASON="no_match"
  fi
  return 1
}

EFFECTIVE_REVIEWER=""
REVIEWER_LIVE_TS=""
resolve_effective_reviewer() {
  local task_file="$1"
  local verdict_action verdict_reviewer configured_reviewer legacy_reviewer
  verdict_action="$(jq -r '[.history // [] | .[] | select((.action // "") | test("^verdict_(approve|reject)$"))] | last | .action // ""' "$task_file")"
  verdict_reviewer="$(jq -r '[.history // [] | .[] | select((.action // "") | test("^verdict_(approve|reject)$"))] | last | .by // "" | ascii_downcase' "$task_file")"
  configured_reviewer="$(jq -r '.effective_reviewer // "" | ascii_downcase' "$task_file")"
  legacy_reviewer="$(jq -r '.reviewer // "" | ascii_downcase' "$task_file")"
  if [[ -n "$verdict_action" ]]; then
    EFFECTIVE_REVIEWER="$verdict_reviewer"
  elif [[ -n "$configured_reviewer" ]]; then
    EFFECTIVE_REVIEWER="$configured_reviewer"
  else
    EFFECTIVE_REVIEWER="$legacy_reviewer"
  fi
}

has_effective_reviewer_live_comment() {
  local task_file="$1"
  resolve_effective_reviewer "$task_file"
  REVIEWER_LIVE_TS=""
  [[ -n "$EFFECTIVE_REVIEWER" ]] || return 1
  REVIEWER_LIVE_TS="$(jq -r --arg reviewer "$EFFECTIVE_REVIEWER" '
    [
      .history // [] | .[]
      | select((.action // "") == "comment")
      | select(((.by // "") | tostring | ascii_downcase) == $reviewer)
      | select(((.text // "") | tostring | test("reviewer-live"; "i")))
    ]
    | last | .ts // ""
  ' "$task_file")"
  [[ -n "$REVIEWER_LIVE_TS" ]]
}

resolve_history_commits() {
  local task_file="$1" existing_deploy="$2"
  local candidates candidate repo oid structured text_candidates
  local resolved resolved_entry

  if [[ "$existing_deploy" -eq 1 ]]; then
    candidates="$(jq -r '.closeout.deploy_evidence.commits[]?' "$task_file")"
    if [[ -z "$candidates" ]] && jq -e '
      .closeout.deploy_evidence.commits == []
      and .closeout.deploy_evidence.not_applicable == true
      and (.closeout.deploy_evidence.reason | type == "string" and test("\\S"))
    ' "$task_file" >/dev/null 2>&1; then
      COMMIT_METHOD="existing_deploy_evidence_not_applicable"
      return 0
    fi
  else
    structured="$(jq -r '
      [
        .deploy_evidence.commits[]?, .deploy_evidence.commit?,
        .commits[]?, .commit?,
        .artifacts.commits[]?, .artifacts.commit?,
        .delivery.commits[]?, .delivery.commit?,
        (.history[]? | .commits[]?), (.history[]? | .commit?)
      ]
      | .[] | select(type == "string")
    ' "$task_file" 2>/dev/null)"
    text_candidates="$(jq -r '
      (.assigned // .assigned_to // "") as $assigned
      | .history[]?
      | select(.action == "comment")
      | select((.by // "") == $assigned or (.by // "") == "anya" or (.by // "") == "deploy-pipeline")
      | .text // empty
    ' "$task_file" 2>/dev/null \
      | sed -nE 's/.*([Cc][Oo][Mm][Mm][Ii][Tt][Ss]?)[[:space:]]*[:：=]?[[:space:]]*`?([0-9a-fA-F]{7,40})`?([^0-9a-fA-F].*)?$/\2/p')"
    candidates="$(printf '%s\n%s\n' "$structured" "$text_candidates" | awk 'NF && !seen[tolower($0)]++')"
  fi

  if [[ -z "$candidates" ]]; then
    COMMIT_REASON="missing_commit_evidence"
    return 1
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    candidate="${candidate,,}"
    if [[ ! "$candidate" =~ ^[0-9a-f]{7,40}$ ]]; then
      COMMIT_REASON="invalid_commit_syntax"
      return 1
    fi
    resolved='[]'
    for repo in "${REPOS[@]}"; do
      oid="$(git -C "$repo" rev-parse --verify "${candidate}^{commit}" 2>/dev/null)" || continue
      git -C "$repo" merge-base --is-ancestor "$oid" HEAD >/dev/null 2>&1 || continue
      resolved_entry="$(jq -cn --arg repo "$repo" --arg oid "$oid" '{repo:$repo,oid:$oid}')"
      resolved="$(jq -c --argjson entry "$resolved_entry" \
        'if map(.oid) | index($entry.oid) then . else . + [$entry] end' <<<"$resolved")"
    done
    if [[ "$(jq 'length' <<<"$resolved")" -eq 0 ]]; then
      COMMIT_REASON="commit_not_on_production_head:$candidate"
      return 1
    fi
    if [[ "$(jq 'length' <<<"$resolved")" -gt 1 ]]; then
      COMMIT_REASON="commit_ambiguous_across_repos:$candidate"
      return 1
    fi
    oid="$(jq -r '.[0].oid' <<<"$resolved")"
    repo="$(jq -r '.[0].repo' <<<"$resolved")"
    COMMITS_JSON="$(jq -c --arg oid "$oid" 'if index($oid) then . else . + [$oid] end' <<<"$COMMITS_JSON")"
    COMMIT_REPOS_JSON="$(jq -c --arg repo "$repo" --arg oid "$oid" \
      'if map(.oid) | index($oid) then . else . + [{repo:$repo,oid:$oid}] end' <<<"$COMMIT_REPOS_JSON")"
  done <<<"$candidates"

  if [[ "$existing_deploy" -eq 0 && "$(jq 'length' <<<"$COMMITS_JSON")" -eq 0 ]]; then
    COMMIT_REASON="missing_commit_evidence"
    return 1
  fi
  COMMIT_METHOD="$([[ "$existing_deploy" -eq 1 ]] && echo existing_deploy_evidence || echo history)"
  return 0
}

collect_and_verify_commits() {
  local task_file="$1" existing_deploy="$2"
  local grep_reason history_reason
  COMMITS_JSON='[]'
  COMMIT_REPOS_JSON='[]'
  COMMIT_REASON=""
  COMMIT_METHOD=""
  COMMIT_FALLBACK_REASON=""

  if [[ "$existing_deploy" -eq 1 ]]; then
    resolve_history_commits "$task_file" "$existing_deploy"
    return $?
  fi

  if resolve_task_id_commit "$task_file"; then
    return 0
  fi
  grep_reason="$COMMIT_REASON"
  COMMITS_JSON='[]'
  COMMIT_REPOS_JSON='[]'
  if resolve_history_commits "$task_file" 0; then
    COMMIT_FALLBACK_REASON="$grep_reason"
    return 0
  fi
  history_reason="$COMMIT_REASON"
  COMMIT_REASON="task_id_grep_${grep_reason}_history_${history_reason}"
  return 1
}

PROBE_OK=0
PROBE_REASON=""
PROBE_EVIDENCE=""
run_probes() {
  local task_file="$1" task_id="$2" deadline="$3"
  local count idx entry expect_exit actual_exit remaining command_json
  local started_at finished_at probe_dir stdout_file stderr_file stdout_sample stderr_sample
  local stdout_text stderr_text proof proofs='[]'
  local -a command=()
  PROBE_OK=0
  PROBE_REASON=""
  PROBE_EVIDENCE=""
  count="$(jq -r '(.live_verify_commands // []) | length' "$task_file")"
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/closeout-autoprobe.XXXXXX")" || { PROBE_REASON="tempdir_failed"; return 1; }

  for ((idx=0; idx<count; idx++)); do
    entry="$(jq -c --argjson idx "$idx" '.live_verify_commands[$idx]' "$task_file")"
    if ! jq -e '
      type == "object"
      and (.cmd | type == "array" and length > 0)
      and all(.cmd[]; type == "string")
      and ((.expect_exit // 0) | type == "number")
    ' <<<"$entry" >/dev/null 2>&1; then
      PROBE_REASON="invalid_probe:$idx"
      rm -rf "$probe_dir"
      return 1
    fi
    expect_exit="$(jq -r '.expect_exit // 0' <<<"$entry")"
    command_json="$(jq -c '.cmd' <<<"$entry")"
    mapfile -t command < <(jq -r '.cmd[]' <<<"$entry")
    remaining=$((deadline - $(date +%s)))
    if [[ "$remaining" -le 0 ]]; then
      PROBE_REASON="time_limit"
      rm -rf "$probe_dir"
      return 1
    fi
    stdout_file="$probe_dir/$idx.stdout"
    stderr_file="$probe_dir/$idx.stderr"
    stdout_sample="$probe_dir/$idx.stdout.sample"
    stderr_sample="$probe_dir/$idx.stderr.sample"
    started_at="$(date --iso-8601=seconds)"
    actual_exit=0
    timeout --preserve-status "${remaining}s" "${command[@]}" >"$stdout_file" 2>"$stderr_file" || actual_exit=$?
    finished_at="$(date --iso-8601=seconds)"
    head -c 2048 "$stdout_file" >"$stdout_sample"
    head -c 2048 "$stderr_file" >"$stderr_sample"
    stdout_text="$(tr '\000' '?' <"$stdout_sample")"
    stderr_text="$(tr '\000' '?' <"$stderr_sample")"
    proof="$(jq -cn --argjson index "$idx" --arg command "$command_json" \
      --arg started_at "$started_at" --arg finished_at "$finished_at" \
      --argjson expected_exit "$expect_exit" --argjson actual_exit "$actual_exit" \
      --arg stdout "$stdout_text" --arg stderr "$stderr_text" \
      '{index:$index,command:$command,started_at:$started_at,finished_at:$finished_at,
        expected_exit:$expected_exit,actual_exit:$actual_exit,stdout:$stdout,stderr:$stderr}')"
    proofs="$(jq -c --argjson proof "$proof" '. + [$proof]' <<<"$proofs")"
    log "task=$task_id probe=$idx command=$command_json expected=$expect_exit actual=$actual_exit started=$started_at finished=$finished_at"
    if [[ "$actual_exit" -ne "$expect_exit" ]]; then
      PROBE_REASON="probe_failed:$idx:expected=$expect_exit:actual=$actual_exit"
      PROBE_EVIDENCE="$(jq -r '
        map("executed_at=" + .started_at + " command=" + .command +
            " expected_exit=" + (.expected_exit|tostring) + " actual_exit=" + (.actual_exit|tostring) +
            " stdout=" + (.stdout|tojson) + " stderr=" + (.stderr|tojson)) | join("\\n")
      ' <<<"$proofs")"
      rm -rf "$probe_dir"
      return 1
    fi
  done

  PROBE_EVIDENCE="$(jq -r '
    map("executed_at=" + .started_at + " command=" + .command +
        " expected_exit=" + (.expected_exit|tostring) + " actual_exit=" + (.actual_exit|tostring) +
        " stdout=" + (.stdout|tojson) + " stderr=" + (.stderr|tojson)) | join("\\n")
  ' <<<"$proofs")"
  PROBE_OK=1
  rm -rf "$probe_dir"
  return 0
}

declare -A SKIPS=()
processed=0
succeeded=0
failed=0
skipped=0
eligible_seen=0
deadline=$((RUN_STARTED_EPOCH + MAX_SECONDS))

skip() {
  local reason="$1" task_id="$2" category
  category="${reason%%:*}"
  SKIPS["$category"]=$(( ${SKIPS["$category"]:-0} + 1 ))
  skipped=$((skipped + 1))
  log "task=$task_id action=skip reason=$reason"
}

log "run_started=$RUN_STARTED_ISO mode=$([[ "$DRY_RUN" -eq 1 ]] && echo dry-run || echo normal) limit=$LIMIT max_seconds=$MAX_SECONDS backoff_seconds=$BACKOFF_SECONDS xdg_runtime_dir=$XDG_RUNTIME_DIR"

shopt -s nullglob
task_files=("$FATQ_ROOT"/done/*.json)
inventory="$(mktemp "${TMPDIR:-/tmp}/closeout-autoprobe-inventory.XXXXXX")" || exit 1
inventory_filter='
  [
    input_filename,
    (.task_id // .id // ""),
    (if (.closeout | type) == "object" then "object" else "missing" end),
    (.closeout.state // "pending"),
    (if ((.live_verify_commands // []) | type) == "array" then ((.live_verify_commands // []) | length | tostring) else "invalid" end),
    (if (.closeout.live_verify_backfill | type) == "object" then "1" else "0" end),
    (if (.closeout.live_check | type) == "object" then "1" else "0" end),
    (if (.closeout.deploy_evidence | type) == "object" then "1" else "0" end)
  ] | join("\u001f")
'
if ! jq -r "$inventory_filter" "${task_files[@]}" >"$inventory" 2>/dev/null; then
  # The normal queue is valid JSON. This slower fallback exists so one damaged
  # file is classified explicitly instead of hiding every later task.
  : >"$inventory"
  for task_file in "${task_files[@]}"; do
    if ! jq -r "$inventory_filter" "$task_file" >>"$inventory" 2>/dev/null; then
      printf '%s\037\037invalid\037pending\037invalid\0370\0370\0370\n' "$task_file" >>"$inventory"
    fi
  done
fi

while IFS=$'\037' read -r task_file task_id closeout_kind closeout_state probe_count has_backfill has_live_check existing_deploy; do
  if [[ "$closeout_kind" == "invalid" ]]; then
    skip invalid_json "$(basename "$task_file")"
    continue
  fi
  if [[ -z "$task_id" ]]; then
    skip missing_task_id "$(basename "$task_file")"
    continue
  fi
  [[ -z "$ONLY_TASK" || "$task_id" == "$ONLY_TASK" ]] || continue

  if [[ "$closeout_state" == "closed" ]]; then
    skip already_closed "$task_id"
    continue
  fi
  if [[ "$closeout_kind" != "object" ]]; then
    skip no_closeout_schema "$task_id"
    continue
  fi
  if [[ ! "$probe_count" =~ ^[0-9]+$ ]]; then
    skip invalid_probe_schema "$task_id"
    continue
  fi
  if [[ "$probe_count" -eq 0 ]]; then
    skip no_live_verify_commands "$task_id"
    continue
  fi
  if [[ "$has_backfill" -eq 1 ]]; then
    skip live_verify_backfill_requires_reviewer "$task_id"
    continue
  fi
  if [[ "$has_live_check" -eq 1 ]]; then
    skip live_check_already_present "$task_id"
    continue
  fi
  if has_effective_reviewer_live_comment "$task_file"; then
    skip "effective_reviewer_live_present:$EFFECTIVE_REVIEWER:$REVIEWER_LIVE_TS" "$task_id"
    continue
  fi

  now_epoch="$(date +%s)"
  failed_at="$(jq -r --arg id "$task_id" '.failures[$id].failed_at // 0' <<<"$STATE_JSON")"
  if [[ "$failed_at" =~ ^[0-9]+$ && "$failed_at" -gt 0 && $((now_epoch - failed_at)) -lt "$BACKOFF_SECONDS" ]]; then
    skip backoff "$task_id"
    continue
  fi

  eligible_seen=$((eligible_seen + 1))
  if [[ "$processed" -ge "$LIMIT" ]]; then
    skip limit_reached "$task_id"
    continue
  fi
  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    skip time_limit "$task_id"
    continue
  fi

  if ! collect_and_verify_commits "$task_file" "$existing_deploy"; then
    skip "$COMMIT_REASON" "$task_id"
    continue
  fi
  log "task=$task_id action=commit_resolved method=$COMMIT_METHOD fallback_reason=${COMMIT_FALLBACK_REASON:-none} repos=$COMMIT_REPOS_JSON commits=$COMMITS_JSON"

  processed=$((processed + 1))
  before_sha="$(sha256sum "$task_file" | awk '{print $1}')"
  if ! run_probes "$task_file" "$task_id" "$deadline"; then
    failed=$((failed + 1))
    log "task=$task_id action=probe_failed reason=$PROBE_REASON"
    [[ "$DRY_RUN" -eq 1 ]] || state_failure "$task_id" "$PROBE_REASON" "$(date +%s)"
    continue
  fi

  # A reviewer may post stronger evidence while a long probe is running. Yield
  # before either dry-run reporting or the write-once closeout call.
  if has_effective_reviewer_live_comment "$task_file"; then
    skip "effective_reviewer_live_present:$EFFECTIVE_REVIEWER:$REVIEWER_LIVE_TS" "$task_id"
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "task=$task_id action=would_close commits=$COMMITS_JSON evidence=$(jq -Rs . <<<"$PROBE_EVIDENCE")"
    succeeded=$((succeeded + 1))
    continue
  fi

  after_probe_sha="$(sha256sum "$task_file" | awk '{print $1}')"
  if [[ "$before_sha" != "$after_probe_sha" ]]; then
    failed=$((failed + 1))
    state_failure "$task_id" "task_changed_during_probe" "$(date +%s)"
    log "task=$task_id action=close_failed reason=task_changed_during_probe"
    continue
  fi

  live_json="$(jq -cn --arg evidence "$PROBE_EVIDENCE" \
    '{verified_by:"deploy-pipeline",method:"auto-probe",evidence:$evidence}')"
  closeout_args=(closeout "$task_id" --as deploy-pipeline)
  if [[ "$existing_deploy" -eq 0 ]]; then
    deploy_json="$(jq -cn --argjson commits "$COMMITS_JSON" '{commits:$commits,services_restarted:[]}')"
    closeout_args+=(--deploy-evidence "$deploy_json")
  fi
  closeout_args+=(--live-check "$live_json" --state closed)
  close_output="$(mktemp "${TMPDIR:-/tmp}/closeout-autoprobe-cli.XXXXXX")"
  close_rc=0
  "$FATQ_CLI_SH" "${closeout_args[@]}" >"$close_output" 2>&1 || close_rc=$?
  if [[ "$close_rc" -ne 0 ]]; then
    failed=$((failed + 1))
    state_failure "$task_id" "closeout_cli_exit:$close_rc" "$(date +%s)"
    log "task=$task_id action=close_failed reason=closeout_cli_exit:$close_rc output=$(head -c 2048 "$close_output" | jq -Rs .)"
    rm -f "$close_output"
    continue
  fi
  log "task=$task_id action=closed commits=$COMMITS_JSON output=$(head -c 2048 "$close_output" | jq -Rs .)"
  rm -f "$close_output"
  state_clear "$task_id"
  succeeded=$((succeeded + 1))
done <"$inventory"
rm -f "$inventory"

if ! write_state; then
  log "state_write=failed path=$AUTOPROBE_STATE"
  exit 1
fi

skip_json='{}'
for reason in "${!SKIPS[@]}"; do
  skip_json="$(jq -c --arg reason "$reason" --argjson count "${SKIPS[$reason]}" '.[$reason]=$count' <<<"$skip_json")"
done
summary="$(jq -cn --arg mode "$([[ "$DRY_RUN" -eq 1 ]] && echo dry-run || echo normal)" \
  --argjson processed "$processed" --argjson succeeded "$succeeded" --argjson failed "$failed" \
  --argjson skipped "$skipped" --argjson eligible_seen "$eligible_seen" --argjson skip_reasons "$skip_json" \
  '{mode:$mode,processed:$processed,succeeded:$succeeded,failed:$failed,skipped:$skipped,
    eligible_seen:$eligible_seen,skip_reasons:$skip_reasons}')"
log "summary=$summary"
exit 0

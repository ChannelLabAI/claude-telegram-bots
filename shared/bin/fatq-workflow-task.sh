#!/usr/bin/env bash
# Foreground support protocol for the optional fatq.workflow/v1 task field.
# This helper owns validation, attempt evidence, and atomic result publication;
# the selected model runner still owns graph execution inside the builder turn.

set -uo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FATQ_CLI="${FATQ_CLI:-$SCRIPT_DIR/fatq-cli.sh}"
CLI_TIMEOUT_SECS="${FATQ_WORKFLOW_CLI_TIMEOUT_SECS:-30}"
LOG_PREFIX="[fatq-workflow]"

die() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 4; }

find_task() {
  local task_id="$1" state candidate
  for state in pending in_progress review done rejected; do
    candidate="$FATQ_ROOT/$state/$task_id.json"
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

now_iso() { TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"; }

atomic_json_write() {
  local destination="$1" filter="$2" input="${3:-}"
  local directory tmp
  directory="$(dirname "$destination")"
  mkdir -p "$directory" || return 1
  tmp="$(mktemp "$directory/.workflow.XXXXXX")" || return 1
  if [[ -n "$input" ]]; then
    jq -S "$filter" "$input" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    jq -n -S "$filter" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  # Both names are in the destination directory; mv is one filesystem rename.
  mv -f "$tmp" "$destination"
}

task_comment() {
  local task_id="$1" actor="$2" text="$3"
  timeout "$CLI_TIMEOUT_SECS" bash "$FATQ_CLI" comment "$task_id" --as "$actor" --text "$text"
}

resolved_asset_root() {
  local task_id="$1"
  printf '%s/assets/%s\n' "${FATQ_ROOT%/}" "$task_id"
}

source_sha() {
  local task_file="$1" kind path
  kind="$(jq -r '.workflow.source.kind' "$task_file")"
  if [[ "$kind" == "inline" ]]; then
    jq -rj '.workflow.source.body' "$task_file" | sha256sum | awk '{print $1}'
  else
    path="$(jq -r '.workflow.source.path' "$task_file")"
    [[ -f "$path" ]] || return 2
    timeout 30 sha256sum "$path" | awk '{print $1}'
  fi
}

require_builder_task() {
  local task_file="$1" actor="$2" assigned status
  status="$(jq -r '.status // ""' "$task_file")"
  assigned="$(jq -r '.assigned // ""' "$task_file" | tr '[:upper:]' '[:lower:]')"
  [[ "$status" == "in_progress" ]] || die "task must be in_progress (got $status)"
  [[ "$assigned" == "${actor,,}" ]] || die "actor $actor is not assigned builder $assigned"
  jq -e '
    .workflow.schema == "fatq.workflow/v1"
    and (.workflow.runner == "codex-collaboration" or .workflow.runner == "claude-workflow-js")
    and (.workflow.source.kind == "inline" or .workflow.source.kind == "scriptPath")
    and (.workflow.source.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.workflow.args | type == "object")
    and (.workflow.budget.deadlineMs | type == "number" and . > 0 and . <= 5100000 and floor == .)
    and (.workflow.budget.maxParallelAgents | type == "number" and . > 0 and floor == .)
    and .workflow.outputs.root == "/home/oldrabbit/.claude-bots/tasks/assets/${task_id}"
    and .workflow.outputs.attemptDir == "attempt-${attempt}"
    and (.workflow.outputs.agentDir | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and .workflow.outputs.resultManifest == "/home/oldrabbit/.claude-bots/tasks/assets/${task_id}/result.json"
    and .workflow.failure.workerLoss == "restart-from-zero"
    and .workflow.failure.automaticAttempts == 1
    and .workflow.failure.preservePartialAttempts == true
  ' "$task_file" >/dev/null || die "task workflow violates fatq.workflow/v1"
}

cmd_prepare() {
  local task_id="$1" actor="$2" attempt="$3" task_file runner allowed expected actual
  task_file="$(find_task "$task_id")" || die "task not found: $task_id"
  require_builder_task "$task_file" "$actor"
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || die "attempt must be a positive integer"

  runner="$(jq -r '.workflow.runner' "$task_file")"
  allowed="${FATQ_WORKFLOW_RUNNERS:-codex-collaboration}"
  case ",$allowed," in
    *",$runner,"*) ;;
    *)
      task_comment "$task_id" "$actor" "[BLOCKED-SPEC] runner capability mismatch: requested=$runner available=$allowed" >/dev/null || true
      die "runner capability mismatch"
      ;;
  esac

  expected="$(jq -r '.workflow.source.sha256' "$task_file")"
  actual="$(source_sha "$task_file")" || actual="unreadable"
  if [[ "$actual" != "$expected" ]]; then
    task_comment "$task_id" "$actor" "[WORKFLOW RESULT] status=failed attempt=$attempt reason=source_sha_mismatch expected=$expected actual=$actual" >/dev/null || true
    echo "$LOG_PREFIX source_sha_mismatch expected=$expected actual=$actual" >&2
    exit 5
  fi

  local asset_root attempt_dir agent_dir partial started deadline_ms
  asset_root="$(resolved_asset_root "$task_id")"
  attempt_dir="$asset_root/attempt-$attempt"
  agent_dir="$attempt_dir/$(jq -r '.workflow.outputs.agentDir' "$task_file")"
  mkdir -p "$agent_dir" || die "cannot create attempt agent directory"
  partial="$attempt_dir/partial-attempt.json"
  [[ ! -e "$partial" ]] || die "attempt $attempt already exists; preserve it and choose the next attempt"
  started="$(now_iso)"
  deadline_ms="$(jq -r '.workflow.budget.deadlineMs' "$task_file")"
  TASK_ID="$task_id" ATTEMPT="$attempt" RUNNER="$runner" STARTED="$started" \
    SOURCE_SHA="$actual" DEADLINE_MS="$deadline_ms" \
    atomic_json_write "$partial" '{
      schema:"fatq.workflow-attempt/v1", taskId:env.TASK_ID,
      attempt:(env.ATTEMPT|tonumber), runner:env.RUNNER, status:"running",
      startedAt:env.STARTED, sourceSha256:env.SOURCE_SHA,
      deadlineMs:(env.DEADLINE_MS|tonumber),
      diagnostic:"If the builder wall-clock fuse terminates this foreground turn, this preserved running attempt plus the gateway wall_clock_cap comment is the partial-attempt record."
    }' || die "cannot atomically write partial attempt"
  printf '%s\n' "$attempt_dir"
}

cmd_commit() {
  local task_id="$1" actor="$2" attempt="$3" result_input="$4" task_file asset_root result_path partial status summary expected_sha runner artifact resolved
  task_file="$(find_task "$task_id")" || die "task not found: $task_id"
  require_builder_task "$task_file" "$actor"
  [[ -f "$result_input" ]] || die "result input not found"
  asset_root="$(resolved_asset_root "$task_id")"
  result_path="$asset_root/result.json"
  partial="$asset_root/attempt-$attempt/partial-attempt.json"
  [[ -f "$partial" ]] || die "prepare evidence missing for attempt $attempt"
  expected_sha="$(jq -r '.workflow.source.sha256' "$task_file")"
  runner="$(jq -r '.workflow.runner' "$task_file")"

  jq -e --arg task_id "$task_id" --argjson attempt "$attempt" --arg root "$asset_root/" \
    --arg source_sha "$expected_sha" --arg runner "$runner" '
    .schema == "fatq.workflow-result/v1"
    and .taskId == $task_id and .attempt == $attempt
    and .runner == $runner and .sourceSha256 == $source_sha
    and (.status == "succeeded" or .status == "failed")
    and (.nodes | type == "array")
    and (if .status == "succeeded" then (.nodes | length > 0 and all(.[]; .status == "succeeded"))
         else any(.nodes[]; .status == "failed") end)
    and ([((.artifacts // [])[]?), (.nodes[]?.artifacts[]?)]
         | all(type == "string" and startswith($root)))
  ' "$result_input" >/dev/null || die "result manifest violates fatq.workflow-result/v1"
  while IFS= read -r artifact; do
    resolved="$(realpath -m "$artifact" 2>/dev/null)" || die "cannot resolve artifact path"
    case "$resolved" in
      "$asset_root"/*) ;;
      *) die "artifact escapes task asset root: $artifact" ;;
    esac
  done < <(jq -r '((.artifacts // [])[]?), (.nodes[]?.artifacts[]?)' "$result_input")

  atomic_json_write "$result_path" '.' "$result_input" || die "cannot atomically publish result manifest"
  status="$(jq -r '.status' "$result_path")"
  summary="$(jq -r '.summary // ("nodes=" + ((.nodes|length)|tostring))' "$result_path" | tr '\n' ' ' | cut -c1-180)"
  FINISHED="$(now_iso)" STATUS="$status" RESULT="$result_path" \
    atomic_json_write "$partial" '. + {status:env.STATUS, finishedAt:env.FINISHED, resultManifest:env.RESULT}' "$partial" \
    || die "cannot atomically finalize partial attempt"
  task_comment "$task_id" "$actor" "[WORKFLOW RESULT] status=$status attempt=$attempt manifest=$result_path summary=$summary" >/dev/null \
    || die "result published but FATQ comment failed"
  printf '%s\n' "$result_path"
}

usage() {
  echo "Usage: $0 prepare TASK_ID --as BOT [--attempt N] | commit TASK_ID --as BOT --attempt N --result FILE" >&2
  exit 2
}

sub="${1:-}"; shift || true
task_id="${1:-}"; [[ -n "$task_id" ]] || usage; shift || true
actor=""; attempt="1"; result_input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --as) actor="$2"; shift 2 ;;
    --attempt) attempt="$2"; shift 2 ;;
    --result) result_input="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$actor" ]] || usage
case "$sub" in
  prepare) cmd_prepare "$task_id" "$actor" "$attempt" ;;
  commit) [[ -n "$result_input" ]] || usage; cmd_commit "$task_id" "$actor" "$attempt" "$result_input" ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# Regression fixture: create must preserve an explicit reviewer on critical
# infra work while retaining the reviewer-empty Bella-first safety default.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="${FATQ_CLI_UNDER_TEST:-$SCRIPT_DIR/../bin/fatq-cli.sh}"
PROD_ROOT="/home/oldrabbit/.claude-bots/tasks"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_BOT_ROUTING="$TMPROOT/bot-routing.yml"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_OVERRIDE_AUDIT="$TMPROOT/override-audit.jsonl"
export FATQ_TRUST_LEDGER_AUDIT="$TMPROOT/trust-ledger.audit.jsonl"
export FATQ_CREATE_GATE_DISABLED=1
export FATQ_MATTERMOST_DISABLE=1

if [[ "$FATQ_ROOT" == "$PROD_ROOT" || "$FATQ_ROOT" == "$PROD_ROOT/" ]]; then
  echo "[fatq-create-explicit-reviewer-test] FATAL: fixture points at production" >&2
  exit 2
fi
if [[ ! -x "$CLI_SH" ]]; then
  echo "[fatq-create-explicit-reviewer-test] FATAL: CLI is not executable: $CLI_SH" >&2
  exit 2
fi

mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR"

cat > "$FATQ_TEAM_CONFIG" <<'JSON'
{
  "assistants": [{"state_dir":"anya"}],
  "shared_pools": {
    "builder": [{"state_dir":"sancai"}],
    "reviewer": [{"state_dir":"bella"},{"state_dir":"yitang"}]
  },
  "external_identities": []
}
JSON

cat > "$FATQ_DISPATCH_AFFINITY" <<'JSON'
{
  "infra_patterns": ["shared/", "systemd", "security", "deployment"],
  "lines": {
    "anya": {"builder":"sancai", "reviewer":"bella"},
    "default": {"builder":"sancai", "reviewer":"bella"}
  }
}
JSON

cat > "$FATQ_BOT_ROUTING" <<'YAML'
bot_roster:
  - id: bella
    directory: bella
    role: reviewer
  - id: yitang
    directory: yitang
    role: reviewer
reviewers:
  - id: bella
  - id: yitang
YAML

failures=0

run_case() {
  local name="$1"
  shift
  local stdout_file="$TMPROOT/$name.stdout" stderr_file="$TMPROOT/$name.stderr" rc=0
  printf '[%s] COMMAND:' "$name"
  printf ' %q' bash "$CLI_SH" "$@"
  printf '\n'
  bash "$CLI_SH" "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
  echo "[$name] EXIT: $rc"
  echo "[$name] STDOUT:"
  sed 's/^/  /' "$stdout_file"
  echo "[$name] STDERR:"
  sed 's/^/  /' "$stderr_file"
  CASE_RC="$rc"
  CASE_STDOUT_FILE="$stdout_file"
  CASE_STDERR_FILE="$stderr_file"
}

common_args=(
  --as anya
  --goal "修 systemd security deployment gate"
  --background "critical infra fixture"
  --context "修改 shared/bin/fatq-cli.sh"
  --deliverables '["shared/bin/fatq-cli.sh"]'
  --acceptance_criteria '["reviewer routing is correct"]'
  --out_of_scope '["no production changes"]'
  --review_focus "explicit reviewer versus empty reviewer"
  --assigned sancai
  --no-live-verify "isolated non-deploy fixture"
  --json
)

run_case explicit-reviewer create --slug explicit-reviewer "${common_args[@]}" --reviewer yitang
explicit_stdout="$CASE_STDOUT_FILE"
explicit_stderr="$CASE_STDERR_FILE"
if [[ "$CASE_RC" -ne 0 ]] || ! jq -e '.ok == true and (.task_id | type == "string")' "$explicit_stdout" >/dev/null 2>&1; then
  echo "[explicit-reviewer] FAIL: create did not succeed with valid JSON"
  failures=$((failures + 1))
else
  explicit_tid="$(jq -r '.task_id' "$explicit_stdout")"
  explicit_task="$FATQ_ROOT/pending/$explicit_tid.json"
  explicit_value="$(jq -r '.reviewer' "$explicit_task")"
  rewrite_count="$(jq '[.history[]? | select(.action=="infra_gate_rewrite" or .action=="infra_gate_fallback")] | length' "$explicit_task")"
  if [[ "$explicit_value" != "yitang" ]]; then
    echo "[explicit-reviewer] FAIL: expected reviewer=yitang, got $explicit_value"
    failures=$((failures + 1))
  fi
  if grep -Fq 'Bella 優先 gate' "$explicit_stderr"; then
    echo "[explicit-reviewer] FAIL: Bella priority override NOTICE was emitted"
    failures=$((failures + 1))
  fi
  if [[ "$rewrite_count" != "0" ]]; then
    echo "[explicit-reviewer] FAIL: explicit reviewer produced $rewrite_count gate rewrite/fallback history entries"
    failures=$((failures + 1))
  fi
  echo "[explicit-reviewer] ACTUAL: reviewer=$explicit_value gate_history=$rewrite_count"
fi

run_case empty-reviewer create --slug empty-reviewer "${common_args[@]}"
empty_stdout="$CASE_STDOUT_FILE"
if [[ "$CASE_RC" -ne 0 ]] || ! jq -e '.ok == true and (.task_id | type == "string")' "$empty_stdout" >/dev/null 2>&1; then
  echo "[empty-reviewer] FAIL: create did not succeed with valid JSON"
  failures=$((failures + 1))
else
  empty_tid="$(jq -r '.task_id' "$empty_stdout")"
  empty_task="$FATQ_ROOT/pending/$empty_tid.json"
  empty_value="$(jq -r '.reviewer' "$empty_task")"
  if [[ "$empty_value" != "bella" ]]; then
    echo "[empty-reviewer] FAIL: expected infra default reviewer=bella, got $empty_value"
    failures=$((failures + 1))
  fi
  echo "[empty-reviewer] ACTUAL: reviewer=$empty_value"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "[fatq-create-explicit-reviewer-test] RESULT: FAIL ($failures assertion failures)"
  exit 1
fi

echo "[fatq-create-explicit-reviewer-test] RESULT: PASS"

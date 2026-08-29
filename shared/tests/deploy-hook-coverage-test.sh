#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$BASE/shared/bin/fatq-deploy-gate.sh"
INSTALLER="$BASE/shared/bin/install-deploy-hook.sh"
AUDIT="$BASE/shared/bin/deploy-hook-coverage-audit.sh"
ROLLOUT="$BASE/shared/bin/deploy-hook-rollout.sh"
FIXTURE="$(mktemp -d /tmp/deploy-hook-coverage-test.XXXXXX)"
trap 'rm -rf -- "$FIXTURE"' EXIT

setup_repo() {
  local repo="$1"
  git init -q -b master "$repo"
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm init
}
make_done() {
  local id="$1"
  jq -n --arg id "$id" '{task_id:$id,history:[{action:"verdict_approve",by:"yitang"}]}' \
    > "$FATQ_ROOT/done/$id.json"
}

export FATQ_ROOT="$FIXTURE/tasks"
export FATQ_DEPLOY_LOG="$FIXTURE/deploy.log"
mkdir -p "$FATQ_ROOT/done"
REPO="$FIXTURE/repo"
setup_repo "$REPO"
git -C "$REPO" checkout -qb feature
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm feature
git -C "$REPO" checkout -q master

# AC2 fixed: installed hook rejects an unapproved bare merge/ref update, and
# actual stderr plus exit code are visible.
bash "$INSTALLER" "$REPO" master "$FATQ_ROOT" >/dev/null
set +e
fixed_output=$(git -C "$REPO" merge --ff-only feature 2>&1)
fixed_rc=$?
set -e
echo "FIXED hook-present exit=$fixed_rc output=$fixed_output"
test "$fixed_rc" -ne 0
grep -F '沒有 deploy token' <<<"$fixed_output" >/dev/null

# AC2 mutant: removing the hook makes the exact same merge succeed.
rm -f "$REPO/.git/hooks/reference-transaction"
set +e
mutant_output=$(git -C "$REPO" merge --ff-only feature 2>&1)
mutant_rc=$?
set -e
echo "MUTANT hook-removed exit=$mutant_rc output=$mutant_output"
test "$mutant_rc" -eq 0

# AC3 true positive: reinstall, add a new target, and use a valid done/approve
# task through the normal gate. The ref advances and the token is consumed.
bash "$INSTALLER" "$REPO" master "$FATQ_ROOT" >/dev/null
git -C "$REPO" checkout -qb feature2
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm feature2
git -C "$REPO" checkout -q master
make_done t-valid
valid_output=$(bash "$GATE" t-valid "$REPO" feature2 2>&1)
echo "TRUE-POSITIVE exit=0 output=$valid_output"
grep -F 'DEPLOYED task=t-valid' <<<"$valid_output" >/dev/null
test ! -e "$REPO/.git/DEPLOY_APPROVED"
test "$(git -C "$REPO" rev-parse master)" = "$(git -C "$REPO" rev-parse feature2)"

# AC5 no-op: exit 0, token removed, NO-OP visible, and DEPLOYED absent from
# both invocation output and the log. Keep the explicit grep -c assertion.
make_done t-noop
: > "$FATQ_DEPLOY_LOG"
noop_output=$(bash "$GATE" t-noop "$REPO" master 2>&1)
noop_output_deployed_count=$(grep -c 'DEPLOYED' <<<"$noop_output" || true)
noop_log_deployed_count=$(grep -c 'DEPLOYED' "$FATQ_DEPLOY_LOG" || true)
echo "NO-OP exit=0 output_DEPLOYED_count=$noop_output_deployed_count log_DEPLOYED_count=$noop_log_deployed_count output=$noop_output"
test "$noop_output_deployed_count" -eq 0
test "$noop_log_deployed_count" -eq 0
grep -F 'NO-OP task=t-noop' <<<"$noop_output" >/dev/null
grep -F 'NO-OP task=t-noop' "$FATQ_DEPLOY_LOG" >/dev/null
test ! -e "$REPO/.git/DEPLOY_APPROVED"

# Production-root allowlist refuses an off-list repo before token creation.
set +e
refused_output=$(FATQ_ROOT=/home/oldrabbit/.claude-bots/tasks FATQ_DEPLOY_LOG="$FIXTURE/refused.log" \
  bash "$GATE" t-noop "$REPO" master 2>&1)
refused_rc=$?
set -e
echo "ALLOWLIST exit=$refused_rc output=$refused_output"
test "$refused_rc" -eq 3
grep -F 'canonical repo allowlist' <<<"$refused_output" >/dev/null
test ! -e "$REPO/.git/DEPLOY_APPROVED"

# AC6 audit: all executable is green; one missing is red and names the repo.
AUDIT_A="$FIXTURE/audit-a"; AUDIT_B="$FIXTURE/audit-b"
setup_repo "$AUDIT_A"; setup_repo "$AUDIT_B"
bash "$INSTALLER" "$AUDIT_A" master "$FATQ_ROOT" >/dev/null
bash "$INSTALLER" "$AUDIT_B" master "$FATQ_ROOT" >/dev/null
DEPLOY_HOOK_COVERAGE_REPOS="$AUDIT_A"$'\n'"$AUDIT_B" bash "$AUDIT" > "$FIXTURE/audit-green.out"
grep -F 'COVERAGE PASS missing=0 total=2' "$FIXTURE/audit-green.out" >/dev/null
rm -f "$AUDIT_B/.git/hooks/reference-transaction"
set +e
DEPLOY_HOOK_COVERAGE_REPOS="$AUDIT_A"$'\n'"$AUDIT_B" bash "$AUDIT" > "$FIXTURE/audit-red.out"
audit_rc=$?
set -e
test "$audit_rc" -ne 0
grep -F "MISSING repo=$AUDIT_B" "$FIXTURE/audit-red.out" >/dev/null
echo "AUDIT red-exit=$audit_rc output=$(tr '\n' ';' < "$FIXTURE/audit-red.out")"

# AC1 rollout ordering: capture all tokens, then clear all, then install.
ROLLOUT_ROOT="$FIXTURE/rollout-root"
for rel in '' infra pod-system shared/memocean-mcp; do
  setup_repo "$ROLLOUT_ROOT${rel:+/$rel}"
  jq -n --arg repo "${rel:-root}" '{task_id:("task-"+$repo),commit:("commit-"+$repo),approved_by:"yitang",ts:"2026-08-29T00:00:00Z"}' \
    > "$ROLLOUT_ROOT${rel:+/$rel}/.git/DEPLOY_APPROVED"
done
DEPLOY_HOOK_ROLLOUT_ROOT="$ROLLOUT_ROOT" \
DEPLOY_HOOK_ROLLOUT_FATQ_ROOT="$FATQ_ROOT" \
DEPLOY_HOOK_ROLLOUT_INSTALLER="$INSTALLER" \
DEPLOY_HOOK_ROLLOUT_EVIDENCE="$FIXTURE/rollout.log" \
  bash "$ROLLOUT" --apply > "$FIXTURE/rollout.out"
last_capture=$(grep -n 'PHASE=capture complete' "$FIXTURE/rollout.log" | cut -d: -f1)
last_clear=$(grep -n 'PHASE=clear complete' "$FIXTURE/rollout.log" | cut -d: -f1)
first_install=$(grep -n 'PHASE=install begin' "$FIXTURE/rollout.log" | cut -d: -f1)
test "$last_capture" -lt "$last_clear"
test "$last_clear" -lt "$first_install"
grep -F '"task_id":"task-root"' "$FIXTURE/rollout.log" >/dev/null
for rel in '' infra pod-system shared/memocean-mcp; do
  test ! -e "$ROLLOUT_ROOT${rel:+/$rel}/.git/DEPLOY_APPROVED"
  test -x "$ROLLOUT_ROOT${rel:+/$rel}/.git/hooks/reference-transaction"
done
echo "ROLLOUT capture_line=$last_capture clear_line=$last_clear install_line=$first_install"

echo "PASS deploy hook fixed/mutant/true-positive/no-op/allowlist/audit/rollout-order"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPROBE_SH="${AUTOPROBE_SH:-$SCRIPT_DIR/../bin/closeout-autoprobe.sh}"
CLI_SH="${CLI_SH:-$SCRIPT_DIR/../bin/fatq-cli.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_CLI_SH="$CLI_SH"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_ENFORCEMENT_KILL_SWITCH="$FATQ_ROOT/.fatq-enforcement-off"
export FATQ_CREATE_GATE_DISABLED=1
export FATQ_AUTOPROBE_STATE="$TMPROOT/autoprobe-state.json"
export FATQ_AUTOPROBE_LOG_DIR="$TMPROOT/logs"
export FATQ_AUTOPROBE_REPOS="$TMPROOT/production-repo"
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR" "$TMPROOT/fake-bin"
printf '%s\n' '{"assistants":[{"state_dir":"anya"}],"shared_pools":{"builder":[{"state_dir":"anna"}],"reviewer":[{"state_dir":"bella"}]},"external_identities":[]}' >"$FATQ_TEAM_CONFIG"
printf '%s\n' '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' >"$FATQ_DISPATCH_AFFINITY"

git init -q "$TMPROOT/production-repo"
git -C "$TMPROOT/production-repo" config user.email fixture@example.invalid
git -C "$TMPROOT/production-repo" config user.name fixture
printf 'deployed\n' >"$TMPROOT/production-repo/marker"
git -C "$TMPROOT/production-repo" add marker
git -C "$TMPROOT/production-repo" commit -qm deployed
commit="$(git -C "$TMPROOT/production-repo" rev-parse HEAD)"
main_branch="$(git -C "$TMPROOT/production-repo" branch --show-current)"

printf 'unrelated\n' >"$TMPROOT/production-repo/unrelated"
git -C "$TMPROOT/production-repo" add unrelated
git -C "$TMPROOT/production-repo" commit -qm 'chore: mention c3d4 in unrelated text'
printf 'grep deployed\n' >"$TMPROOT/production-repo/grep-deployed"
git -C "$TMPROOT/production-repo" add grep-deployed
git -C "$TMPROOT/production-repo" commit -qm 'feat(a1b2): deployed by task short id'
grep_commit="$(git -C "$TMPROOT/production-repo" rev-parse HEAD)"

git -C "$TMPROOT/production-repo" switch -qc undeployed
printf 'undeployed\n' >"$TMPROOT/production-repo/undeployed"
git -C "$TMPROOT/production-repo" add undeployed
git -C "$TMPROOT/production-repo" commit -qm 'fix(b4d5): exists but is not deployed'
undeployed_commit="$(git -C "$TMPROOT/production-repo" rev-parse HEAD)"
git -C "$TMPROOT/production-repo" switch -q "$main_branch"
fake_commit=0123456789abcdef0123456789abcdef01234567

if [[ -n "${FATQ_AUTOPROBE_HOST_SERVICE:-}" ]]; then
  xdg_probe="$(jq -cn --arg service "$FATQ_AUTOPROBE_HOST_SERVICE" \
    '[{cmd:["systemctl","--user","is-active","--quiet",$service],expect_exit:0}]')"
else
  cat >"$TMPROOT/fake-bin/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "${XDG_RUNTIME_DIR:-}" == "/run/user/$(id -u)" ]] || exit 91
[[ "${1:-}" == "--user" ]] || exit 92
exit 0
SH
  chmod +x "$TMPROOT/fake-bin/systemctl"
  export PATH="$TMPROOT/fake-bin:$PATH"
  xdg_probe='[{"cmd":["systemctl","--user","is-active","--quiet","fixture"],"expect_exit":0}]'
fi

make_task() {
  local id="$1" probes="$2" history="$3" closeout
  if [[ $# -ge 4 ]]; then
    closeout="$4"
  else
    closeout='{"state":"pending","host_effect_policy":"required_for_commits"}'
  fi
  jq -n --arg id "$id" --argjson probes "$probes" --argjson history "$history" --argjson closeout "$closeout" '
    {task_id:$id,slug:$id,status:"done",assigned:"anna",reviewer:"bella",
     live_verify_commands:$probes,closeout:$closeout,history:$history}
  ' >"$FATQ_ROOT/done/$id.json"
}

history="$(jq -cn --arg commit "$commit" '[{ts:"2026-08-16T00:00:00+08:00",by:"anna",action:"comment",commit:$commit}]')"
fake_history="$(jq -cn --arg commit "$fake_commit" '[{ts:"2026-08-16T00:00:00+08:00",by:"anna",action:"comment",commit:$commit}]')"
make_task pass '[{"cmd":["printf","host-ok"],"expect_exit":0}]' "$history"
make_task xdg "$xdg_probe" "$history"
make_task fail '[{"cmd":["bash","-c","printf red >&2; exit 7"],"expect_exit":0}]' "$history"
make_task no-probe '[]' "$history"
make_task bad-commit '[{"cmd":["true"],"expect_exit":0}]' "$fake_history"
make_task closed '[{"cmd":["true"],"expect_exit":0}]' "$history" '{"state":"closed","host_effect_policy":"required_for_commits"}'
grep_history="$(jq -cn --arg commit "$fake_commit" '[{ts:"2026-08-16T00:00:00+08:00",by:"anna",action:"comment",commit:$commit}]')"
fallback_history="$(jq -cn --arg commit "$commit" '[{ts:"2026-08-16T00:00:00+08:00",by:"anna",action:"comment",commit:$commit}]')"
undeployed_history="$(jq -cn --arg commit "$undeployed_commit" '[{ts:"2026-08-16T00:00:00+08:00",by:"anna",action:"comment",commit:$commit}]')"
make_task 20260816-0000-a1b2-grep-hit '[{"cmd":["true"],"expect_exit":0}]' "$grep_history"
make_task 20260816-0001-c3d4-false-positive '[{"cmd":["true"],"expect_exit":0}]' "$fake_history"
make_task 20260816-0002-e5f6-history-fallback '[{"cmd":["true"],"expect_exit":0}]' "$fallback_history"
make_task 20260816-0003-dead-both-fail '[{"cmd":["true"],"expect_exit":0}]' "$fake_history"
make_task 20260816-0004-b4d5-nonancestor '[{"cmd":["true"],"expect_exit":0}]' "$undeployed_history"

before="$TMPROOT/before.sha"
after="$TMPROOT/after.sha"
sha256sum "$FATQ_ROOT"/done/*.json | sort >"$before"
env -u XDG_RUNTIME_DIR bash "$AUTOPROBE_SH" --dry-run --limit 10 --max-seconds 30 --backoff-seconds 60 >"$TMPROOT/dry.log"
dry_rc=$?
sha256sum "$FATQ_ROOT"/done/*.json | sort >"$after"
[[ "$dry_rc" -eq 0 ]] || { echo "FAIL dry-run exit=$dry_rc"; exit 1; }
cmp -s "$before" "$after" || { echo "FAIL dry-run mutated a task"; exit 1; }
[[ ! -e "$FATQ_AUTOPROBE_STATE" ]] || { echo "FAIL dry-run wrote state"; exit 1; }
grep -q 'task=no-probe action=skip reason=no_live_verify_commands' "$TMPROOT/dry.log" || exit 1
grep -q 'task=bad-commit action=skip reason=task_id_grep_invalid_task_short_id_history_commit_not_on_production_head' "$TMPROOT/dry.log" || exit 1
grep -q 'task=closed action=skip reason=already_closed' "$TMPROOT/dry.log" || exit 1
grep -q 'task=xdg probe=0 .* actual=0 ' "$TMPROOT/dry.log" || exit 1
grep -Fq "task=20260816-0000-a1b2-grep-hit action=commit_resolved method=task_id_grep fallback_reason=none repos=[{\"repo\":\"$TMPROOT/production-repo\",\"oid\":\"$grep_commit\"}] commits=[\"$grep_commit\"]" "$TMPROOT/dry.log" || exit 1
grep -q 'task=20260816-0002-e5f6-history-fallback action=commit_resolved method=history fallback_reason=no_match ' "$TMPROOT/dry.log" || exit 1
grep -q 'task=20260816-0001-c3d4-false-positive action=skip reason=task_id_grep_no_match_history_commit_not_on_production_head' "$TMPROOT/dry.log" || exit 1
grep -q 'task=20260816-0003-dead-both-fail action=skip reason=task_id_grep_no_match_history_commit_not_on_production_head' "$TMPROOT/dry.log" || exit 1
grep -q 'task=20260816-0004-b4d5-nonancestor action=skip reason=task_id_grep_not_on_production_head_history_commit_not_on_production_head' "$TMPROOT/dry.log" || exit 1

# A cap still inventories every remaining task and reports the reason instead
# of silently stopping at the first eligible item.
env -u XDG_RUNTIME_DIR bash "$AUTOPROBE_SH" --dry-run --limit 1 --max-seconds 30 --backoff-seconds 60 >"$TMPROOT/limit.log"
grep -q 'action=skip reason=limit_reached' "$TMPROOT/limit.log" || exit 1

cp "$FATQ_ROOT/done/pass.json" "$TMPROOT/pass.before.json"
cp "$FATQ_ROOT/done/fail.json" "$TMPROOT/fail.before.json"
cp "$FATQ_ROOT/done/no-probe.json" "$TMPROOT/no-probe.before.json"
cp "$FATQ_ROOT/done/bad-commit.json" "$TMPROOT/bad-commit.before.json"
cp "$FATQ_ROOT/done/closed.json" "$TMPROOT/closed.before.json"
env -u XDG_RUNTIME_DIR bash "$AUTOPROBE_SH" --limit 10 --max-seconds 30 --backoff-seconds 60 >"$TMPROOT/live.log"
live_rc=$?
[[ "$live_rc" -eq 0 ]] || { echo "FAIL normal exit=$live_rc"; exit 1; }

jq -e --arg commit "$commit" '
  .closeout.state == "closed"
  and .closeout.deploy_evidence.commits == [$commit]
  and .closeout.live_check.method == "auto-probe"
  and .closeout.live_check.verified_by == "deploy-pipeline"
  and (.closeout.live_check.evidence | contains("command=[\"printf\",\"host-ok\"]"))
  and (.closeout.live_check.evidence | contains("actual_exit=0"))
  and (.closeout.live_check.evidence | contains("executed_at="))
' "$FATQ_ROOT/done/pass.json" >/dev/null || { echo "FAIL pass closeout shape"; jq '.closeout' "$FATQ_ROOT/done/pass.json"; exit 1; }
jq -e '.closeout.state == "closed" and .closeout.live_check.method == "auto-probe"' "$FATQ_ROOT/done/xdg.json" >/dev/null || exit 1
jq -e --arg commit "$grep_commit" '.closeout.state == "closed" and .closeout.deploy_evidence.commits == [$commit]' "$FATQ_ROOT/done/20260816-0000-a1b2-grep-hit.json" >/dev/null || exit 1
jq -e --arg commit "$commit" '.closeout.state == "closed" and .closeout.deploy_evidence.commits == [$commit]' "$FATQ_ROOT/done/20260816-0002-e5f6-history-fallback.json" >/dev/null || exit 1
cmp -s "$TMPROOT/fail.before.json" "$FATQ_ROOT/done/fail.json" || { echo "FAIL red probe wrote task"; exit 1; }
cmp -s "$TMPROOT/no-probe.before.json" "$FATQ_ROOT/done/no-probe.json" || { echo "FAIL empty probe wrote task"; exit 1; }
cmp -s "$TMPROOT/bad-commit.before.json" "$FATQ_ROOT/done/bad-commit.json" || { echo "FAIL bad commit wrote task"; exit 1; }
cmp -s "$TMPROOT/closed.before.json" "$FATQ_ROOT/done/closed.json" || { echo "FAIL closed task changed"; exit 1; }
jq -e '.failures.fail.reason | startswith("probe_failed:0")' "$FATQ_AUTOPROBE_STATE" >/dev/null || exit 1
grep -q 'task=fail action=probe_failed reason=probe_failed:0:expected=0:actual=7' "$TMPROOT/live.log" || exit 1

bash "$AUTOPROBE_SH" --limit 10 --max-seconds 30 --backoff-seconds 60 >"$TMPROOT/backoff.log"
grep -q 'task=fail action=skip reason=backoff' "$TMPROOT/backoff.log" || exit 1

diff -u "$TMPROOT/pass.before.json" "$FATQ_ROOT/done/pass.json" >"$TMPROOT/pass.diff" || true
echo "[closeout-autoprobe-test] PASS"
echo "dry_run_hashes_unchanged=yes"
echo "empty_probe_unchanged=yes"
echo "red_probe_unchanged=yes"
echo "invalid_commit_unchanged=yes"
echo "closed_task_unchanged=yes"
echo "xdg_runtime_env_unset_entry_passed=yes"
echo "limit_remainder_classified=yes"
echo "--- dry-run summary ---"
grep 'summary=' "$TMPROOT/dry.log"
echo "--- normal summary ---"
grep 'summary=' "$TMPROOT/live.log"
echo "--- successful auto-probe closeout ---"
jq '.closeout' "$FATQ_ROOT/done/pass.json"
echo "--- successful task before/after diff ---"
sed -n '1,260p' "$TMPROOT/pass.diff"

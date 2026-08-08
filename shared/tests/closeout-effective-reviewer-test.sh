#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_SH="${CLI_SH:-$SCRIPT_DIR/../bin/fatq-cli.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export FATQ_ROOT="$TMPROOT/tasks"
export FATQ_TEAM_CONFIG="$TMPROOT/team-config.json"
export FATQ_RELAY_DIR="$TMPROOT/relay"
export FATQ_DISPATCH_AFFINITY="$TMPROOT/dispatch-affinity.json"
export FATQ_ENFORCEMENT_KILL_SWITCH="$FATQ_ROOT/.fatq-enforcement-off"
export FATQ_CREATE_GATE_DISABLED=1
mkdir -p "$FATQ_ROOT"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} "$FATQ_RELAY_DIR"

printf '%s\n' '{"assistants":[{"state_dir":"anya"}],"shared_pools":{"builder":[{"state_dir":"anna"}],"reviewer":[{"state_dir":"bella"},{"state_dir":"yitang"},{"state_dir":"cece"}]},"external_identities":[]}' > "$FATQ_TEAM_CONFIG"
printf '%s\n' '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name"
    fail=$((fail + 1))
  fi
}

make_task() {
  local id="$1" assigned="$2" reviewer="$3" effective="$4" history_json="$5"
  jq -n --arg id "$id" --arg assigned "$assigned" --arg reviewer "$reviewer" \
    --arg effective "$effective" --argjson history "$history_json" '
      {task_id:$id,slug:$id,status:"done",assigned:$assigned,reviewer:$reviewer,
       closeout:{state:"pending"},history:$history}
      | if $effective != "" then .effective_reviewer=$effective else . end
    ' > "$FATQ_ROOT/done/$id.json"
}

closeout_live() {
  local id="$1" verified_by="$2" output="$3"
  bash "$CLI_SH" closeout "$id" --as anya \
    --live-check "{\"verified_by\":\"$verified_by\",\"method\":\"reviewer-live\",\"evidence\":\"fixture\"}" \
    --state pending >"$output" 2>&1
}

closeout_closed() {
  local id="$1" verified_by="$2" output="$3"
  bash "$CLI_SH" closeout "$id" --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"isolated closeout fixture"}' \
    --live-check "{\"verified_by\":\"$verified_by\",\"method\":\"reviewer-live\",\"evidence\":\"fixture\"}" \
    --state closed >"$output" 2>&1
}

seed_live_check() {
  local id="$1" verified_by="$2" tmp
  tmp="$(mktemp "$FATQ_ROOT/done/.${id}.XXXXXX")"
  jq --arg verified_by "$verified_by" '
    .closeout.live_check = {
      verified_by:$verified_by,
      method:"reviewer-live",
      evidence:"previously accepted fixture",
      ts:"2026-08-08T03:00:00+08:00"
    }
  ' "$FATQ_ROOT/done/$id.json" > "$tmp"
  mv "$tmp" "$FATQ_ROOT/done/$id.json"
}

close_preseeded() {
  local id="$1" output="$2"
  bash "$CLI_SH" closeout "$id" --as anya \
    --deploy-evidence '{"commits":[],"services_restarted":[],"not_applicable":true,"reason":"isolated closeout fixture"}' \
    --state closed >"$output" 2>&1
}

# Real 1102/16a6 field shape: the original reviewer differs from both the
# infra-gate effective reviewer and the final verdict author.
make_task real-shape anna yitang bella '[
  {"ts":"2026-08-08T01:00:00+08:00","by":"yitang","action":"verdict_reject"},
  {"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}
]'
real_out="$TMPROOT/real.out"
closeout_live real-shape bella "$real_out"
real_rc=$?
check "effective reviewer can attest real task shape" test "$real_rc" -eq 0
check "real task stores bella reviewer-live" jq -e '.closeout.live_check.verified_by == "bella"' "$FATQ_ROOT/done/real-shape.json"

make_task third-party anna yitang bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
third_out="$TMPROOT/third.out"
closeout_live third-party cece "$third_out"
third_rc=$?
check "unrelated third party remains rejected" test "$third_rc" -eq 3
check "rejection names actual reviewer and verdict source" grep -q '本單實際審查者是 bella（來源：verdict 歷史），你是 cece' "$third_out"
check "third-party rejection writes no live evidence" jq -e '.closeout | has("live_check") | not' "$FATQ_ROOT/done/third-party.json"

# Defense in depth: even a malformed/tampered task containing a builder-authored
# verdict entry must not turn assigned into a valid reviewer-live identity.
make_task builder-self anna yitang anna '[{"ts":"2026-08-08T02:00:00+08:00","by":"anna","action":"verdict_approve"}]'
self_out="$TMPROOT/self.out"
closeout_live builder-self anna "$self_out"
self_rc=$?
check "assigned builder cannot self-attest" test "$self_rc" -eq 3
check "builder rejection is explicit" grep -q 'verified_by(anna) 是本單 assigned builder' "$self_out"

make_task same-reviewer anna bella bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
same_out="$TMPROOT/same.out"
closeout_live same-reviewer bella "$same_out"
same_rc=$?
check "same reviewer and effective reviewer remains accepted" test "$same_rc" -eq 0

make_task effective-fallback anna yitang bella '[]'
effective_out="$TMPROOT/effective.out"
closeout_live effective-fallback bella "$effective_out"
effective_rc=$?
check "missing verdict falls back to effective_reviewer" test "$effective_rc" -eq 0

make_task reviewer-fallback anna bella '' '[]'
reviewer_out="$TMPROOT/reviewer.out"
closeout_live reviewer-fallback bella "$reviewer_out"
reviewer_rc=$?
check "missing verdict and effective reviewer falls back to reviewer" test "$reviewer_rc" -eq 0

make_task verdict-precedence anna yitang yitang '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
precedence_out="$TMPROOT/precedence.out"
closeout_live verdict-precedence yitang "$precedence_out"
precedence_rc=$?
check "verdict history outranks effective_reviewer and reviewer" test "$precedence_rc" -eq 3
check "precedence error identifies verdict author" grep -q '本單實際審查者是 bella（來源：verdict 歷史），你是 yitang' "$precedence_out"

# A verdict action with no author is authoritative-but-malformed. It must not
# fall through to effective_reviewer or the legacy reviewer field.
make_task verdict-missing-by anna yitang bella '[{"ts":"2026-08-08T02:00:00+08:00","action":"verdict_approve"}]'
missing_by_out="$TMPROOT/missing-by.out"
closeout_live verdict-missing-by bella "$missing_by_out"
missing_by_rc=$?
check "verdict entry missing by fails closed" test "$missing_by_rc" -eq 3
check "missing verdict author reports empty authoritative reviewer" grep -q '本單實際審查者是 <empty>（來源：verdict 歷史），你是 bella' "$missing_by_out"
check "missing verdict author writes no live evidence" jq -e '.closeout | has("live_check") | not' "$FATQ_ROOT/done/verdict-missing-by.json"

# True end-to-end closed-state regression: this is the 16a6 field shape that
# d65a accepted at write time but the old final assertion compared to yitang.
make_task closed-real-shape anna yitang bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
closed_real_out="$TMPROOT/closed-real.out"
closeout_closed closed-real-shape bella "$closed_real_out"
closed_real_rc=$?
check "resolved reviewer can complete state=closed" test "$closed_real_rc" -eq 0
check "resolved reviewer fixture is really closed" jq -e '.closeout.state == "closed" and .closeout.live_check.verified_by == "bella"' "$FATQ_ROOT/done/closed-real-shape.json"

# Positive control: when the static reviewer was already right, closing remains
# unchanged.
make_task closed-same-reviewer anna bella bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
closed_same_out="$TMPROOT/closed-same.out"
closeout_closed closed-same-reviewer bella "$closed_same_out"
closed_same_rc=$?
check "matching reviewer field still completes state=closed" test "$closed_same_rc" -eq 0
check "matching reviewer fixture is closed" jq -e '.closeout.state == "closed"' "$FATQ_ROOT/done/closed-same-reviewer.json"

# Exercise the final assertion independently of the write-time gate by seeding
# previously accepted live evidence. Identity errors must not masquerade as
# missing-evidence errors.
make_task closed-third-party anna yitang bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
seed_live_check closed-third-party cece
closed_third_out="$TMPROOT/closed-third.out"
close_preseeded closed-third-party "$closed_third_out"
closed_third_rc=$?
check "preseeded unrelated third party cannot close" test "$closed_third_rc" -eq 4
check "closed gate names third-party identity mismatch" grep -q '本單實際審查者是 bella（來源：verdict 歷史），live_check.verified_by 是 cece' "$closed_third_out"
check "third-party identity error is not evidence error" sh -c '! grep -q "兩證據齊備" "$1"' _ "$closed_third_out"

make_task closed-builder-self anna yitang bella '[{"ts":"2026-08-08T02:00:00+08:00","by":"bella","action":"verdict_approve"}]'
seed_live_check closed-builder-self anna
closed_self_out="$TMPROOT/closed-self.out"
close_preseeded closed-builder-self "$closed_self_out"
closed_self_rc=$?
check "preseeded assigned builder cannot close" test "$closed_self_rc" -eq 4
check "closed gate explicitly rejects assigned builder" grep -q 'live_check.verified_by(anna) 是本單 assigned builder' "$closed_self_out"
check "builder identity error is not evidence error" sh -c '! grep -q "兩證據齊備" "$1"' _ "$closed_self_out"

sed 's/^/[RAW closed-real] /' "$closed_real_out"
sed 's/^/[RAW closed-same-reviewer] /' "$closed_same_out"
sed 's/^/[RAW closed-third-party] /' "$closed_third_out"
sed 's/^/[RAW closed-builder-self] /' "$closed_self_out"

echo "[closeout-effective-reviewer-test] pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]

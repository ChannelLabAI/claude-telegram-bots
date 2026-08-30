#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATROL="$REPO_ROOT/shared/loops/roster-patrol/roster-patrol.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fixture="$tmpdir/root"
mkdir -p "$fixture/bots/diana" "$fixture/bots/truly-unregistered" \
  "$fixture/shared" "$fixture/pod-system/pods" "$fixture/reports" "$fixture/relay"
touch "$fixture/bots/diana/CLAUDE.md" "$fixture/bots/truly-unregistered/CLAUDE.md"

jq -n '{assistants:[{name:"Diana",state_dir:"keeper",bot_username:"DianaAI_v2_bot"}],shared_pools:{},external_identities:[]}' \
  > "$fixture/shared/team-config.json"
jq -n '{podName:"fixture-pod",bots:[{name:"Pod Only",username:"pod_only_bot",dir:"/fixture/pod-only"}]}' \
  > "$fixture/pod-system/pods/fixture.json"
jq -n '{aliases:[]}' > "$tmpdir/empty-aliases.json"
jq -n '{aliases:[{canonical:"keeper",alias:"diana",reason:"Diana uses keeper as her runtime state_dir",added_at:"2026-08-30"}]}' \
  > "$tmpdir/diana-aliases.json"

run_patrol() {
  local script="$1" aliases="$2" date_key="$3"
  ROSTER_PATROL_ROOT="$fixture" \
  ROSTER_PATROL_TEAM_CONFIG="$fixture/shared/team-config.json" \
  ROSTER_PATROL_ALIAS_FILE="$aliases" \
  ROSTER_PATROL_REPORT_ROOT="$fixture/reports" \
  ROSTER_PATROL_RELAY_DIR="$fixture/relay" \
  ROSTER_PATROL_DATE="$date_key" \
  ROSTER_PATROL_NOW="2026-08-30T09:30:00+08:00" \
  ROSTER_PATROL_DRY_RUN=1 \
    bash "$script" >/dev/null
  printf '%s\n' "$fixture/reports/$date_key.json"
}

assert_issue() {
  local report="$1" category="$2" key="$3" known="$4"
  jq -e --arg category "$category" --arg key "$key" --argjson known "$known" \
    '.issues | any(.category == $category and .key == $key and .known == $known)' \
    "$report" >/dev/null
}

print_case() {
  local case_name="$1" report="$2"
  jq -c --arg case_name "$case_name" '{case:$case_name,issue_counts,missing_registration:[.issues[] | select(.category=="missing_registration") | {key,known,known_reason}]}' \
    "$report"
}

# AC2 calibration must run before any suppression assertion.
calibration_report="$(run_patrol "$PATROL" "$tmpdir/empty-aliases.json" calibration)"
assert_issue "$calibration_report" missing_registration truly-unregistered false
print_case "AC2_TRUE_POSITIVE_FIRST" "$calibration_report"

# AC3(a): data without the code fix is a silent no-op.
mutant="$tmpdir/roster-patrol-old-missing-registration.sh"
awk '
  /\(\(\[\$r\[\]\?\.state_dir\] \| map\(alias_reason\(\.; \$dir.dir\)\)/ { replacing=1; print "        known($dir.dir; $dir.dir))),"; next }
  replacing && /else \{known: false\} end\)\)\),/ { replacing=0; next }
  !replacing { print }
' "$PATROL" > "$mutant"
chmod +x "$mutant"
data_only_report="$(run_patrol "$mutant" "$tmpdir/diana-aliases.json" data-only)"
assert_issue "$data_only_report" missing_registration diana false
print_case "AC3_DATA_ONLY_STILL_ALERTS" "$data_only_report"

set +e
ROSTER_PATROL_ROOT="$fixture" \
ROSTER_PATROL_TEAM_CONFIG="$fixture/shared/team-config.json" \
ROSTER_PATROL_ALIAS_FILE="$tmpdir/diana-aliases.json" \
ROSTER_PATROL_SCRIPT="$mutant" \
  bash "$REPO_ROOT/shared/loops/roster-patrol/roster-patrol-alias-audit.sh" \
  > "$tmpdir/mutant-audit.out" 2>&1
mutant_audit_rc=$?
set -e
if [[ "$mutant_audit_rc" -eq 0 ]] || ! grep -q '"key":"diana"' "$tmpdir/mutant-audit.out"; then
  echo "audit mutant calibration failed" >&2
  sed -n '1,120p' "$tmpdir/mutant-audit.out" >&2
  exit 1
fi
echo '{"case":"AUDIT_REJECTS_ALIAS_LEAK","exit":1,"key":"diana"}'

set +e
ROSTER_PATROL_ROOT="$fixture" \
ROSTER_PATROL_TEAM_CONFIG="$fixture/shared/team-config.json" \
ROSTER_PATROL_ALIAS_FILE="$tmpdir/empty-aliases.json" \
ROSTER_PATROL_SCRIPT="$PATROL" \
  bash "$REPO_ROOT/shared/loops/roster-patrol/roster-patrol-alias-audit.sh" \
  > "$tmpdir/zero-audit.out" 2>&1
zero_audit_rc=$?
set -e
if [[ "$zero_audit_rc" -eq 0 ]] ||
   ! grep -q 'checked=0' "$tmpdir/zero-audit.out" ||
   ! grep -q 'no missing_registration entries to audit' "$tmpdir/zero-audit.out"; then
  echo "audit empty-observation calibration failed" >&2
  sed -n '1,120p' "$tmpdir/zero-audit.out" >&2
  exit 1
fi
echo '{"case":"AUDIT_REJECTS_ZERO_CHECKED","exit":1,"checked":0}'

# AC3(b): code without alias data must not suppress the issue.
code_only_report="$(run_patrol "$PATROL" "$tmpdir/empty-aliases.json" code-only)"
assert_issue "$code_only_report" missing_registration diana false
print_case "AC3_CODE_ONLY_STILL_ALERTS" "$code_only_report"

# Fixed conjunction: Diana is known, while the real unregistered bot still alerts.
fixed_report="$(run_patrol "$PATROL" "$tmpdir/diana-aliases.json" fixed)"
assert_issue "$fixed_report" missing_registration diana true
assert_issue "$fixed_report" missing_registration truly-unregistered false
jq -e '.issues | any(.category=="missing_registration" and .key=="diana" and .known_reason=="Diana uses keeper as her runtime state_dir")' \
  "$fixed_report" >/dev/null
print_case "AC1_FIXED_AND_AC2_RECHECK" "$fixed_report"

jq '[.issues[] | select(.category=="missing_directory" or .category=="pod_unregistered")]' \
  "$data_only_report" > "$tmpdir/old-other-branches.json"
jq '[.issues[] | select(.category=="missing_directory" or .category=="pod_unregistered")]' \
  "$fixed_report" > "$tmpdir/fixed-other-branches.json"
diff -u "$tmpdir/old-other-branches.json" "$tmpdir/fixed-other-branches.json"
echo '{"case":"AC5_OTHER_BRANCHES_UNCHANGED","missing_directory":1,"pod_unregistered":1}'

ROSTER_PATROL_ROOT="$fixture" \
ROSTER_PATROL_TEAM_CONFIG="$fixture/shared/team-config.json" \
ROSTER_PATROL_ALIAS_FILE="$tmpdir/diana-aliases.json" \
ROSTER_PATROL_SCRIPT="$PATROL" \
  bash "$REPO_ROOT/shared/loops/roster-patrol/roster-patrol-alias-audit.sh" >/dev/null
echo '{"case":"AUDIT_ACCEPTS_FIXED_REPORT","exit":0}'

echo "roster-patrol alias tests: PASS"

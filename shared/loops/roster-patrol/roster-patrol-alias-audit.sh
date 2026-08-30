#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROSTER_PATROL_ROOT:-/home/oldrabbit/.claude-bots}"
PATROL="${ROSTER_PATROL_SCRIPT:-$SCRIPT_DIR/roster-patrol.sh}"
ALIAS_FILE="${ROSTER_PATROL_ALIAS_FILE:-$SCRIPT_DIR/known-aliases.json}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
date_key="alias-audit"

ROSTER_PATROL_ROOT="$ROOT" \
ROSTER_PATROL_ALIAS_FILE="$ALIAS_FILE" \
ROSTER_PATROL_REPORT_ROOT="$tmpdir/reports" \
ROSTER_PATROL_RELAY_DIR="$tmpdir/relay" \
ROSTER_PATROL_DATE="$date_key" \
ROSTER_PATROL_DRY_RUN=1 \
  bash "$PATROL"

report="$tmpdir/reports/$date_key.json"
candidates="$tmpdir/alias-candidates.json"
leaks="$tmpdir/alias-leaks.json"
jq -n \
  --slurpfile report "$report" \
  --slurpfile aliases "$ALIAS_FILE" '
    [
      ($report[0].issues // [])[] as $issue
      | select($issue.category == "missing_registration")
      | ($aliases[0].aliases // [])[] as $alias
      | select($issue.key == $alias.canonical or $issue.key == $alias.alias)
      | {
          category: $issue.category,
          key: $issue.key,
          known: $issue.known,
          summary: $issue.summary,
          canonical: $alias.canonical,
          alias: $alias.alias
        }
    ]
  ' > "$candidates"

checked="$(jq 'length' "$candidates")"
echo "[roster-patrol-alias-audit] checked=$checked"
if [[ "$checked" -eq 0 ]]; then
  echo "[roster-patrol-alias-audit] FAIL: no missing_registration entries to audit" >&2
  exit 1
fi

jq '[.[] | select(.known != true)]' "$candidates" > "$leaks"

if jq -e 'length > 0' "$leaks" >/dev/null; then
  echo "[roster-patrol-alias-audit] alerting items still match registered aliases:" >&2
  jq -c '.[]' "$leaks" >&2
  exit 1
fi

echo "[roster-patrol-alias-audit] PASS: no alerting report key matches a registered alias"

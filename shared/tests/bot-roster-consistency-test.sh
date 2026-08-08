#!/usr/bin/env bash
set -euo pipefail

ROOT="${BOT_ROSTER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CHECK="$ROOT/shared/tests/bot-roster-consistency.sh"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

run_check() {
  BOT_ROSTER_ROOT="$ROOT" \
  BOT_ROSTER_BOTS_DIR="${BOT_ROSTER_BOTS_DIR:-$ROOT/bots}" \
  BOT_ROSTER_ROUTING_FILE="$ROOT/shared/config/bot-routing.yml" \
  BOT_ROSTER_IDENTITY_FILE="$1" \
  BOT_ROSTER_DISPATCH_FILE="$ROOT/shared/bin/fatq-dispatch.sh" \
  bash "$CHECK"
}

# Green proof: Sara and Spark are found despite having only AGENTS.md.
run_check "$ROOT/shared/config/bot-identity-map.yml" > "$BASE/green.out"
grep -Fx 'Codex AGENTS-only coverage: sara, spark' "$BASE/green.out"

# Red proof 1: deleting Sara's identity anchor must expose the orphan directory.
python3 - "$ROOT/shared/config/bot-identity-map.yml" "$BASE/no-sara.yml" <<'PYTHON'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
data["bots"] = [row for row in data["bots"] if row["directory"] != "sara"]
yaml.safe_dump(data, open(sys.argv[2], "w", encoding="utf-8"), allow_unicode=True, sort_keys=False)
PYTHON
if run_check "$BASE/no-sara.yml" > "$BASE/no-sara.out" 2>&1; then
  echo "expected missing Sara anchor to fail" >&2
  exit 1
fi
grep -F 'orphan role-definition directory: sara' "$BASE/no-sara.out"

# Red proof 2: an anchor to a nonexistent routing id must fail as a dead pointer.
python3 - "$ROOT/shared/config/bot-identity-map.yml" "$BASE/dead-roster.yml" <<'PYTHON'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
next(row for row in data["bots"] if row["directory"] == "anna")["roster_id"] = "not-a-roster-id"
yaml.safe_dump(data, open(sys.argv[2], "w", encoding="utf-8"), allow_unicode=True, sort_keys=False)
PYTHON
if run_check "$BASE/dead-roster.yml" > "$BASE/dead-roster.out" 2>&1; then
  echo "expected dead roster_id to fail" >&2
  exit 1
fi
grep -F 'dead roster_id for anna: not-a-roster-id' "$BASE/dead-roster.out"

echo "PASS bot-roster-consistency test (green + two required red proofs)"

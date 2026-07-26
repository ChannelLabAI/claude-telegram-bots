#!/usr/bin/env bash
# Regression fixture for symlink-health detector alert noise.
# Runs only against an isolated temp BOTS_DIR/RELAY_DIR/STATE_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$TASK_ROOT/shared/loops/symlink-health/detector.sh"

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL $desc"
    FAIL=$((FAIL + 1))
  fi
}

json_get() {
  python3 - "$@" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    obj = json.load(f)
print(obj.get(key, ""))
PY
}

relay_count() {
  find "$RELAY_DIR" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '
}

latest_audit_value() {
  python3 - "$AUDIT_LOG" "$1" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = [line for line in f if line.strip()]
obj = json.loads(lines[-1])
cur = obj
for part in field.split("."):
    cur = cur[part]
print(cur)
PY
}

tmp="$(mktemp -d /tmp/symlink-health-noise-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

BASE_DIR="$tmp/repo"
BOTS_DIR="$BASE_DIR/bots"
SHARED_BLOCKS="$BASE_DIR/shared/blocks"
RELAY_DIR="$tmp/relay"
STATE_DIR="$tmp/state"
AUDIT_LOG="$tmp/audit.jsonl"
CONFIG_FILE="$tmp/config"

case "$BASE_DIR:$BOTS_DIR:$RELAY_DIR:$STATE_DIR" in
  /tmp/*:/tmp/*:/tmp/*:/tmp/*) ;;
  *) echo "fixture isolation canary failed"; exit 1 ;;
esac

mkdir -p "$SHARED_BLOCKS" "$BOTS_DIR/anna/blocks" "$RELAY_DIR" "$STATE_DIR"

# Keep the fixture independent of the production kill switch while preserving
# the detector's normal configuration values.
cat > "$CONFIG_FILE" <<'EOF'
loop_enabled=1
auto_fix_enabled=0
circuit_breaker_limit=3
topology_threshold_pct=25
chronic_fix_threshold=3
chronic_window_days=7
EOF

cat > "$SHARED_BLOCKS/block-section11.md" <<'EOF'
canonical section11
EOF
cat > "$SHARED_BLOCKS/block-task-queue.md" <<'EOF'
canonical task queue
EOF

# Keep enough live, healthy population for the topology threshold while the
# fixture exercises one and then two independent drift findings.
for bot in baseline-a baseline-b baseline-c baseline-d baseline-e baseline-f; do
  mkdir -p "$BOTS_DIR/$bot/blocks"
  ln -s "$SHARED_BLOCKS/block-section11.md" "$BOTS_DIR/$bot/blocks/block-section11.md"
done

run_detector() {
  SYMLINK_HEALTH_BASE_DIR="$BASE_DIR" \
  SYMLINK_HEALTH_BOTS_DIR="$BOTS_DIR" \
  SYMLINK_HEALTH_SHARED_BLOCKS="$SHARED_BLOCKS" \
  SYMLINK_HEALTH_RELAY_DIR="$RELAY_DIR" \
  SYMLINK_HEALTH_STATE_DIR="$STATE_DIR" \
  SYMLINK_HEALTH_AUDIT_LOG="$AUDIT_LOG" \
  SYMLINK_HEALTH_CONFIG_FILE="$CONFIG_FILE" \
  bash "$DETECTOR" >/tmp/symlink-health-noise.stdout 2>/tmp/symlink-health-noise.stderr
}

echo "T1 excluded work/.worktrees/bak/review scratch clone and nested copy drift does not alert"
mkdir -p "$BOTS_DIR/anna/work/w1/shared/blocks" "$BOTS_DIR/.worktrees/w2/bots/anna/blocks" "$BOTS_DIR/anna/bak-20260711/blocks" \
  "$BOTS_DIR/anna/review-tmp/r1/blocks" "$BOTS_DIR/anna/scratch/r2/blocks" \
  "$BOTS_DIR/anna/check-freshclone/r3/blocks" "$BOTS_DIR/anna/preflight-verify-clone/r4/blocks" \
  "$BOTS_DIR/anna/tmp/transient-nested-repo/blocks"
printf 'work copy drift\n' > "$BOTS_DIR/anna/work/w1/shared/blocks/block-section11.md"
printf 'worktree copy drift\n' > "$BOTS_DIR/.worktrees/w2/bots/anna/blocks/block-section11.md"
printf 'backup copy drift\n' > "$BOTS_DIR/anna/bak-20260711/blocks/block-section11.md"
printf 'review temp drift\n' > "$BOTS_DIR/anna/review-tmp/r1/blocks/block-section11.md"
printf 'scratch clone drift\n' > "$BOTS_DIR/anna/scratch/r2/blocks/block-section11.md"
printf 'fresh clone drift\n' > "$BOTS_DIR/anna/check-freshclone/r3/blocks/block-section11.md"
printf 'verify clone drift\n' > "$BOTS_DIR/anna/preflight-verify-clone/r4/blocks/block-section11.md"
ln -s missing-canonical "$BOTS_DIR/anna/tmp/transient-nested-repo/blocks/block-section11.md"
run_detector
check "excluded paths produce no relay" test "$(relay_count)" -eq 0
check "nested dangling block symlink produces zero broken" test "$(latest_audit_value summary.broken)" -eq 0
check "excluded paths produce zero drift_conflict" test "$(latest_audit_value summary.drift_conflict)" -eq 0

echo "T2 deployed bot named scratch still alerts and relay is routable"
mkdir -p "$BOTS_DIR/scratch/blocks"
printf 'real deployed drift v1\n' > "$BOTS_DIR/scratch/blocks/block-section11.md"
run_detector
first_relay="$(find "$RELAY_DIR" -maxdepth 1 -type f -name '*.json' | sort | head -1)"
check "real drift produces one relay" test "$(relay_count)" -eq 1
check "relay recipient routes to anya" test "$(json_get "$first_relay" recipient)" = "anya"
check "relay text mentions Anyachl bot" grep -q '@Anyachl_bot' "$first_relay"
check "legacy unroutable to field is absent" bash -c "! grep -q '\"to\"[[:space:]]*:' '$first_relay'"

echo "T3 same (file, md5) drift is deduped within the window"
run_detector
run_detector
check "same drift still has only one relay" test "$(relay_count)" -eq 1
check "audit records deduped action" grep -q '"action": "deduped"' "$AUDIT_LOG"

echo "T4 changed md5 re-alerts"
printf 'real deployed drift v2\n' > "$BOTS_DIR/anna/blocks/block-section11.md"
run_detector
check "changed md5 produces second relay" test "$(relay_count)" -eq 2

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

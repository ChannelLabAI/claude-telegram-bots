#!/usr/bin/env bash
# Read production task JSONs, but execute both scanners only against an isolated copy.
set -euo pipefail

for cmd in git jq find grep sort comm mktemp cp date; do
  command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_ROOT="${PATROL_AB_HOST_ROOT:-/home/oldrabbit/.claude-bots}"
BASE_COMMIT="${PATROL_AB_BASE_COMMIT:-a52651bb128b1ed17104df1c6cfd7411a75d4bda}"
OUT_DIR="${PATROL_AB_OUT_DIR:-$REPO_ROOT/evidence/49c0/current-stall-ab}"
NOW="${PATROL_AB_NOW_EPOCH:-$(date +%s)}"
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf -- "$FIXTURE"; }
trap cleanup EXIT

mkdir -p "$FIXTURE"/tasks/{pending,in_progress,review} "$FIXTURE"/{baseline-logs,baseline-relay,fixed-logs,fixed-relay,pod-system/pods,shared/config}
for state in pending in_progress review; do
  find "$HOST_ROOT/tasks/$state" -maxdepth 1 -type f -name '*.json' -exec cp -p {} "$FIXTURE/tasks/$state/" \;
done
cp "$HOST_ROOT/shared/config/patrol-scan.json" "$FIXTURE/shared/config/patrol-scan.json"
: > "$FIXTURE/ps.txt"
git -C "$REPO_ROOT" show "$BASE_COMMIT:shared/bin/patrol-scan.sh" > "$FIXTURE/patrol-baseline.sh"

run_scan() {
  local script="$1" log_dir="$2" relay_dir="$3" output="$4"
  PATROL_ROOT="$FIXTURE" PATROL_CONFIG="$FIXTURE/shared/config/patrol-scan.json" \
    PATROL_LOG_DIR="$log_dir" PATROL_RELAY_DIR="$relay_dir" \
    PATROL_INOTIFY_LOG="$FIXTURE/missing-inotify.log" PATROL_PODS_DIR="$FIXTURE/pod-system/pods" \
    PATROL_PS_FILE="$FIXTURE/ps.txt" PATROL_NOW_EPOCH="$NOW" \
    PATROL_BLOCKING_LIB="$REPO_ROOT/shared/lib/fatq-blocking.sh" bash "$script" > "$output"
}

mkdir -p "$OUT_DIR"
run_scan "$FIXTURE/patrol-baseline.sh" "$FIXTURE/baseline-logs" "$FIXTURE/baseline-relay" "$OUT_DIR/before.json"
run_scan "$REPO_ROOT/shared/bin/patrol-scan.sh" "$FIXTURE/fixed-logs" "$FIXTURE/fixed-relay" "$OUT_DIR/after.json"

extract_set() {
  jq -r '.failures[] | select(test("^task_(pending|in_progress|review):")) | capture("task_id=(?<id>[^ ]+)").id' "$1" | sort -u
}
extract_set "$OUT_DIR/before.json" > "$OUT_DIR/before-task-ids.txt"
extract_set "$OUT_DIR/after.json" > "$OUT_DIR/after-task-ids.txt"

printf 'AC4 fixed timestamp: %s\n' "$NOW"
printf 'before stale task count: %s\n' "$(grep -c . "$OUT_DIR/before-task-ids.txt" || true)"
printf 'after stale task count: %s\n' "$(grep -c . "$OUT_DIR/after-task-ids.txt" || true)"
printf 'before stale task IDs:\n'
sed 's/^/  /' "$OUT_DIR/before-task-ids.txt"
printf 'after stale task IDs:\n'
sed 's/^/  /' "$OUT_DIR/after-task-ids.txt"

if comm -23 "$OUT_DIR/before-task-ids.txt" "$OUT_DIR/after-task-ids.txt" | grep -q .; then
  echo 'AC4 FAIL: fixed scanner dropped stale tasks' >&2
  comm -23 "$OUT_DIR/before-task-ids.txt" "$OUT_DIR/after-task-ids.txt" >&2
  exit 1
fi
echo 'AC4 PASS: no previously stale task disappeared'

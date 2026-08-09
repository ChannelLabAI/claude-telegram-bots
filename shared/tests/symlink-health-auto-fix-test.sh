#!/usr/bin/env bash
# Isolated red/green tests for the symlink-health auto-fix configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$ROOT/shared/loops/symlink-health/detector.sh"
tmp="$(mktemp -d /tmp/symlink-health-auto-fix-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

base="$tmp/repo"
bots="$base/bots"
canonical="$base/shared/blocks"
mkdir -p "$bots/anna/blocks" "$canonical" "$tmp/relay" "$tmp/state"
printf '%s\n' '---' 'priority: medium' '---' 'canonical content' > "$canonical/block-section11.md"

# Six healthy entries keep one anomaly below the detector's topology breaker.
for bot in a b c d e f; do
  mkdir -p "$bots/$bot/blocks"
  ln -s "$canonical/block-section11.md" "$bots/$bot/blocks/block-section11.md"
done
target="$bots/anna/blocks/block-section11.md"
ln -s /missing/block-section11.md "$target"

run() {
  SYMLINK_HEALTH_BASE_DIR="$base" SYMLINK_HEALTH_BOTS_DIR="$bots" \
  SYMLINK_HEALTH_SHARED_BLOCKS="$canonical" SYMLINK_HEALTH_RELAY_DIR="$tmp/relay" \
  SYMLINK_HEALTH_STATE_DIR="$tmp/state" SYMLINK_HEALTH_AUDIT_LOG="$tmp/audit.jsonl" \
  SYMLINK_HEALTH_GENERATE_MANIFEST="$ROOT/shared/lib/generate-manifest.py" \
  SYMLINK_HEALTH_CONFIG_FILE="$1" bash "$DETECTOR" 2>&1
}

printf '%s\n' 'loop_enabled=1' 'auto_fix_enabled=0' > "$tmp/dry-run.conf"
dry_output="$(run "$tmp/dry-run.conf")"
printf '%s\n' "$dry_output"
test "$(readlink "$target")" = /missing/block-section11.md
printf '%s\n' "$dry_output" | grep -q 'status=dry_run.*broken=1.*mode=dry_run'

printf '%s\n' 'loop_enabled=1' 'auto_fix_enabled=1' > "$tmp/auto-fix.conf"
fix_output="$(run "$tmp/auto-fix.conf")"
printf '%s\n' "$fix_output"
test -L "$target"
test "$(realpath "$target")" = "$(realpath "$canonical/block-section11.md")"
printf '%s\n' "$fix_output" | grep -q 'status=fixed.*broken=1.*mode=auto_fix'

# A regular file with different content is a conflict and must stay untouched.
conflict="$bots/anna/blocks/block-task-queue.md"
printf '%s\n' 'canonical queue' > "$canonical/block-task-queue.md"
printf '%s\n' 'local conflicting queue' > "$conflict"
conflict_output="$(run "$tmp/auto-fix.conf")"
printf '%s\n' "$conflict_output"
test ! -L "$conflict"
test "$(cat "$conflict")" = 'local conflicting queue'
printf '%s\n' "$conflict_output" | grep -q 'drift_conflict=1'

printf '%s\n' 'PASS dry-run leaves broken link; auto-fix repairs it; conflict remains untouched'

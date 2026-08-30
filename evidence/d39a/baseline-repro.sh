#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

ROOT="$FIXTURE/home/.claude-bots"
BOT_DIR="$ROOT/bots/testbot"
BLOCKS="$BOT_DIR/blocks"
mkdir -p "$BLOCKS" "$ROOT/shared/lib"
BASELINE_REF="${L25_BASELINE_REF:-HEAD^}"
git -C "$REPO_ROOT" show "$BASELINE_REF:shared/hooks/l25-trigger-loader.sh" > "$FIXTURE/baseline-hook.sh"
chmod +x "$FIXTURE/baseline-hook.sh"
cp "$REPO_ROOT/shared/lib/generate-manifest.py" "$ROOT/shared/lib/generate-manifest.py"

cat > "$BLOCKS/block-high.md" <<'EOF'
---
triggers: ["always high"]
priority: high
size_tokens: 10
---
# High block
BASELINE_DUPLICATE_CONTEXT
EOF

payload='{"hook_event_name":"SessionStart","session_id":"same-session","cwd":"'"$BOT_DIR"'"}'
first=$(HOME="$FIXTURE/home" "$FIXTURE/baseline-hook.sh" <<<"$payload")
second=$(HOME="$FIXTURE/home" "$FIXTURE/baseline-hook.sh" <<<"$payload")

grep -Fq 'BASELINE_DUPLICATE_CONTEXT' <<<"$first"
grep -Fq 'BASELINE_DUPLICATE_CONTEXT' <<<"$second"
printf 'BASELINE_FIRST=%s\n' "$first"
printf 'BASELINE_SECOND_SAME_SESSION=%s\n' "$second"
printf 'PASS: baseline reproduces duplicate injection for repeated SessionStart with one session_id\n'

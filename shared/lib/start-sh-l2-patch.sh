#!/usr/bin/env bash
# start-sh-l2-patch.sh
# ─────────────────────────────────────────────────────────────────────────────
# Applies the L2 on-demand block loading step to bots/anya/start.sh.
#
# USAGE (run as the shell user, NOT as a bot):
#   bash ~/.claude-bots/shared/lib/start-sh-l2-patch.sh
#
# What it does: inserts an L2 block-loading section into anya/start.sh
# immediately after the "Auto-patch plugin on startup" block.
#
# On-demand design:
#   - Reads L2_HINT env var (or first arg to start.sh) to decide which blocks
#     to load. If L2_HINT is empty → 0 blocks loaded (correct default).
#   - Calls log_session() after every match attempt to track usage in
#     ~/.claude-bots/bots/anya/l2_stats.json.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

START_SH="$HOME/.claude-bots/bots/anya/start.sh"

# Guard: don't apply twice
if grep -q 'L2 on-demand' "$START_SH" 2>/dev/null; then
  echo "Patch already applied (found 'L2 on-demand' in $START_SH). Nothing to do."
  exit 0
fi

# Anchor line to insert after
ANCHOR='"$HOME/.claude-bots/patch-server.sh" 2>/dev/null || true'

# Verify anchor exists
if ! grep -qF "$ANCHOR" "$START_SH"; then
  echo "ERROR: anchor line not found in $START_SH" >&2
  exit 1
fi

# Build the patch block as a heredoc written to a temp file, then python-insert
PATCH_CONTENT=$(cat <<'PATCH'

# ── L2 on-demand block loading ─────────────────────────────────────────────
# Loads only the blocks whose trigger keywords match L2_HINT.
# L2_HINT comes from the env var or the first argument passed to start.sh.
# If L2_HINT is empty, no blocks are loaded (0 tokens overhead).
# log_session() writes a session entry to l2_stats.json every run.
_L2_BLOCKS_DIR="$HOME/.claude-bots/bots/anya/blocks"
_L2_LIB="$HOME/.claude-bots/shared/lib"
_L2_HINT="${L2_HINT:-${1:-}}"

_L2_MATCHED=$(python3 - <<PYEOF 2>/dev/null
import sys
sys.path.insert(0, '$_L2_LIB')
from l2_loader import L2Loader, log_session
loader = L2Loader('$_L2_BLOCKS_DIR')
hint = '$_L2_HINT'
matched = loader.match(hint)
log_session(hint, matched)
for p in matched:
    print(p)
PYEOF
) || true

if [[ -n "$_L2_MATCHED" ]]; then
    echo "=== L2 on-demand blocks (hint: ${_L2_HINT:-<empty>}) ==="
    while IFS= read -r _l2_block; do
        [[ -f "$_l2_block" ]] || continue
        echo "--- $(basename "$_l2_block") ---"
        cat "$_l2_block"
        echo
    done <<< "$_L2_MATCHED"
    echo "=== end L2 blocks ==="
else
    echo "[$(date -u '+%H:%M:%S')] L2: no blocks matched for hint='${_L2_HINT:-<empty>}'"
fi

unset _L2_BLOCKS_DIR _L2_LIB _L2_HINT _L2_MATCHED _l2_block
# ───────────────────────────────────────────────────────────────────────────
PATCH
)

# Use python3 for reliable multi-line insertion
python3 - "$START_SH" "$PATCH_CONTENT" <<'PYEOF'
import sys, os
from pathlib import Path

target = Path(sys.argv[1])
patch_text = sys.argv[2]

content = target.read_text(encoding='utf-8')

anchor = '"$HOME/.claude-bots/patch-server.sh" 2>/dev/null || true'

if anchor not in content:
    print(f"ERROR: anchor not found in {target}", file=sys.stderr)
    sys.exit(1)

new_content = content.replace(anchor, anchor + patch_text, 1)

tmp = str(target) + '.tmp'
Path(tmp).write_text(new_content, encoding='utf-8')
os.replace(tmp, str(target))
print(f"Patch applied successfully to {target}")
PYEOF

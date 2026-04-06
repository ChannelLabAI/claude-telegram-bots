#!/usr/bin/env bash
# Archive old mistakes entries when file exceeds threshold
# Keeps header + last 10 entries, moves rest to mistakes.archive.md

MISTAKES="$HOME/.claude-bots/shared/mistakes.md"
ARCHIVE="$HOME/.claude-bots/shared/mistakes.archive.md"
MAX_ENTRIES=20

if [[ ! -f "$MISTAKES" ]]; then exit 0; fi

# Count entries (lines starting with "- **")
ENTRY_COUNT=$(grep -c '^- \*\*' "$MISTAKES" 2>/dev/null || echo 0)

if [[ $ENTRY_COUNT -le $MAX_ENTRIES ]]; then
  exit 0
fi

echo "[archive] mistakes.md has $ENTRY_COUNT entries (max $MAX_ENTRIES), archiving..."

# Append current content to archive (minus header)
echo "" >> "$ARCHIVE"
echo "## Archived $(date -u '+%Y-%m-%d')" >> "$ARCHIVE"
# Keep only entries beyond the last MAX_ENTRIES
python3 -c "
import re
with open('$MISTAKES') as f:
    content = f.read()
entries = re.split(r'(?=^- \*\*)', content, flags=re.MULTILINE)
header = entries[0]
items = entries[1:]
archive_items = items[:-$MAX_ENTRIES]
keep_items = items[-$MAX_ENTRIES:]
# Write archived entries
with open('$ARCHIVE', 'a') as f:
    for item in archive_items:
        f.write(item)
# Rewrite mistakes with only recent entries
with open('$MISTAKES', 'w') as f:
    f.write(header)
    for item in keep_items:
        f.write(item)
"
echo "[archive] Done. Kept last $MAX_ENTRIES entries."

#!/usr/bin/env bash
# Hook: Pearl lint guard for Ocean/Pearl/ writes.
# Blocks writes > 300 words or missing frontmatter; warns on < 2 wikilinks.
# PreToolUse on Edit|Write|MultiEdit.
set -uo pipefail
exec python3 "$(dirname "$0")/pearl-lint.py"

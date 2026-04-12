#!/usr/bin/env bash
# Hook: Require ≥1 [[wikilink]] in Ocean/ markdown and tasks/ JSON files.
# PreToolUse on Edit|Write|MultiEdit. Source: ADR v0.4 §10 (張凌赫提案).
#
# Thin wrapper: real logic lives in wikilink_required.py so the hook can read
# the tool_input JSON payload from stdin without heredoc stealing it.
set -uo pipefail
exec python3 "$(dirname "$0")/wikilink_required.py"

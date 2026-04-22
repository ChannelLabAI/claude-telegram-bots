#!/usr/bin/env bash
# PostToolUse / UserPromptSubmit hook: inject undelivered Cove messages into session.
# Reads *-cove-msg.json written by pushSessionNotification() in inbox-write.ts.
# params.content is a pre-built XML <channel> tag — echo verbatim, mark .delivered.
# Fast-exits (<10ms) when inbox is empty or dir doesn't exist.
set -uo pipefail

BOT_NAME="${COVE_BOT_NAME:-$(basename "${TELEGRAM_STATE_DIR:-}")}"
[[ -z "$BOT_NAME" ]] && exit 0

COVE_MSG_DIR="${COVE_STATE_INBOX_DIR:-$HOME/.claude-bots/state/$BOT_NAME/inbox/messages}"
[[ ! -d "$COVE_MSG_DIR" ]] && exit 0

shopt -s nullglob
files=("$COVE_MSG_DIR"/*-cove-msg.json)
shopt -u nullglob
[[ ${#files[@]} -eq 0 ]] && exit 0

for f in "${files[@]}"; do
  content=$(jq -r '.params.content // empty' "$f" 2>/dev/null) || continue
  [[ -z "$content" ]] && continue
  echo "$content"
  mv "$f" "${f}.delivered" 2>/dev/null || true
done

exit 0

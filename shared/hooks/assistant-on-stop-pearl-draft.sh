#!/usr/bin/env bash
# anya-on-stop-pearl-draft.sh — Pearl draft generation on Anya stop
# Called from anya-stop-orchestrator.sh

source ~/.claude-bots/shared/.env 2>/dev/null || true
python3 ~/.claude-bots/shared/scripts/pearl_draft_generator.py >> ~/.claude-bots/logs/pearl-draft.log 2>&1

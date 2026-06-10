#!/usr/bin/env bash
# run-with-secrets.sh — exec wrapper: load MemOcean secrets (from GCP) then run the command.
# Use in cron for scripts that need ANTHROPIC_API_KEY but run without it in cron env.
# Example: run-with-secrets.sh /path/venv/bin/python /path/dream_cycle.py --mode=live
source /home/oldrabbit/.claude-bots/shared/scripts/load-secrets.sh
exec "$@"

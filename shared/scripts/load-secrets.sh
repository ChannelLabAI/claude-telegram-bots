#!/usr/bin/env bash
# load-secrets.sh — sourceable: load MemOcean runtime secrets from GCP Secret Manager.
# WHY: cron jobs run without the interactive shell's env vars; scripts that read
# os.environ["ANTHROPIC_API_KEY"] (tg_daily_ingest, dream_cycle, stale_knowledge_check)
# silently failed for 38+ days because no env source existed (shared/.env was missing).
# Usage: `source load-secrets.sh`  OR via run-with-secrets.sh wrapper.
# The key is fetched from GCP at runtime — never stored in plaintext on disk.

export ANTHROPIC_API_KEY="$(gcloud secrets versions access latest --secret=anthropic-api-key --project=channellab-prod 2>/dev/null)"

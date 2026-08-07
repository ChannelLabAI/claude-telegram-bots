#!/usr/bin/env bash
set -euo pipefail
: "${TECH_RADAR_STUB_LOG:?TECH_RADAR_STUB_LOG is required}"
jq -cn --arg channel_id "${2:-}" --arg message "$1" \
  '{channel_id:$channel_id,message:$message}' >> "$TECH_RADAR_STUB_LOG"

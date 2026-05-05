#!/usr/bin/env bash
# rollback-webhook-all.sh — Delete TG webhook for all bots (revert to long-poll).
# Usage:
#   ./rollback-webhook-all.sh             # delete webhooks for all bots
#   ./rollback-webhook-all.sh --dry-run   # show what would be called
#   ./rollback-webhook-all.sh --bot anna  # single bot

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-channellab-prod}"
TARGET_BOT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bot) TARGET_BOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

log "Loading bot-token-map..."
BOT_TOKEN_MAP_JSON=$(gcloud secrets versions access latest \
  --secret="bot-token-map" --project="$GCP_PROJECT") || {
  log "ERROR: cannot read bot-token-map. Make sure GCP auth is configured."
  exit 1
}

ENTRIES=$(python3 - <<PYEOF
import json
tokens = json.loads("""$BOT_TOKEN_MAP_JSON""")
target = "$TARGET_BOT"
for token, bot_name in tokens.items():
    if target and bot_name != target:
        continue
    print(f"{token}|{bot_name}")
PYEOF
)

if [[ -z "$ENTRIES" ]]; then
  log "No bots matched (check --bot name or bot-token-map content)"
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY-RUN] Would call deleteWebhook for:"
  while IFS='|' read -r _ BOT_NAME; do
    log "  - $BOT_NAME"
  done <<< "$ENTRIES"
  exit 0
fi

SUCCESS=0
FAIL=0

while IFS='|' read -r BOT_TOKEN BOT_NAME; do
  [[ -z "$BOT_TOKEN" ]] && continue
  log "deleteWebhook for ${BOT_NAME}..."
  RESP=$(curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" \
    -d "drop_pending_updates=false")

  if python3 -c "import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get('ok') else 1)" <<< "$RESP"; then
    log "  OK: ${BOT_NAME} webhook deleted (long-poll ready)"
    SUCCESS=$((SUCCESS + 1))
  else
    log "  FAIL: ${BOT_NAME}: $RESP"
    FAIL=$((FAIL + 1))
  fi
done <<< "$ENTRIES"

log "Done. success=$SUCCESS fail=$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0

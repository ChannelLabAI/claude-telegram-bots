#!/usr/bin/env bash
# setup-webhook.sh — Register TG webhook for all bots (or a single bot).
# Reads bot-token-map + webhook-secrets-map from Secret Manager.
# Usage:
#   ./setup-webhook.sh                          # all bots
#   ./setup-webhook.sh --bot anna               # single bot
#   ./setup-webhook.sh --dry-run                # show what would be called
#   ./setup-webhook.sh --bot anna --dry-run

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-channellab-prod}"
WEBHOOK_BASE_URL="${WEBHOOK_BASE_URL:-}"   # e.g. https://webhook-gateway-xyz-de.a.run.app
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

if [[ -z "$WEBHOOK_BASE_URL" ]]; then
  log "Fetching Cloud Run URL for webhook-gateway..."
  WEBHOOK_BASE_URL=$(gcloud run services describe webhook-gateway \
    --region=asia-east1 --project="$GCP_PROJECT" \
    --format="value(status.url)" 2>/dev/null) || {
    log "ERROR: WEBHOOK_BASE_URL not set and could not detect Cloud Run URL."
    log "Export WEBHOOK_BASE_URL=https://<your-cloud-run-url> and retry."
    exit 1
  }
fi
WEBHOOK_BASE_URL="${WEBHOOK_BASE_URL%/}"   # strip trailing slash
log "Webhook base URL: $WEBHOOK_BASE_URL"

log "Loading bot-token-map..."
BOT_TOKEN_MAP_JSON=$(gcloud secrets versions access latest \
  --secret="bot-token-map" --project="$GCP_PROJECT")

log "Loading webhook-secrets-map..."
WEBHOOK_SECRETS_JSON=$(gcloud secrets versions access latest \
  --secret="webhook-secrets-map" --project="$GCP_PROJECT")

# Build list of (token, bot_name, webhook_secret)
ENTRIES=$(python3 - <<PYEOF
import json
tokens = json.loads("""$BOT_TOKEN_MAP_JSON""")
secrets = json.loads("""$WEBHOOK_SECRETS_JSON""")
target = "$TARGET_BOT"
for token, bot_name in tokens.items():
    if target and bot_name != target:
        continue
    secret = secrets.get(bot_name, "")
    if not secret:
        print(f"WARN no secret for {bot_name}", flush=True)
        continue
    print(f"{token}|{bot_name}|{secret}")
PYEOF
)

if [[ -z "$ENTRIES" ]]; then
  log "No bots to process (check --bot name or run setup-webhook-secrets.sh first)"
  exit 1
fi

SUCCESS=0
FAIL=0

while IFS='|' read -r BOT_TOKEN BOT_NAME WEBHOOK_SECRET; do
  [[ -z "$BOT_TOKEN" ]] && continue
  WEBHOOK_URL="${WEBHOOK_BASE_URL}/${BOT_TOKEN}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] setWebhook for ${BOT_NAME}: ${WEBHOOK_URL} (secret: ${WEBHOOK_SECRET:0:6}...)"
    continue
  fi

  log "setWebhook for ${BOT_NAME}..."
  RESP=$(curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    -d "url=${WEBHOOK_URL}" \
    -d "secret_token=${WEBHOOK_SECRET}" \
    -d "drop_pending_updates=false" \
    -d "allowed_updates=[\"message\",\"callback_query\",\"inline_query\"]")

  if python3 -c "import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get('ok') else 1)" <<< "$RESP"; then
    log "  OK: ${BOT_NAME} → ${WEBHOOK_URL}"
    SUCCESS=$((SUCCESS + 1))
  else
    log "  FAIL: ${BOT_NAME}: $RESP"
    FAIL=$((FAIL + 1))
  fi
done <<< "$ENTRIES"

if [[ "$DRY_RUN" != "true" ]]; then
  log "Done. success=$SUCCESS fail=$FAIL"
  [[ $FAIL -gt 0 ]] && exit 1 || exit 0
fi

#!/usr/bin/env bash
# setup-webhook-secrets.sh — Generate per-bot webhook secrets and store in SM.
# Creates / updates Secret Manager secret: webhook-secrets-map (JSON {bot_name: secret}).
# Idempotent: existing secrets are preserved, new bots get a freshly generated token.
# Usage: ./setup-webhook-secrets.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

GCP_PROJECT="${GCP_PROJECT:-channellab-prod}"
SECRET_NAME="webhook-secrets-map"

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

# Load bot names from bot-token-map
log "Fetching bot names from SM bot-token-map..."
BOT_TOKEN_MAP_JSON=$(gcloud secrets versions access latest \
  --secret="bot-token-map" --project="$GCP_PROJECT" 2>/dev/null) || {
  log "ERROR: cannot read bot-token-map from SM. Run setup-gcp-secrets.sh first."
  exit 1
}
BOT_NAMES=$(python3 -c "
import json, sys
m = json.loads(sys.stdin.read())
names = sorted(set(m.values()))
print('\n'.join(names))
" <<< "$BOT_TOKEN_MAP_JSON")

log "Bots: $(echo "$BOT_NAMES" | tr '\n' ' ')"

# Load existing secrets map (or start fresh)
EXISTING_JSON=$(gcloud secrets versions access latest \
  --secret="$SECRET_NAME" --project="$GCP_PROJECT" 2>/dev/null || echo "{}")

# Generate / preserve per-bot secrets
NEW_JSON=$(python3 - <<PYEOF
import json, secrets, sys
existing = json.loads("""$EXISTING_JSON""")
bots = """$BOT_NAMES""".strip().split("\n")
result = {}
for bot in bots:
    if not bot:
        continue
    if bot in existing:
        result[bot] = existing[bot]  # preserve
    else:
        result[bot] = secrets.token_urlsafe(32)
print(json.dumps(result, indent=2))
PYEOF
)

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY-RUN] Would write webhook-secrets-map:"
  echo "$NEW_JSON"
  exit 0
fi

# Write to SM
TMP=$(mktemp)
echo "$NEW_JSON" > "$TMP"

if gcloud secrets describe "$SECRET_NAME" --project="$GCP_PROJECT" &>/dev/null; then
  gcloud secrets versions add "$SECRET_NAME" \
    --data-file="$TMP" --project="$GCP_PROJECT"
  log "Updated SM $SECRET_NAME"
else
  gcloud secrets create "$SECRET_NAME" \
    --data-file="$TMP" \
    --replication-policy="automatic" \
    --project="$GCP_PROJECT"
  log "Created SM $SECRET_NAME"
fi
rm -f "$TMP"

log "Done. webhook-secrets-map stored in Secret Manager."

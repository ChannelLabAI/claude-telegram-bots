#!/usr/bin/env bash
# setup-gcp-secrets.sh — Migrate secrets to GCP Secret Manager (one-time setup)
# Reads values from bot .env.backup files and creates SM secrets.
# Requires: gcloud auth with channellab-prod Secret Manager Admin access

set -euo pipefail

PROJECT="channellab-prod"
BOTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

_create_or_update_secret() {
    local name="$1" value="$2"
    if gcloud secrets describe "$name" --project="$PROJECT" >/dev/null 2>&1; then
        echo "$value" | gcloud secrets versions add "$name" --project="$PROJECT" --data-file=-
        echo "[setup-secrets] UPDATED: $name"
    else
        echo "$value" | gcloud secrets create "$name" --project="$PROJECT" \
            --replication-policy="user-managed" \
            --locations="asia-east1" \
            --data-file=-
        echo "[setup-secrets] CREATED: $name"
    fi
}

_read_env_var() {
    local file="$1" varname="$2"
    grep -m1 "^${varname}=" "$file" 2>/dev/null | sed "s/^${varname}=//;s/[[:space:]]*#.*//;s/^['\"]//;s/['\"]$//" || true
}

echo "[setup-secrets] Migrating secrets to ${PROJECT}..."

# 1. Shared ANTHROPIC_API_KEY
SHARED_ENV="${BOTS_ROOT}/shared/.env.backup"
ANTHROPIC_KEY=$(_read_env_var "$SHARED_ENV" "ANTHROPIC_API_KEY")
if [ -z "$ANTHROPIC_KEY" ]; then
    ANTHROPIC_KEY=$(_read_env_var "${BOTS_ROOT}/shared/secrets/llm-keys.env" "ANTHROPIC_API_KEY")
fi
[ -n "$ANTHROPIC_KEY" ] && _create_or_update_secret "anthropic-api-key" "$ANTHROPIC_KEY" || \
    echo "[setup-secrets] WARN: ANTHROPIC_API_KEY not found"

# 2. Per-bot TG tokens
declare -A BOT_TOKEN_SECRETS=(
    ["anya"]="tg-token-anya"
    ["ron-assistant"]="tg-token-panda"
    ["nicky-zhanglinghe"]="tg-token-zhanglinghe"
    ["chltao"]="tg-token-elon"
    ["caijie-zhuchu"]="tg-token-zhuchu"
    ["33-huizhang"]="tg-token-33-huizhang"
    ["anna"]="tg-token-anna"
    ["Bella"]="tg-token-bella"
    ["sancai"]="tg-token-sancai"
)

for bot_dir in "${!BOT_TOKEN_SECRETS[@]}"; do
    secret_name="${BOT_TOKEN_SECRETS[$bot_dir]}"
    env_file="${BOTS_ROOT}/bots/${bot_dir}/.env.backup"
    if [ -f "$env_file" ]; then
        token=$(_read_env_var "$env_file" "TELEGRAM_BOT_TOKEN")
        [ -n "$token" ] && _create_or_update_secret "$secret_name" "$token" || \
            echo "[setup-secrets] WARN: TELEGRAM_BOT_TOKEN not found in ${env_file}"
    else
        echo "[setup-secrets] WARN: ${env_file} not found"
    fi
done

echo "[setup-secrets] Done. Verify:"
echo "  gcloud secrets list --project=${PROJECT}"

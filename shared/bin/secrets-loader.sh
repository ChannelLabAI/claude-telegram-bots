#!/usr/bin/env bash
# secrets-loader.sh — Load secrets from GCP Secret Manager with .env.backup fallback
# Usage: source /path/to/shared/bin/secrets-loader.sh <bot_name>
# bot_name matches the tg-token-{bot_name} secret (e.g. anya, anna, bella, panda...)

set +e  # don't exit on error — fallback handles it

BOT_NAME="${1:-}"
GCP_PROJECT="channellab-prod"
BOTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_BACKUP="${BOTS_ROOT}/shared/.env.backup"

_secrets_ok=0

_load_secret() {
    local secret_name="$1" env_var="$2"
    local value
    value=$(gcloud secrets versions access latest \
        --secret="$secret_name" \
        --project="$GCP_PROJECT" 2>/dev/null) || return 1
    if [ -n "$value" ]; then
        export "$env_var"="$value"
        return 0
    fi
    return 1
}

# Try Secret Manager first
if gcloud auth print-access-token --project="$GCP_PROJECT" >/dev/null 2>&1; then
    if _load_secret "anthropic-api-key" "ANTHROPIC_API_KEY"; then
        _secrets_ok=1
        if [ -n "$BOT_NAME" ]; then
            _load_secret "tg-token-${BOT_NAME}" "TELEGRAM_BOT_TOKEN" || \
                echo "[secrets-loader] WARN: tg-token-${BOT_NAME} not found in Secret Manager" >&2
        fi
        echo "[secrets-loader] Loaded from Secret Manager (bot=${BOT_NAME:-global})" >&2
    fi
fi

# Fallback: .env.backup
if [ "$_secrets_ok" -eq 0 ]; then
    if [ -f "$ENV_BACKUP" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_BACKUP"
        set +a
        echo "[secrets-loader] WARN: Secret Manager unavailable, loaded from .env.backup" >&2
    else
        echo "[secrets-loader] ERROR: Neither Secret Manager nor .env.backup available" >&2
    fi
fi

unset _secrets_ok BOT_NAME GCP_PROJECT BOTS_ROOT ENV_BACKUP
unset -f _load_secret

#!/usr/bin/env bash
# secrets-loader.sh — Load secrets from GCP Secret Manager with .env.backup fallback
# Usage: source /path/to/shared/bin/secrets-loader.sh <bot_token_name> [bot_dir]
#   bot_token_name: matches tg-token-{name} secret (e.g. anya, anna, bella, panda)
#                   pass "" to skip per-bot token
#   bot_dir:        absolute path to bot directory (for per-bot .env.backup fallback)

# m1: save caller's errexit state and disable it; restore on exit
_sl_old_opts="$-"
set +e

BOT_NAME="${1:-}"
BOT_DIR="${2:-}"
GCP_PROJECT="channellab-prod"
BOTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHARED_BACKUP="${BOTS_ROOT}/shared/.env.backup"

_sl_ok=0

_sl_load_secret() {
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
    if _sl_load_secret "anthropic-api-key" "ANTHROPIC_API_KEY"; then
        _sl_ok=1
        if [ -n "$BOT_NAME" ]; then
            _sl_load_secret "tg-token-${BOT_NAME}" "TELEGRAM_BOT_TOKEN" || \
                echo "[secrets-loader] WARN: tg-token-${BOT_NAME} not found in Secret Manager" >&2
        fi
        echo "[secrets-loader] Loaded from Secret Manager (bot=${BOT_NAME:-global})" >&2
    fi
fi

# B1: Fallback loads BOTH shared .env.backup (ANTHROPIC_API_KEY)
#     AND per-bot .env.backup (TELEGRAM_BOT_TOKEN)
if [ "$_sl_ok" -eq 0 ]; then
    if [ -f "$SHARED_BACKUP" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$SHARED_BACKUP"
        set +a
        echo "[secrets-loader] WARN: loaded ANTHROPIC_API_KEY from shared .env.backup" >&2
    else
        echo "[secrets-loader] ERROR: shared/.env.backup not found" >&2
    fi
    # Per-bot .env.backup for TELEGRAM_BOT_TOKEN
    if [ -n "$BOT_DIR" ] && [ -f "${BOT_DIR}/.env.backup" ]; then
        set -a
        # shellcheck source=/dev/null
        source "${BOT_DIR}/.env.backup"
        set +a
        echo "[secrets-loader] WARN: loaded TELEGRAM_BOT_TOKEN from ${BOT_DIR}/.env.backup" >&2
    elif [ -n "$BOT_NAME" ]; then
        echo "[secrets-loader] WARN: no per-bot .env.backup for ${BOT_NAME}" >&2
    fi
fi

# m1: restore caller's errexit state
[[ "$_sl_old_opts" == *e* ]] && set -e

unset _sl_ok _sl_old_opts BOT_NAME BOT_DIR GCP_PROJECT BOTS_ROOT SHARED_BACKUP
unset -f _sl_load_secret

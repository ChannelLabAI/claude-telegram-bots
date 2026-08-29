#!/usr/bin/env bash
# Reviewer-approved host rollout. It enforces capture -> clear -> install as
# three complete phases; installation cannot begin while any legacy token remains.
set -euo pipefail

if [[ "${1:-}" != "--apply" || "$#" -ne 1 ]]; then
  echo "usage: deploy-hook-rollout.sh --apply" >&2
  exit 2
fi

ROOT="${DEPLOY_HOOK_ROLLOUT_ROOT:-/home/oldrabbit/.claude-bots}"
FATQ_ROOT="${DEPLOY_HOOK_ROLLOUT_FATQ_ROOT:-$ROOT/tasks}"
INSTALLER="${DEPLOY_HOOK_ROLLOUT_INSTALLER:-$ROOT/shared/bin/install-deploy-hook.sh}"
EVIDENCE="${DEPLOY_HOOK_ROLLOUT_EVIDENCE:-$ROOT/logs/deploy-hook-rollout-$(date -u '+%Y%m%dT%H%M%SZ').log}"
mkdir -p "$(dirname "$EVIDENCE")"
touch "$EVIDENCE"
chmod 600 "$EVIDENCE"

REPOS=(
  "$ROOT|main"
  "$ROOT/infra|master"
  "$ROOT/pod-system|master"
  "$ROOT/shared/memocean-mcp|main"
)

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
record() { printf '%s %s\n' "$(stamp)" "$*" | tee -a "$EVIDENCE"; }
common_dir() {
  local repo="$1" value
  value=$(git -C "$repo" rev-parse --git-common-dir)
  [[ "$value" == /* ]] || value="$repo/$value"
  printf '%s\n' "$value"
}

record "PHASE=capture begin"
for entry in "${REPOS[@]}"; do
  repo=${entry%%|*}
  token="$(common_dir "$repo")/DEPLOY_APPROVED"
  if [[ -f "$token" ]]; then
    token_json=$(jq -c '{task_id,commit,approved_by,ts}' "$token")
    if ! jq -e '.task_id and .commit and .approved_by and .ts' "$token" >/dev/null; then
      record "PHASE=capture REFUSED repo=$repo reason=incomplete-token token=$token_json"
      exit 1
    fi
    record "PHASE=capture repo=$repo token=$token_json"
  else
    record "PHASE=capture repo=$repo token=MISSING"
  fi
done
record "PHASE=capture complete"

record "PHASE=clear begin"
for entry in "${REPOS[@]}"; do
  repo=${entry%%|*}
  token="$(common_dir "$repo")/DEPLOY_APPROVED"
  rm -f -- "$token"
  [[ ! -e "$token" ]] || { record "PHASE=clear REFUSED repo=$repo reason=token-remains"; exit 1; }
  record "PHASE=clear repo=$repo token=absent"
done
record "PHASE=clear complete"

# Hard ordering barrier: re-check every token before installing the first hook.
for entry in "${REPOS[@]}"; do
  repo=${entry%%|*}
  token="$(common_dir "$repo")/DEPLOY_APPROVED"
  [[ ! -e "$token" ]] || { record "PHASE=preinstall REFUSED repo=$repo reason=token-reappeared"; exit 1; }
done

record "PHASE=install begin"
for entry in "${REPOS[@]}"; do
  repo=${entry%%|*}
  branch=${entry#*|}
  output=$(bash "$INSTALLER" "$repo" "$branch" "$FATQ_ROOT" 2>&1)
  record "PHASE=install repo=$repo branch=$branch output=$output"
done
record "PHASE=install complete"
record "RESULT=PASS evidence=$EVIDENCE"

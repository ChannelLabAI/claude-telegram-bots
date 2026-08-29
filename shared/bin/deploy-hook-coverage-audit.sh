#!/usr/bin/env bash
set -uo pipefail

# No arguments by contract. Tests may override the newline-delimited repo list
# through DEPLOY_HOOK_COVERAGE_REPOS; production uses these five canonical repos.
if [[ "$#" -ne 0 ]]; then
  echo "usage: bash shared/bin/deploy-hook-coverage-audit.sh" >&2
  exit 2
fi

if [[ -n "${DEPLOY_HOOK_COVERAGE_REPOS:-}" ]]; then
  mapfile -t REPOS <<<"$DEPLOY_HOOK_COVERAGE_REPOS"
else
  REPOS=(
    /home/oldrabbit/.claude-bots
    /home/oldrabbit/.claude-bots/infra
    /home/oldrabbit/.claude-bots/pod-system
    /home/oldrabbit/.claude-bots/shared/memocean-mcp
    /home/oldrabbit/.claude-bots/mvp
  )
fi

missing=0
for repo in "${REPOS[@]}"; do
  common_dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || {
    echo "MISSING repo=$repo reason=not-a-git-repo"
    missing=$((missing + 1))
    continue
  }
  [[ "$common_dir" == /* ]] || common_dir="$repo/$common_dir"
  hook="$common_dir/hooks/reference-transaction"
  if [[ -x "$hook" ]]; then
    echo "OK repo=$repo hook=$hook executable=yes"
  else
    echo "MISSING repo=$repo hook=$hook reason=not-executable-or-absent"
    missing=$((missing + 1))
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "COVERAGE FAIL missing=$missing total=${#REPOS[@]}"
  exit 1
fi
echo "COVERAGE PASS missing=0 total=${#REPOS[@]}"
exit 0

#!/usr/bin/env bash
# Canonical operator entry for a reviewed, non-editable MemOcean deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${MEMOCEAN_BOTS_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REPO_ROOT="${MEMOCEAN_REPO_ROOT:-$ROOT_DIR/shared/memocean-mcp}"
DEPLOY_IMPL="${MEMOCEAN_DEPLOY_IMPL:-$REPO_ROOT/ops/deploy.sh}"
DRIFT_CHECK="${MEMOCEAN_DRIFT_CHECK:-$SCRIPT_DIR/memocean-drift-check.sh}"
DEPLOY_RECORD="${MEMOCEAN_DEPLOY_RECORD:-$ROOT_DIR/logs/memocean-mcp-deployment.json}"

[[ -d "$REPO_ROOT/.git" ]] || { echo "[memocean-mcp-deploy] repository not found: $REPO_ROOT" >&2; exit 2; }
[[ -x "$DEPLOY_IMPL" ]] || { echo "[memocean-mcp-deploy] implementation not executable: $DEPLOY_IMPL" >&2; exit 2; }
[[ -x "$DRIFT_CHECK" ]] || { echo "[memocean-mcp-deploy] drift gate not executable: $DRIFT_CHECK" >&2; exit 2; }

repo_commit="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
source_status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- memocean_mcp pyproject.toml)"
if [[ -n "$source_status" ]]; then
  echo "[memocean-mcp-deploy] refusing dirty package sources or pyproject.toml:" >&2
  printf '%s\n' "$source_status" >&2
  exit 2
fi

MEMOCEAN_REPO_ROOT="$REPO_ROOT" bash "$DEPLOY_IMPL"
MEMOCEAN_REPO_ROOT="$REPO_ROOT" MEMOCEAN_DRIFT_TRIGGER=post-deploy bash "$DRIFT_CHECK"

mkdir -p "$(dirname "$DEPLOY_RECORD")"
record_tmp="$(mktemp "${DEPLOY_RECORD}.XXXXXX")"
trap 'rm -f "$record_tmp"' EXIT
"${MEMOCEAN_PYTHON:-python3}" - "$record_tmp" "$repo_commit" "$REPO_ROOT" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

path, commit, repo = sys.argv[1:]
payload = {
    "repo_commit": commit,
    "repo_root": str(Path(repo).resolve()),
    "installed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    "install_mode": "non-editable",
}
Path(path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
chmod 600 "$record_tmp"
mv "$record_tmp" "$DEPLOY_RECORD"
trap - EXIT

echo "[memocean-mcp-deploy] deployment verified repo_commit=$repo_commit record=$DEPLOY_RECORD"

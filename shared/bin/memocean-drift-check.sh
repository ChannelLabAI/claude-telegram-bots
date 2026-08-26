#!/usr/bin/env bash
# Canonical MemOcean deployment drift gate. Compare repository Python sources
# with the non-editable package Python imports; notify the named consumer on drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${MEMOCEAN_BOTS_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REPO_ROOT="${MEMOCEAN_REPO_ROOT:-$ROOT_DIR/shared/memocean-mcp}"
REPO_PACKAGE="${MEMOCEAN_REPO_PACKAGE:-$REPO_ROOT/memocean_mcp}"
PYTHON_BIN="${MEMOCEAN_PYTHON:-python3}"
TRIGGER="${MEMOCEAN_DRIFT_TRIGGER:-manual}"
NOTIFY_BIN="${MEMOCEAN_DRIFT_NOTIFY_BIN:-$ROOT_DIR/shared/bin/relay-notify}"
RELAY_DIR="${MEMOCEAN_DRIFT_RELAY_DIR:-$ROOT_DIR/relay}"
NOTIFY_STATE_DIR="${MEMOCEAN_DRIFT_STATE_DIR:-$ROOT_DIR/logs/.memocean-mcp-drift-state}"
LOG_PATH="${MEMOCEAN_DRIFT_LOG:-$ROOT_DIR/logs/memocean-mcp-drift.log}"

fail() {
  echo "[memocean-mcp-drift] ERROR trigger=$TRIGGER $*" >&2
  exit 2
}

[[ -d "$REPO_PACKAGE" ]] || fail "repo package not found: $REPO_PACKAGE"

INSTALL_PACKAGE="${MEMOCEAN_INSTALL_PACKAGE:-}"
if [[ -z "$INSTALL_PACKAGE" ]]; then
  INSTALL_PACKAGE="$({
    cd /
    "$PYTHON_BIN" - <<'PY'
import importlib.util
from pathlib import Path

spec = importlib.util.find_spec("memocean_mcp")
if spec is None or not spec.submodule_search_locations:
    raise SystemExit("memocean_mcp is not installed")
print(Path(next(iter(spec.submodule_search_locations))).resolve())
PY
  })" || fail "cannot resolve installed memocean_mcp with $PYTHON_BIN"
fi

[[ -d "$INSTALL_PACKAGE" ]] || fail "installed package not found: $INSTALL_PACKAGE"

repo_real="$(realpath "$REPO_PACKAGE")"
install_real="$(realpath "$INSTALL_PACKAGE")"
[[ "$repo_real" != "$install_real" ]] || fail "installed package resolves to repo (editable install is unsupported)"

mapfile -t python_files < <(
  {
    find "$REPO_PACKAGE" -type f -name '*.py' -printf '%P\n'
    find "$INSTALL_PACKAGE" -type f -name '*.py' -printf '%P\n'
  } | LC_ALL=C sort -u
)

drift=0
drift_entries=()
for relative_path in "${python_files[@]}"; do
  repo_file="$REPO_PACKAGE/$relative_path"
  install_file="$INSTALL_PACKAGE/$relative_path"
  if [[ ! -f "$repo_file" ]]; then
    echo "[memocean-mcp-drift] DRIFT extra-installed $relative_path"
    drift_entries+=("extra-installed $relative_path")
    drift=1
  elif [[ ! -f "$install_file" ]]; then
    echo "[memocean-mcp-drift] DRIFT missing-installed $relative_path"
    drift_entries+=("missing-installed $relative_path")
    drift=1
  elif ! cmp -s "$repo_file" "$install_file"; then
    echo "[memocean-mcp-drift] DRIFT content-diff $relative_path"
    repo_hash="$(sha256sum "$repo_file" | awk '{print $1}')"
    install_hash="$(sha256sum "$install_file" | awk '{print $1}')"
    drift_entries+=("content-diff $relative_path repo=$repo_hash installed=$install_hash")
    drift=1
  fi
done

timestamp="$(TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S%:z')"
if [[ "$drift" -ne 0 ]]; then
  echo "[memocean-mcp-drift] FAIL trigger=$TRIGGER ts=$timestamp repo=$repo_real installed=$install_real" >&2
  signature="$(printf '%s\n' "${drift_entries[@]}" | sha256sum | awk '{print $1}')"
  state_file="$NOTIFY_STATE_DIR/last-notified-signature"
  previous_signature="$(cat "$state_file" 2>/dev/null || true)"
  if [[ "$previous_signature" == "$signature" ]]; then
    echo "[memocean-mcp-drift] NOTIFY deduplicated signature=$signature" >&2
  else
    message="[memocean-mcp-drift] FAIL trigger=$TRIGGER signature=$signature — repo 與 production site-packages 的 .py 原始碼不一致；請由 Anya/maintainer 處置。詳見 $LOG_PATH"
    if [[ -x "$NOTIFY_BIN" ]] && \
      RELAY_NOTIFY_DIR="$RELAY_DIR" "$NOTIFY_BIN" memocean-mcp-drift anya "$message" >/dev/null; then
      mkdir -p "$NOTIFY_STATE_DIR"
      state_tmp="$(mktemp "$NOTIFY_STATE_DIR/.last-notified-signature.XXXXXX")"
      printf '%s\n' "$signature" > "$state_tmp"
      mv "$state_tmp" "$state_file"
      echo "[memocean-mcp-drift] NOTIFY sent consumer=relay:anya signature=$signature" >&2
    else
      echo "[memocean-mcp-drift] WARN notification failed consumer=relay:anya bin=$NOTIFY_BIN; drift remains failed and notification will retry" >&2
    fi
  fi
  exit 1
fi

rm -f "$NOTIFY_STATE_DIR/last-notified-signature"
echo "[memocean-mcp-drift] OK trigger=$TRIGGER ts=$timestamp py_files=${#python_files[@]} repo=$repo_real installed=$install_real"

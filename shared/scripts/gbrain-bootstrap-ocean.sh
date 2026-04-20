#!/usr/bin/env bash
# gbrain-bootstrap-ocean.sh — One-shot Ocean vault import into GBrain.
#
# Safety contract:
#   - Only ever imports Ocean/ (never parent vault, never OldRabbit/).
#   - Verifies target dir resolves inside Ocean before invoking gbrain.
#   - Dry-run flag available: BOOTSTRAP_DRY_RUN=1
#
# Usage:
#   bash gbrain-bootstrap-ocean.sh [--fresh] [--no-embed] [--workers N]
#
# Flags forwarded to gbrain import:
#   --fresh       drop and reimport all pages
#   --no-embed    skip embedding (faster, keyword-only search)
#   --workers N   parallel workers (default: gbrain decides)

set -euo pipefail

GBRAIN="${HOME}/.bun/bin/gbrain"
OCEAN_DIR="${HOME}/Documents/Obsidian Vault/Ocean"
PRIVACY_CHECK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/memocean-mcp/gbrain-privacy-check.py"

# ── Arg parsing ───────────────────────────────────────────────────────────────

EXTRA_FLAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh|--no-embed)
      EXTRA_FLAGS+=("$1")
      shift
      ;;
    --workers)
      EXTRA_FLAGS+=("$1" "$2")
      shift 2
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [--fresh] [--no-embed] [--workers N]" >&2
      exit 1
      ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────

echo "=== GBrain Bootstrap: Ocean vault import ==="
echo "Target: ${OCEAN_DIR}"
echo ""

# 1. gbrain binary must exist
if [[ ! -x "${GBRAIN}" ]]; then
  echo "ERROR: gbrain not found at ${GBRAIN}" >&2
  exit 1
fi

# 2. Ocean dir must exist
if [[ ! -d "${OCEAN_DIR}" ]]; then
  echo "ERROR: Ocean vault not found at: ${OCEAN_DIR}" >&2
  exit 1
fi

# 3. Resolve symlinks — must be strictly inside "Obsidian Vault/Ocean"
REAL_OCEAN=$(realpath "${OCEAN_DIR}")
REAL_VAULT=$(realpath "${HOME}/Documents/Obsidian Vault")

# Guard: resolved path must be the Ocean dir, not the parent vault
if [[ "${REAL_OCEAN}" == "${REAL_VAULT}" ]] || \
   [[ "${REAL_OCEAN}" == "${REAL_VAULT}/OldRabbit" ]] || \
   [[ "${REAL_OCEAN}" != "${REAL_VAULT}/Ocean" ]]; then
  echo "ERROR: Privacy gate — target resolved to '${REAL_OCEAN}'" >&2
  echo "       Expected exactly: ${REAL_VAULT}/Ocean" >&2
  exit 2
fi

echo "Privacy gate: OK (${REAL_OCEAN})"

# 4. gbrain health probe
GBRAIN_VER=$("${GBRAIN}" --version 2>&1 | head -1) || true
if [[ -z "${GBRAIN_VER}" ]]; then
  echo "ERROR: gbrain --version failed" >&2
  exit 1
fi
echo "GBrain version: ${GBRAIN_VER}"
echo ""

# ── Dry-run short-circuit ─────────────────────────────────────────────────────

if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
  echo "[DRY RUN] Would execute:"
  echo "  ${GBRAIN} import \"${REAL_OCEAN}\" ${EXTRA_FLAGS[*]:-}"
  echo ""
  echo "Dry run complete. Set BOOTSTRAP_DRY_RUN=0 to execute."
  exit 0
fi

# ── Import ────────────────────────────────────────────────────────────────────

echo "Starting import (this may take several minutes)..."
echo "Command: ${GBRAIN} import \"${REAL_OCEAN}\" ${EXTRA_FLAGS[*]:-}"
echo ""

START_TS=$(date +%s)

"${GBRAIN}" import "${REAL_OCEAN}" "${EXTRA_FLAGS[@]}"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo ""
echo "Import complete in ${ELAPSED}s."

# ── Post-import privacy probe ─────────────────────────────────────────────────
# Spot-check: gbrain list should return only Ocean slugs (no OldRabbit/)

echo ""
echo "Running post-import privacy probe..."

OLDRB_LEAK=$("${GBRAIN}" list 2>/dev/null | grep -i "oldrabbit\|old-rabbit\|OldRabbit" || true)
if [[ -n "${OLDRB_LEAK}" ]]; then
  echo "WARNING: Potential OldRabbit data leak detected in GBrain:" >&2
  echo "${OLDRB_LEAK}" >&2
  echo ""
  echo "Review the above slugs. If personal data leaked, run:" >&2
  echo "  gbrain delete <slug>  (for each affected slug)" >&2
  exit 3
fi

echo "Privacy probe: PASS — no OldRabbit/ slugs found."

# ── Summary ───────────────────────────────────────────────────────────────────

PAGE_COUNT=$("${GBRAIN}" list 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "=== Bootstrap complete ==="
echo "Pages in GBrain: ${PAGE_COUNT}"
echo "Elapsed: ${ELAPSED}s"
echo ""
echo "Next: set MEMOCEAN_USE_GBRAIN=true and run Stage 1.3 benchmark."

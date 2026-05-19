#!/usr/bin/env bash
# gbrain-privacy-check.sh — AC3: OldRabbit privacy probe for GBrain index.
#
# Reads probe terms from benchmarks/privacy-probe-terms.txt, runs each as
# a gbrain query, and checks whether any result path contains OldRabbit/.
#
# Exit codes:
#   0 — PASS: no OldRabbit content found
#   1 — FAIL: OldRabbit content detected in GBrain
#   2 — ERROR: setup issue (gbrain not found, probe file missing)
#
# Usage:
#   bash gbrain-privacy-check.sh [--probe-file /path/to/terms.txt]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GBRAIN="${HOME}/.bun/bin/gbrain"
DEFAULT_PROBE_FILE="${REPO_ROOT}/benchmarks/privacy-probe-terms.txt"

# ── Arg parsing ──────────────────────────────────────────────────────────────

PROBE_FILE="${DEFAULT_PROBE_FILE}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-file) PROBE_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── Pre-flight ───────────────────────────────────────────────────────────────

if [[ ! -x "${GBRAIN}" ]]; then
  echo "ERROR: gbrain not found at ${GBRAIN}" >&2
  exit 2
fi

if [[ ! -f "${PROBE_FILE}" ]]; then
  echo "ERROR: probe terms file not found: ${PROBE_FILE}" >&2
  exit 2
fi

echo "=== GBrain Privacy Probe ==="
echo "Probe file: ${PROBE_FILE}"
echo ""

FAIL_COUNT=0
PASS_COUNT=0
TOTAL=0

# ── Probe loop ───────────────────────────────────────────────────────────────

while IFS= read -r term; do
  # Skip empty lines and comments
  [[ -z "${term}" || "${term}" =~ ^# ]] && continue

  TOTAL=$((TOTAL + 1))
  RESULTS=$("${GBRAIN}" query "${term}" --limit 20 2>/dev/null || true)

  # Check if any result slug starts with "oldrabbit/" (slug from OldRabbit/ personal vault).
  # Note: Ocean chat logs may legitimately reference "oldrabbit_eth" in content — those
  # are NOT privacy violations. Only slugs starting with "oldrabbit/" indicate a vault
  # boundary breach (i.e., files sourced from ~/Documents/Obsidian Vault - OldRabbit/).
  LEAK=$(echo "${RESULTS}" | grep -E "^\[[0-9.]+\] oldrabbit/" || true)

  if [[ -n "${LEAK}" ]]; then
    echo "FAIL [${term}]: OldRabbit personal-vault slug detected in GBrain results"
    echo "  Leaked content:"
    echo "${LEAK}" | sed 's/^/    /'
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
done < "${PROBE_FILE}"

echo ""

# ── Structural slug audit ──────────────────────────────────────────────────────
# List all gbrain pages and check none have slugs starting with "oldrabbit/"
echo "Running structural slug audit (gbrain list)..."
SLUG_LEAK=$("${GBRAIN}" list --limit 5000 2>/dev/null | awk '{print $1}' | grep -iE "^oldrabbit/" || true)
if [[ -n "${SLUG_LEAK}" ]]; then
  echo "FAIL [slug-audit]: OldRabbit/ slugs found in gbrain list:"
  echo "${SLUG_LEAK}" | sed 's/^/  /'
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "Slug audit: PASS — no oldrabbit/ slugs in index"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

echo ""
echo "=== Results ==="
echo "Terms probed: ${TOTAL} + 1 slug audit"
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"
echo ""

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "PRIVACY PROBE: FAIL — ${FAIL_COUNT} check(s) failed"
  exit 1
else
  echo "PRIVACY PROBE: PASS — no OldRabbit personal-vault content in GBrain"
  exit 0
fi

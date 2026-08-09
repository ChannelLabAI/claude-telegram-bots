#!/usr/bin/env bash
# gbrain-privacy-check.sh — AC3: OldRabbit privacy probe for GBrain index.
#
# Reads probe terms from benchmarks/privacy-probe-terms.txt, runs each as
# a gbrain query, and checks whether any result path contains OldRabbit/.
#
# Exit codes:
#   0 — PASS: no OldRabbit content found and the query pipeline was verified
#   1 — FAIL: a leak was found or the result is not trustworthy
#   2 — ERROR: setup issue (gbrain not found, probe file missing)
#
# Usage:
#   bash gbrain-privacy-check.sh [--probe-file /path/to/terms.txt]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GBRAIN="${GBRAIN_BIN:-${HOME}/.bun/bin/gbrain}"
DEFAULT_PROBE_FILE="${REPO_ROOT}/benchmarks/privacy-probe-terms.txt"
# Anya verified this query against the shared index on 2026-08-09.  Operators
# may override it only when their index has a different known-public document.
POSITIVE_CONTROL_QUERY="${GBRAIN_PRIVACY_POSITIVE_CONTROL_QUERY:-身分證}"

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

# A command failure, an empty response, a clean response, and a leak must not
# collapse into the same result.  In particular, never use `|| true` here:
# the old form turned a broken query pipeline into a clean PASS.
run_query() {
  local query="$1"
  QUERY_OUTPUT=""
  QUERY_ERROR=""

  if ! QUERY_OUTPUT=$("${GBRAIN}" query "${query}" --limit 20 2>&1); then
    QUERY_ERROR="${QUERY_OUTPUT}"
    return 1
  fi

  if [[ -z "${QUERY_OUTPUT//[[:space:]]/}" ]]; then
    return 2
  fi
  return 0
}

# ── Positive control ─────────────────────────────────────────────────────────

echo "Running positive control query: ${POSITIVE_CONTROL_QUERY}"
if run_query "${POSITIVE_CONTROL_QUERY}"; then
  POSITIVE_RESULT_COUNT=$(grep -cE '^\[[0-9.]+' <<< "${QUERY_OUTPUT}" || true)
  if [[ "${POSITIVE_RESULT_COUNT}" -gt 0 ]]; then
    echo "PASS [positive_control]: ${POSITIVE_RESULT_COUNT} known-public result(s) returned"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL [positive_control]: query returned zero matching results; this run is untrustworthy"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  query_status=$?
  if [[ "${query_status}" -eq 1 ]]; then
    echo "FAIL [positive_control]: query pipeline error; this run is untrustworthy"
    [[ -n "${QUERY_ERROR}" ]] && echo "  ${QUERY_ERROR}"
  else
    echo "FAIL [positive_control]: query returned no output; this run is untrustworthy"
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ── Probe loop ───────────────────────────────────────────────────────────────

while IFS= read -r term; do
  # Skip empty lines and comments
  [[ -z "${term}" || "${term}" =~ ^# ]] && continue

  TOTAL=$((TOTAL + 1))
  if run_query "${term}"; then
    RESULTS="${QUERY_OUTPUT}"
  else
    query_status=$?
    if [[ "${query_status}" -eq 1 ]]; then
      echo "FAIL [${term}]: query pipeline error"
      [[ -n "${QUERY_ERROR}" ]] && echo "  ${QUERY_ERROR}"
    else
      echo "EMPTY [${term}]: query returned no output (no leak decision made from this response)"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

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
    RESULT_COUNT=$(grep -cE '^\[[0-9.]+' <<< "${RESULTS}" || true)
    echo "CLEAN [${term}]: ${RESULT_COUNT} result(s), no OldRabbit personal-vault slug"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
done < "${PROBE_FILE}"

echo ""

# ── Structural slug audit ──────────────────────────────────────────────────────
# List all gbrain pages and check none have slugs starting with "oldrabbit/"
echo "Running structural slug audit (gbrain list)..."
LIST_OUTPUT=""
LIST_ERROR=""
if ! LIST_OUTPUT=$("${GBRAIN}" list --limit 5000 2>&1); then
  LIST_ERROR="${LIST_OUTPUT}"
  echo "FAIL [slug-audit]: list command failed; this run is untrustworthy"
  [[ -n "${LIST_ERROR}" ]] && echo "  ${LIST_ERROR}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
elif [[ -z "${LIST_OUTPUT//[[:space:]]/}" ]]; then
  echo "EMPTY [slug-audit]: list returned no output; this run is untrustworthy"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  SLUG_LEAK=$(awk '{print $1}' <<< "${LIST_OUTPUT}" | grep -iE "^oldrabbit/" || true)
  if [[ -n "${SLUG_LEAK}" ]]; then
  echo "FAIL [slug-audit]: OldRabbit/ slugs found in gbrain list:"
  echo "${SLUG_LEAK}" | sed 's/^/  /'
  FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    LIST_COUNT=$(grep -cve '^[[:space:]]*$' <<< "${LIST_OUTPUT}" || true)
    echo "CLEAN [slug-audit]: ${LIST_COUNT} listed page(s), no oldrabbit/ slug"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
fi

echo ""
echo "=== Results ==="
echo "Terms probed: ${TOTAL} + 1 positive control + 1 slug audit"
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"
echo ""

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "PRIVACY PROBE: FAIL — ${FAIL_COUNT} check(s) failed; query errors/empty controls make this run untrustworthy"
  exit 1
else
  echo "PRIVACY PROBE: PASS — no OldRabbit personal-vault content in GBrain"
  exit 0
fi

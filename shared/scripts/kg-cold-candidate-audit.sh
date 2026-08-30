#!/usr/bin/env bash
# Audit pending/cold stale-candidate reconciliation against live radar rows.
#
# KG_COLD_CANDIDATE_DB may point at a read-only fixture/copy for validation.
# The production default is read only; this script never mutates the database.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
db_path="${KG_COLD_CANDIDATE_DB:-${repo_root}/memory.db}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 is required" >&2
  exit 2
fi
if [[ ! -f "${db_path}" ]]; then
  echo "ERROR: memory database not found: ${db_path}" >&2
  exit 2
fi

cutoff="$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ)"

# Keep this predicate aligned with the original 11d8 live probe: pending/cold
# rows are wrong only when their live radar row is no longer cold.
wrong="$(sqlite3 "${db_path}" "
  SELECT COUNT(*)
  FROM stale_candidates s
  JOIN radar r ON s.slug=r.slug
  WHERE s.reason='cold'
    AND s.status='pending'
    AND NOT (
      r.encoded_at < '${cutoff}'
      AND (r.last_accessed IS NULL OR r.last_accessed < '${cutoff}')
    );
")"

# archived and reviewed_valid are deliberately retained terminal/manual states,
# so either one satisfies the requirement that a current cold row is recorded.
missing="$(sqlite3 "${db_path}" "
  SELECT COUNT(*)
  FROM radar r
  WHERE r.encoded_at < '${cutoff}'
    AND (r.last_accessed IS NULL OR r.last_accessed < '${cutoff}')
    AND NOT EXISTS (
      SELECT 1
      FROM stale_candidates s
      WHERE s.slug=r.slug
        AND s.reason='cold'
        AND s.status IN ('pending', 'archived', 'reviewed_valid')
    );
")"

# checked is the actual observation set: live radar rows currently old enough
# to qualify as cold. An empty set makes the audit untrustworthy, not green.
checked="$(sqlite3 "${db_path}" "
  SELECT COUNT(*)
  FROM radar r
  WHERE r.encoded_at < '${cutoff}'
    AND (r.last_accessed IS NULL OR r.last_accessed < '${cutoff}');
")"
radar_total="$(sqlite3 "${db_path}" "SELECT COUNT(*) FROM radar;")"

error_total=$((wrong + missing))
threshold=$((radar_total / 200))

printf 'checked=%d wrong_in_pending=%d missing_from_pending=%d error_total=%d threshold_0.5pct=%d\n' \
  "${checked}" "${wrong}" "${missing}" "${error_total}" "${threshold}"

if ((checked == 0)); then
  echo "FAIL: checked=0; no cold radar rows were observed" >&2
  exit 1
fi

((error_total <= threshold))

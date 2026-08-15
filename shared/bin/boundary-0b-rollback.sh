#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/boundary-0b-common.sh
source "$SCRIPT_DIR/../lib/boundary-0b-common.sh"

ROOT="$(boundary_0b_repo_root)"
MANIFEST=""
DRY_RUN=0
CHATTR_BIN="${BOUNDARY_0B_CHATTR_BIN:-chattr}"
CHOWN_BIN="${BOUNDARY_0B_CHOWN_BIN:-chown}"
CHMOD_BIN="${BOUNDARY_0B_CHMOD_BIN:-chmod}"

usage() {
  cat >&2 <<'EOF'
Usage: boundary-0b-rollback.sh [--root DIR] [--manifest FILE] [--dry-run]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

ROOT="$(realpath -m -- "$ROOT")"
[[ -n "$MANIFEST" ]] || MANIFEST="$(boundary_0b_default_manifest "$ROOT")"
MANIFEST="$(realpath -m -- "$MANIFEST")"
boundary_0b_validate_manifest "$MANIFEST"

failures=0
restored=0
while IFS=$'\t' read -r relative expected_uid expected_gid expected_mode expected_attrs; do
  if ! target="$(boundary_0b_target "$ROOT" "$relative")"; then
    printf 'ROLLBACK_FAILED|%s|reason=path-resolution\n' "$relative"
    failures=$((failures + 1))
    continue
  fi
  if (( DRY_RUN == 1 )); then
    printf 'PLAN|chattr|-i|%s\n' "$relative"
    printf 'PLAN|chown|%s:%s|%s\n' "$expected_uid" "$expected_gid" "$relative"
    printf 'PLAN|chmod|%s|%s\n' "$expected_mode" "$relative"
    continue
  fi
  if [[ ! -f "$target" ]]; then
    printf 'ROLLBACK_FAILED|%s|reason=missing\n' "$relative"
    failures=$((failures + 1))
    continue
  fi

  file_failed=0
  if ! "$CHATTR_BIN" -i -- "$target"; then
    printf 'ROLLBACK_FAILED|%s|operation=chattr-i\n' "$relative"
    failures=$((failures + 1))
    file_failed=1
  fi
  if ! "$CHOWN_BIN" "$expected_uid:$expected_gid" -- "$target"; then
    printf 'ROLLBACK_FAILED|%s|operation=chown|expected=%s:%s\n' "$relative" "$expected_uid" "$expected_gid"
    failures=$((failures + 1))
    file_failed=1
  fi
  if ! "$CHMOD_BIN" "$expected_mode" -- "$target"; then
    printf 'ROLLBACK_FAILED|%s|operation=chmod|expected=%s\n' "$relative" "$expected_mode"
    failures=$((failures + 1))
    file_failed=1
  fi

  state_read_failed=0
  if ! actual_uid="$(stat -c '%u' -- "$target")"; then
    printf 'ROLLBACK_FAILED|%s|operation=verify-read-uid\n' "$relative"
    failures=$((failures + 1)); file_failed=1; state_read_failed=1
  fi
  if ! actual_gid="$(stat -c '%g' -- "$target")"; then
    printf 'ROLLBACK_FAILED|%s|operation=verify-read-gid\n' "$relative"
    failures=$((failures + 1)); file_failed=1; state_read_failed=1
  fi
  if ! actual_mode="$(stat -c '%a' -- "$target")"; then
    printf 'ROLLBACK_FAILED|%s|operation=verify-read-mode\n' "$relative"
    failures=$((failures + 1)); file_failed=1; state_read_failed=1
  fi
  if ! actual_attrs="$(boundary_0b_lsattr "$target")" || [[ -z "$actual_attrs" ]]; then
    printf 'ROLLBACK_FAILED|%s|operation=verify-read-lsattr\n' "$relative"
    failures=$((failures + 1)); file_failed=1; state_read_failed=1
  fi
  if (( state_read_failed == 1 )); then
    continue
  fi
  if [[ "$actual_uid" != "$expected_uid" || "$actual_gid" != "$expected_gid" \
    || "$actual_mode" != "$expected_mode" || "$actual_attrs" != "$expected_attrs" ]]; then
    printf 'ROLLBACK_FAILED|%s|operation=verify|expected=%s:%s:%s:%s|actual=%s:%s:%s:%s\n' \
      "$relative" "$expected_uid" "$expected_gid" "$expected_mode" "$expected_attrs" \
      "$actual_uid" "$actual_gid" "$actual_mode" "$actual_attrs"
    failures=$((failures + 1))
    file_failed=1
  fi
  if (( file_failed == 0 )); then
    printf 'RESTORED|%s|uid=%s|gid=%s|mode=%s|lsattr=%s\n' \
      "$relative" "$actual_uid" "$actual_gid" "$actual_mode" "$actual_attrs"
    restored=$((restored + 1))
  fi
done < <(boundary_0b_entries "$MANIFEST")

if (( DRY_RUN == 1 )); then
  printf 'DRY_RUN_OK|no-changes-made\n'
  exit 0
fi
printf 'ROLLBACK_SUMMARY|restored=%s|failed_operations=%s\n' "$restored" "$failures"
(( failures == 0 ))

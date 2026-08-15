#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/boundary-0b-common.sh
source "$SCRIPT_DIR/../lib/boundary-0b-common.sh"

ROOT="$(boundary_0b_repo_root)"
MANIFEST=""
CONFIRM=0
CHATTR_BIN="${BOUNDARY_0B_CHATTR_BIN:-chattr}"

usage() {
  cat >&2 <<'EOF'
Usage: boundary-0b-apply.sh [--root DIR] [--manifest FILE] [--confirm]

Without --confirm this command is a dry run and changes nothing.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

ROOT="$(realpath -m -- "$ROOT")"
[[ -n "$MANIFEST" ]] || MANIFEST="$(boundary_0b_default_manifest "$ROOT")"
MANIFEST="$(realpath -m -- "$MANIFEST")"
boundary_0b_validate_manifest "$MANIFEST"

if (( CONFIRM == 0 )); then
  printf 'DRY_RUN|root=%s|manifest=%s\n' "$ROOT" "$MANIFEST"
  while IFS=$'\t' read -r relative _uid _gid _mode _attrs; do
    target="$(boundary_0b_target "$ROOT" "$relative")"
    [[ -f "$target" ]] || boundary_0b_die "protected-file-missing|$relative|$target"
    printf 'PLAN|chattr|+i|%s\n' "$relative"
  done < <(boundary_0b_entries "$MANIFEST")
  printf 'DRY_RUN_OK|no-changes-made\n'
  exit 0
fi

# Complete preflight before the first mutation.  Baseline drift must never leave
# an avoidable partial application where earlier rows are immutable and a later
# row was rejected without invoking chattr.
preflight_failures=0
while IFS=$'\t' read -r relative expected_uid expected_gid expected_mode expected_attrs; do
  target="$(boundary_0b_target "$ROOT" "$relative")"
  if [[ ! -f "$target" ]]; then
    printf 'PREFLIGHT_FAILED|%s|reason=missing\n' "$relative"
    preflight_failures=$((preflight_failures + 1))
    continue
  fi
  actual_uid="$(stat -c '%u' -- "$target")"
  actual_gid="$(stat -c '%g' -- "$target")"
  actual_mode="$(stat -c '%a' -- "$target")"
  actual_attrs="$(boundary_0b_lsattr "$target")"
  if [[ "$actual_uid" != "$expected_uid" || "$actual_gid" != "$expected_gid" \
    || "$actual_mode" != "$expected_mode" \
    || "$(boundary_0b_attrs_without_immutable "$actual_attrs")" != "$(boundary_0b_attrs_without_immutable "$expected_attrs")" ]]; then
    printf 'PREFLIGHT_FAILED|%s|reason=baseline-drift|expected=%s:%s:%s:%s|actual=%s:%s:%s:%s\n' \
      "$relative" "$expected_uid" "$expected_gid" "$expected_mode" "$expected_attrs" \
      "$actual_uid" "$actual_gid" "$actual_mode" "$actual_attrs"
    preflight_failures=$((preflight_failures + 1))
  fi
done < <(boundary_0b_entries "$MANIFEST")

if (( preflight_failures > 0 )); then
  printf 'PREFLIGHT_SUMMARY|failed=%s|changes=0\n' "$preflight_failures"
  exit 1
fi
printf 'PREFLIGHT_OK|files=%s\n' "$(jq '.files | length' "$MANIFEST")"

failures=0
successes=0
while IFS=$'\t' read -r relative _expected_uid _expected_gid _expected_mode _expected_attrs; do
  target="$(boundary_0b_target "$ROOT" "$relative")"
  if ! "$CHATTR_BIN" +i -- "$target"; then
    printf 'APPLY_FAILED|%s|operation=chattr+i\n' "$relative"
    failures=$((failures + 1))
    continue
  fi
  actual_attrs="$(boundary_0b_lsattr "$target")"
  if [[ "$actual_attrs" != *i* ]]; then
    printf 'APPLY_FAILED|%s|operation=verify-immutable|actual=%s\n' "$relative" "$actual_attrs"
    failures=$((failures + 1))
  else
    printf 'APPLIED|%s|operation=chattr+i|lsattr=%s\n' "$relative" "$actual_attrs"
    successes=$((successes + 1))
  fi
done < <(boundary_0b_entries "$MANIFEST")

printf 'APPLY_SUMMARY|applied=%s|failed=%s\n' "$successes" "$failures"
(( failures == 0 ))

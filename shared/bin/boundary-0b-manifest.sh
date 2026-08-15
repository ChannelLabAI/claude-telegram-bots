#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/boundary-0b-common.sh
source "$SCRIPT_DIR/../lib/boundary-0b-common.sh"

ROOT="$(boundary_0b_repo_root)"
ROOT_EXPLICIT=0
MANIFEST=""
ACTION=""

usage() {
  cat >&2 <<'EOF'
Usage: boundary-0b-manifest.sh <--snapshot|--check> [--root DIR] [--manifest FILE]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot|--check)
      [[ -z "$ACTION" ]] || usage
      ACTION="$1"
      shift
      ;;
    --root) ROOT="${2:-}"; ROOT_EXPLICIT=1; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$ACTION" ]] || usage
ROOT="$(realpath -m -- "$ROOT")"
[[ -n "$MANIFEST" ]] || MANIFEST="$(boundary_0b_default_manifest "$ROOT")"
MANIFEST="$(realpath -m -- "$MANIFEST")"

# A committed snapshot describes the production root it was captured from.
# Default --check follows that root so a reviewer can run the versioned script
# from an isolated clone without requiring untracked nested .git hook files in
# that clone.  --root always wins, and mutating scripts never use this fallback.
if [[ "$ACTION" == "--check" && "$ROOT_EXPLICIT" -eq 0 && -f "$MANIFEST" ]]; then
  snapshot_root="$(jq -r '.snapshot_root // empty' "$MANIFEST" 2>/dev/null || true)"
  [[ -z "$snapshot_root" ]] || ROOT="$(realpath -m -- "$snapshot_root")"
fi

mapfile -t PROTECTED_PATHS < <(boundary_0b_expected_paths)

snapshot() {
  local entries='[]' relative target attrs stat_line uid gid owner group mode
  for relative in "${PROTECTED_PATHS[@]}"; do
    target="$(boundary_0b_target "$ROOT" "$relative")"
    [[ -f "$target" ]] || boundary_0b_die "protected-file-missing|$relative|$target"
    attrs="$(boundary_0b_lsattr "$target")"
    [[ -n "$attrs" ]] || boundary_0b_die "lsattr-failed|$relative"
    [[ "$attrs" != *i* ]] || boundary_0b_die "snapshot-refuses-existing-immutable|$relative|$attrs"
    stat_line="$(stat -c '%u|%g|%U|%G|%a' -- "$target")"
    IFS='|' read -r uid gid owner group mode <<< "$stat_line"
    entries="$(jq -c \
      --arg path "$relative" \
      --argjson uid "$uid" \
      --argjson gid "$gid" \
      --arg owner "$owner" \
      --arg group "$group" \
      --arg mode "$mode" \
      --arg lsattr "$attrs" \
      '. + [{path:$path,uid:$uid,gid:$gid,owner:$owner,group:$group,mode:$mode,lsattr:$lsattr}]' \
      <<< "$entries")"
    printf 'SNAPSHOT|%s|uid=%s|gid=%s|mode=%s|lsattr=%s\n' \
      "$relative" "$uid" "$gid" "$mode" "$attrs"
  done

  local manifest_dir tmp
  manifest_dir="$(dirname "$MANIFEST")"
  mkdir -p "$manifest_dir"
  tmp="$(mktemp "$manifest_dir/.boundary-0b-manifest.XXXXXX")"
  jq -n \
    --arg generated_at "$(date --iso-8601=seconds)" \
    --arg snapshot_root "$ROOT" \
    --argjson files "$entries" \
    '{schema_version:1,generated_at:$generated_at,snapshot_root:$snapshot_root,risk_class:"tripwire-and-friction",files:$files}' \
    > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MANIFEST"
  printf 'SNAPSHOT_OK|manifest=%s|files=%s\n' "$MANIFEST" "${#PROTECTED_PATHS[@]}"
}

check() {
  boundary_0b_validate_manifest "$MANIFEST"
  local failures=0 relative expected_uid expected_gid expected_mode expected_attrs
  local target actual_uid actual_gid actual_mode actual_attrs
  while IFS=$'\t' read -r relative expected_uid expected_gid expected_mode expected_attrs; do
    target="$(boundary_0b_target "$ROOT" "$relative")"
    if [[ ! -f "$target" ]]; then
      printf 'DIFF|%s|field=existence|expected=file|actual=missing\n' "$relative"
      failures=$((failures + 1))
      continue
    fi
    actual_uid="$(stat -c '%u' -- "$target")"
    actual_gid="$(stat -c '%g' -- "$target")"
    actual_mode="$(stat -c '%a' -- "$target")"
    actual_attrs="$(boundary_0b_lsattr "$target")"
    if [[ "$actual_uid" != "$expected_uid" ]]; then
      printf 'DIFF|%s|field=uid|expected=%s|actual=%s\n' "$relative" "$expected_uid" "$actual_uid"
      failures=$((failures + 1))
    fi
    if [[ "$actual_gid" != "$expected_gid" ]]; then
      printf 'DIFF|%s|field=gid|expected=%s|actual=%s\n' "$relative" "$expected_gid" "$actual_gid"
      failures=$((failures + 1))
    fi
    if [[ "$actual_mode" != "$expected_mode" ]]; then
      printf 'DIFF|%s|field=mode|expected=%s|actual=%s\n' "$relative" "$expected_mode" "$actual_mode"
      failures=$((failures + 1))
    fi
    if [[ "$actual_attrs" != "$expected_attrs" ]]; then
      printf 'DIFF|%s|field=lsattr|expected=%s|actual=%s\n' "$relative" "$expected_attrs" "$actual_attrs"
      failures=$((failures + 1))
    fi
    if [[ "$actual_uid" == "$expected_uid" && "$actual_gid" == "$expected_gid" \
      && "$actual_mode" == "$expected_mode" && "$actual_attrs" == "$expected_attrs" ]]; then
      printf 'OK|%s|uid=%s|gid=%s|mode=%s|lsattr=%s\n' \
        "$relative" "$actual_uid" "$actual_gid" "$actual_mode" "$actual_attrs"
    fi
  done < <(boundary_0b_entries "$MANIFEST")

  if (( failures > 0 )); then
    printf 'CHECK_FAILED|manifest=%s|differences=%s\n' "$MANIFEST" "$failures"
    return 1
  fi
  printf 'CHECK_OK|manifest=%s|files=%s\n' "$MANIFEST" "$(jq '.files | length' "$MANIFEST")"
}

case "$ACTION" in
  --snapshot) snapshot ;;
  --check) check ;;
esac

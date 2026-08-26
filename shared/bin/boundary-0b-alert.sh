#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/boundary-0b-common.sh
source "$SCRIPT_DIR/../lib/boundary-0b-common.sh"

ROOT="$(boundary_0b_repo_root)"
MANIFEST=""

usage() {
  cat >&2 <<'EOF'
Usage: boundary-0b-alert.sh [--root DIR] [--manifest FILE]

Production defaults to shared/scripts/alert_notify.py -> relay -> Anya Telegram.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

ROOT="$(realpath -m -- "$ROOT")"
[[ -n "$MANIFEST" ]] || MANIFEST="$(boundary_0b_default_manifest "$ROOT")"
MANIFEST="$(realpath -m -- "$MANIFEST")"
boundary_0b_validate_manifest "$MANIFEST"

issues=()
while IFS=$'\t' read -r relative expected_uid expected_gid expected_mode _expected_attrs; do
  if ! target="$(boundary_0b_target "$ROOT" "$relative")"; then
    issues+=("$relative:path-resolution-failed")
    printf 'ALERT|%s|field=path-resolution|expected=safe-file|actual=invalid\n' "$relative"
    continue
  fi
  if [[ ! -f "$target" ]]; then
    issue="$relative:missing"
    issues+=("$issue")
    printf 'ALERT|%s|field=existence|expected=file|actual=missing\n' "$relative"
    continue
  fi
  actual_uid=""; actual_gid=""; actual_mode=""; actual_attrs=""
  if ! actual_uid="$(stat -c '%u' -- "$target")"; then
    issues+=("$relative:uid-read-failed")
    printf 'ALERT|%s|field=uid-read|expected=readable|actual=failed\n' "$relative"
  fi
  if ! actual_gid="$(stat -c '%g' -- "$target")"; then
    issues+=("$relative:gid-read-failed")
    printf 'ALERT|%s|field=gid-read|expected=readable|actual=failed\n' "$relative"
  fi
  if ! actual_mode="$(stat -c '%a' -- "$target")"; then
    issues+=("$relative:mode-read-failed")
    printf 'ALERT|%s|field=mode-read|expected=readable|actual=failed\n' "$relative"
  fi
  if ! actual_attrs="$(boundary_0b_lsattr "$target")" || [[ -z "$actual_attrs" ]]; then
    issues+=("$relative:lsattr-read-failed")
    printf 'ALERT|%s|field=lsattr-read|expected=readable|actual=failed\n' "$relative"
  fi
  if [[ -n "$actual_attrs" && "$actual_attrs" != *i* ]]; then
    issues+=("$relative:immutable-missing")
    printf 'ALERT|%s|field=immutable|expected=present|actual=%s\n' "$relative" "$actual_attrs"
  fi
  if [[ -n "$actual_uid" && "$actual_uid" != "$expected_uid" ]]; then
    issues+=("$relative:uid:$actual_uid")
    printf 'ALERT|%s|field=uid|expected=%s|actual=%s\n' "$relative" "$expected_uid" "$actual_uid"
  fi
  if [[ -n "$actual_gid" && "$actual_gid" != "$expected_gid" ]]; then
    issues+=("$relative:gid:$actual_gid")
    printf 'ALERT|%s|field=gid|expected=%s|actual=%s\n' "$relative" "$expected_gid" "$actual_gid"
  fi
  if [[ -n "$actual_mode" && "$actual_mode" != "$expected_mode" ]]; then
    issues+=("$relative:mode:$actual_mode")
    printf 'ALERT|%s|field=mode|expected=%s|actual=%s\n' "$relative" "$expected_mode" "$actual_mode"
  fi
done < <(boundary_0b_entries "$MANIFEST")

if (( ${#issues[@]} == 0 )); then
  printf 'BARRIER_OK|files=%s\n' "$(jq '.files | length' "$MANIFEST")"
  exit 0
fi

message="[boundary-0b] write-barrier tripwire fired: ${#issues[@]} issue(s): $(IFS=,; printf '%s' "${issues[*]}")"
if python3 - "$ROOT" "$message" <<'PY'
import sys

root, message = sys.argv[1], sys.argv[2]
sys.path.insert(0, f"{root}/shared/scripts")
from alert_notify import relay_notify

raise SystemExit(0 if relay_notify(message, "boundary-0b-alert") else 1)
PY
then
  printf 'NOTIFY_OK|route=alert_notify.py:relay_notify|issues=%s\n' "${#issues[@]}"
  exit 1
fi
printf 'NOTIFY_FAILED|route=alert_notify.py:relay_notify|issues=%s\n' "${#issues[@]}" >&2
exit 2

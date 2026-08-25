#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
phase1="$repo_root/shared/customer-env/phase1"
denylist="$phase1/internal-identifiers.txt"
distribution="${1:-}"
scan_tmp=""
state_tmp="$(mktemp -d)"

cleanup() {
  [[ -z "$scan_tmp" ]] || rm -rf -- "$scan_tmp"
  rm -rf -- "$state_tmp"
}
trap cleanup EXIT

if [[ -z "$distribution" ]]; then
  source_root="${CUSTOMER_MVP_SOURCE:-$repo_root/mvp}"
  [[ -f "$source_root/mvp-server.ts" ]] || source_root="/home/oldrabbit/.claude-bots/mvp"
  scan_tmp="$(mktemp -d)"
  bash "$phase1/build-customer-release.sh" "$source_root" "$scan_tmp/build" >/dev/null
  distribution="$scan_tmp/build/release"
fi

distribution="$(realpath -e "$distribution")"
[[ -d "$distribution" ]] || { echo "CUSTOMER_BUNDLE_SCAN_NOT_DIRECTORY=$distribution" >&2; exit 2; }
[[ -s "$denylist" ]] || { echo "CUSTOMER_BUNDLE_SCAN_DENYLIST_MISSING=$denylist" >&2; exit 2; }

sort -u "$phase1/customer-distribution-allowlist.txt" > "$state_tmp/expected-files.txt"
find "$distribution" -type f -printf '%P\n' | sort > "$state_tmp/actual-files.txt"
if ! diff -u "$state_tmp/expected-files.txt" "$state_tmp/actual-files.txt"; then
  echo "CUSTOMER_BUNDLE_SCAN_INCOMPLETE=1" >&2
  exit 2
fi

hits=0
while IFS= read -r token; do
  [[ -z "$token" || "$token" == \#* ]] && continue
  while IFS= read -r -d '' file; do
    while IFS= read -r match; do
      [[ -n "$match" ]] || continue
      printf 'INTERNAL_IDENTIFIER token=%q file=%q line=%s\n' "$token" "${file#"$distribution"/}" "${match%%:*}"
      hits=$((hits + 1))
    done < <(grep -aFn -- "$token" "$file" || true)
  done < <(find "$distribution" -type f -print0 | sort -z)
done < "$denylist"

if (( hits > 0 )); then
  echo "CUSTOMER_BUNDLE_INTERNAL_IDENTIFIER_HITS=$hits"
  exit 1
fi
echo "CUSTOMER_BUNDLE_INTERNAL_IDENTIFIER_HITS=0"

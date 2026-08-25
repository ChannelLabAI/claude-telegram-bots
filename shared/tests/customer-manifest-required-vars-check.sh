#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHASE1="$ROOT/shared/customer-env/phase1"
POLICY="$PHASE1/customer-env-var-policy.json"
TMP=""
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"' EXIT

if [[ -n "${CUSTOMER_MANIFEST_UNDER_TEST:-}" ]]; then
  manifest="$(realpath -e "$CUSTOMER_MANIFEST_UNDER_TEST")"
else
  source_root="$(realpath -e "${CUSTOMER_MVP_SOURCE:-$ROOT/mvp}")"
  TMP="$(mktemp -d)"
  prepared_source="$TMP/prepared-source"
  manifest="$TMP/env-manifest.json"
  bun "$PHASE1/prepare-customer-source.ts" "$source_root" \
    "$PHASE1/customer-source-allowlist.txt" "$prepared_source"
  bun "$PHASE1/generate-env-manifest.ts" "$prepared_source" \
    "$PHASE1/customer-source-allowlist.txt" "$manifest" "$TMP/customer.env.template"
fi

required_count="$(jq '.required | length' "$manifest")"
echo "CUSTOMER_MANIFEST_REQUIRED_COUNT=$required_count"

mapfile -t violations < <(jq -r --slurpfile policy "$POLICY" '
  ($policy[0].non_required | to_entries
    | map(.key as $class | .value.variables[] | {name: .name, class: $class})) as $blocked
  | [.required[].name] as $required
  | $blocked[]
  | select(.name as $name | $required | index($name))
  | "FORBIDDEN_REQUIRED=\(.name) class=\(.class)"
' "$manifest")

if ((${#violations[@]})); then
  printf '%s\n' "${violations[@]}"
  echo "CUSTOMER_MANIFEST_REQUIRED_VARS_CHECK=FAIL count=${#violations[@]}" >&2
  exit 1
fi

echo "CUSTOMER_MANIFEST_REQUIRED_VARS_CHECK=PASS"

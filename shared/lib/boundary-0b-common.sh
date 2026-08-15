#!/usr/bin/env bash

# Shared, side-effect-free helpers for the Phase 0B write-barrier scripts.

boundary_0b_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
}

boundary_0b_default_manifest() {
  printf '%s/shared/config/boundary-0b-manifest.json\n' "$1"
}

boundary_0b_die() {
  printf 'ERROR|%s\n' "$*" >&2
  exit 2
}

boundary_0b_expected_paths() {
  printf '%s\n' \
    shared/bin/fatq-cli.sh \
    shared/bin/fatq-deploy-gate.sh \
    pod-system/gateway.ts \
    mvp/.git/config \
    mvp/.git/hooks/reference-transaction
}

boundary_0b_validate_manifest() {
  local manifest="$1" expected_paths
  [[ -f "$manifest" ]] || boundary_0b_die "manifest-not-found|$manifest"
  expected_paths="$(boundary_0b_expected_paths | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -e --argjson expected_paths "$expected_paths" '
    .schema_version == 1
    and .risk_class == "tripwire-and-friction"
    and (.files | type == "array" and length > 0)
    and ([.files[].path] | unique | length) == (.files | length)
    and (([.files[].path] | sort) == ($expected_paths | sort))
    and all(.files[];
      (.path | type == "string" and test("^[A-Za-z0-9._/-]+$") and (startswith("/") | not))
      and (.uid | type == "number" and . >= 0)
      and (.gid | type == "number" and . >= 0)
      and (.owner | type == "string" and length > 0)
      and (.group | type == "string" and length > 0)
      and (.mode | type == "string" and test("^[0-7]{3,4}$"))
      and (.lsattr | type == "string" and length > 0)
    )
  ' "$manifest" >/dev/null || boundary_0b_die "invalid-manifest|$manifest"
}

boundary_0b_target() {
  local root="$1" relative="$2" root_real target
  [[ "$relative" != /* ]] || boundary_0b_die "absolute-path-rejected|$relative"
  case "/$relative/" in
    */../*|*/./*) boundary_0b_die "path-traversal-rejected|$relative" ;;
  esac
  root_real="$(realpath -m -- "$root")"
  target="$(realpath -m -- "$root/$relative")"
  case "$target" in
    "$root_real"/*) ;;
    *) boundary_0b_die "path-outside-root|$relative|$target" ;;
  esac
  [[ ! -L "$root/$relative" ]] || boundary_0b_die "symlink-rejected|$relative"
  printf '%s\n' "$target"
}

boundary_0b_lsattr() {
  local target="$1" lsattr_bin="${BOUNDARY_0B_LSATTR_BIN:-lsattr}"
  "$lsattr_bin" -d -- "$target" 2>/dev/null | awk 'NR == 1 {print $1}'
}

boundary_0b_attrs_without_immutable() {
  printf '%s' "$1" | tr 'i' '-'
}

boundary_0b_entries() {
  jq -r '.files[] | [.path, (.uid|tostring), (.gid|tostring), .mode, .lsattr] | @tsv' "$1"
}

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUN_BIN="${KB_GUARD_BUN_BIN:-/home/oldrabbit/.bun/bin/bun}"
[[ -x "$BUN_BIN" ]] || { echo "kb-guard: bun is not executable at $BUN_BIN" >&2; exit 127; }
exec "$BUN_BIN" "$SCRIPT_DIR/kb-guard.ts" "$@"

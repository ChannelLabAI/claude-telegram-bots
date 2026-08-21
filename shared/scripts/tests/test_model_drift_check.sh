#!/usr/bin/env bash
# Three-source fixtures: consistent, one missing source, and contradiction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${MODEL_DRIFT_CHECK:-$SCRIPT_DIR/../../bin/model-drift-check.sh}"
RESOLVER="${MODEL_RESOLVE_SHIM:-$SCRIPT_DIR/../../bin/model-resolve.sh}"
GATEWAY="${MODEL_GATEWAY_TS:?MODEL_GATEWAY_TS must point to the patched gateway.ts}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/pods"

cat > "$FIX/pods/fleet.json" <<'JSON'
{"bots":[
  {"name":"twinkle","dir":"/bots/twinkle","model":"claude-opus-5"},
  {"name":"bella","dir":"/bots/bella","model":"claude-sonnet-5"},
  {"name":"sara","dir":"/bots/sara","engine":"codex","codexModel":"gpt-5.6-sol"}
]}
JSON

write_router() {
  local twinkle="$1" include_bella="$2"
  {
    printf '%s\n' 'models:' '  claude-opus-5: claude-opus-5' '  claude-sonnet: claude-sonnet-5' 'bot_defaults:'
    printf '  twinkle: %s\n' "$twinkle"
    [[ "$include_bella" == yes ]] && printf '%s\n' '  bella: claude-sonnet'
    printf '%s\n' '  _default: claude-sonnet' 'codex:' '  bot_defaults:' '    sara: sol'
  } > "$FIX/router.yml"
}

run_check() {
  MODEL_PODS_DIR="$FIX/pods" \
  MODEL_ROUTER_YML="$FIX/router.yml" \
  MODEL_GATEWAY_TS="$GATEWAY" \
  MODEL_RESOLVE_SHIM="$RESOLVER" \
    "$CHECK"
}

echo "=== all three sources consistent ==="
write_router claude-opus-5 yes
run_check >"$FIX/out" 2>"$FIX/err"
grep -q 'PASS bots=2' "$FIX/out"
[[ ! -s "$FIX/err" ]]
echo "  ✓ consistent exits 0"

echo "=== one source missing ==="
write_router claude-opus-5 no
if run_check >"$FIX/out" 2>"$FIX/err"; then
  echo "  ✗ missing router item unexpectedly passed"
  exit 1
fi
grep -q 'DRIFT bot=bella pod=claude-sonnet-5 model-router=<missing> gateway=claude-sonnet-5' "$FIX/err"
echo "  ✓ missing source names bella and both compared sources"

echo "=== sources contradict ==="
write_router claude-sonnet yes
if run_check >"$FIX/out" 2>"$FIX/err"; then
  echo "  ✗ contradictory router item unexpectedly passed"
  exit 1
fi
grep -q 'DRIFT bot=twinkle pod=claude-opus-5 model-router=claude-sonnet-5 gateway=claude-opus-5' "$FIX/err"
echo "  ✓ contradiction names twinkle and all source values"

echo "model drift fixtures passed"

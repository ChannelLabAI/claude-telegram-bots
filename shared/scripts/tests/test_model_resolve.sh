#!/usr/bin/env bash
# Isolated coverage for pod-primary resolution and loud fail-safe fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="${MODEL_RESOLVE_SHIM:-$SCRIPT_DIR/../../bin/model-resolve.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/pods"

cat > "$FIX/pods/fleet.json" <<'JSON'
{"bots":[
  {"name":"anya","dir":"/bots/anya","model":"claude-opus-5"},
  {"name":"huizhang","dir":"/bots/33-huizhang","model":"claude-opus-5"},
  {"name":"zhuchu","dir":"/bots/caijie-zhuchu","model":"claude-opus-5"},
  {"name":"twinkle","dir":"/bots/twinkle","model":"claude-opus-5"},
  {"name":"bella","dir":"/bots/bella","model":"claude-sonnet-5"},
  {"name":"sara","dir":"/bots/sara","engine":"codex","codexModel":"gpt-5.6-sol"}
]}
JSON

cat > "$FIX/router.yml" <<'YML'
models:
  claude-opus-5: claude-opus-5
  claude-sonnet: claude-sonnet-5
bot_defaults:
  anya: claude-opus-5
  huizhang: claude-opus-5
  zhuchu: claude-opus-5
  twinkle: claude-opus-5
  bella: claude-sonnet
  _default: claude-sonnet
codex:
  bot_defaults:
    anna: sol
YML

PASS=0
FAIL=0
check_primary() {
  local bot="$1" expected="$2" out err
  err="$FIX/stderr"
  out="$(MODEL_PODS_DIR="$FIX/pods" MODEL_ROUTER_YML="$FIX/router.yml" "$SHIM" "$bot" 2>"$err")"
  if [[ "$out" == "$expected" && ! -s "$err" && "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]]; then
    printf '  ✓ primary %s -> %s\n' "$bot" "$out"
    PASS=$((PASS + 1))
  else
    printf '  ✗ primary %s out=%q stderr=%q\n' "$bot" "$out" "$(<"$err")"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== pod source of truth and stdout contract ==="
check_primary anya claude-opus-5
check_primary huizhang claude-opus-5
check_primary zhuchu claude-opus-5
check_primary twinkle claude-opus-5
check_primary bella claude-sonnet-5
check_primary 33-huizhang claude-opus-5
check_primary caijie-zhuchu claude-opus-5

echo "=== missing bot remains usable but visibly guessed ==="
out="$(MODEL_PODS_DIR="$FIX/pods" MODEL_ROUTER_YML="$FIX/router.yml" "$SHIM" unknown-bot 2>"$FIX/stderr")"
if [[ "$out" == "claude-sonnet-5" ]] && grep -q 'FALLBACK source=model-router bot=unknown-bot' "$FIX/stderr"; then
  echo "  ✓ router fallback is loud and stdout stays a model ID"
  PASS=$((PASS + 1))
else
  echo "  ✗ router fallback out=$out stderr=$(<"$FIX/stderr")"
  FAIL=$((FAIL + 1))
fi

echo "=== corrupt sources preserve final fail-safe with a distinct signal ==="
printf '%s\n' 'not-json' > "$FIX/pods/fleet.json"
printf '%s\n' 'not: [valid' > "$FIX/router.yml"
out="$(MODEL_PODS_DIR="$FIX/pods" MODEL_ROUTER_YML="$FIX/router.yml" "$SHIM" anya 2>"$FIX/stderr")"
if [[ "$out" == "claude-sonnet-5" ]] && grep -q 'FALLBACK source=hardcoded-default bot=anya' "$FIX/stderr"; then
  echo "  ✓ hardcoded fallback is useful and distinguishable"
  PASS=$((PASS + 1))
else
  echo "  ✗ hardcoded fallback out=$out stderr=$(<"$FIX/stderr")"
  FAIL=$((FAIL + 1))
fi

echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]

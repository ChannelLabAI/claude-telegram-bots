#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/shared/scripts/owner-delivery-zero-receipt-alert.ts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/pod-system" "$TMP/relay" "$TMP/state" "$TMP/home/.claude-bots/relay"
MORNING_BEFORE="$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)"
cat >"$TMP/team-config.json" <<'JSON'
{"assistants":[
  {"role":"特助","bot_username":"a_bot","state_dir":"alpha"},
  {"role":"特助","bot_username":"b_bot","state_dir":"beta"},
  {"role":"company-agent","bot_username":null,"state_dir":"keeper"}
]}
JSON
cat >"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-27T01:02:00.000Z] task #1 relay output routed via owner_escalation
LOG
# beta deliberately has no gateway log: a renamed/missing pod must alert rather
# than fall out of monitoring silently.

HOME="$TMP/home" env OWNER_DELIVERY_TEAM_CONFIG="$TMP/team-config.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T01:30:00.000Z" bun "$SCRIPT"
test -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-beta.json"
test ! -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-alpha.json"
test "$(find "$TMP/relay" -maxdepth 1 -type f | wc -l)" -eq 1

# A deleted assistant mapping must not make the already observed pod fall out
# of the expected set.  This is the 0254 missing-mapping guard's silent-skip
# path: alpha is healthy, beta has vanished from current team-config, and beta
# must still produce a next-day alert.
cat >"$TMP/team-config.json" <<'JSON'
{"assistants":[{"role":"特助","bot_username":"a_bot","state_dir":"alpha"}]}
JSON
cat >>"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-28T01:02:00.000Z] task #2 relay output routed via owner_escalation
LOG
HOME="$TMP/home" env OWNER_DELIVERY_TEAM_CONFIG="$TMP/team-config.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-28T01:30:00.000Z" bun "$SCRIPT"
test -f "$TMP/relay/2026-07-28-diana-crit-owner-delivery-zero-beta.json"
test ! -f "$TMP/relay/2026-07-28-diana-crit-owner-delivery-zero-alpha.json"
# Same date/pod is a single fact: rerunning must not emit a second alert.
HOME="$TMP/home" env OWNER_DELIVERY_TEAM_CONFIG="$TMP/team-config.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T03:00:00.000Z" bun "$SCRIPT"
test "$(find "$TMP/relay" -maxdepth 1 -type f | wc -l)" -eq 2

# Negative proof: if the alert branch is disabled, the fixture must fail.
rm -rf "$TMP/relay" "$TMP/state"
mkdir -p "$TMP/relay" "$TMP/state"
# Rebuild a genuinely missing receipt after clearing prior roster state.  The
# injected failure must execute the alert branch, rather than passing because
# the test data accidentally has no missing pods.
cat >"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-28T01:02:00.000Z] task #2 relay output routed via owner_escalation
LOG
if HOME="$TMP/home" env OWNER_DELIVERY_INJECT_BROKEN=1 OWNER_DELIVERY_TEAM_CONFIG="$TMP/team-config.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T01:30:00.000Z" bun "$SCRIPT"; then
  echo "negative proof unexpectedly passed" >&2
  exit 1
fi
test "$MORNING_BEFORE" -eq "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)"
echo "owner-delivery zero-receipt fixture: PASS"

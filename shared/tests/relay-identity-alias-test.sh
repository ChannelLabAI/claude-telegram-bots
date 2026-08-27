#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER="$ROOT/shared/server.patched.ts"
CONFIG="$ROOT/shared/config/relay-consumed-readers.json"
VERIFY="$ROOT/shared/bin/relay-identity-alias-verify.sh"
STRANDED="${RELAY_IDENTITY_STRANDED_FILE:-$ROOT/shared/tests/fixtures/relay-identity-alias-stranded-envelopes.md}"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

extract_helpers() {
  local source="$1" destination="$2"
  {
    echo "import { readFileSync } from 'fs'"
    awk '/RELAY_IDENTITY_HELPERS_BEGIN/{inside=1; next} /RELAY_IDENTITY_HELPERS_END/{inside=0} inside' "$source"
  } > "$destination"
}

write_behavior_runner() {
  local helper="$1" runner="$2"
  cp "$helper" "$runner"
  cat >> "$runner" <<'TYPESCRIPT'
function expectDecision(label: string, actual: RelayDecision, expected: RelayDecision): void {
  if (actual !== expected) {
    console.error(`FAIL ${label}: expected=${expected} actual=${actual}`)
    process.exit(1)
  }
  console.log(`PASS ${label} decision=${actual}`)
}
const config = process.argv[2]
const diana = loadRelayIdentityAliases(config, 'DianaAI_v2_bot', 'diana', 'keeper')
const anya = loadRelayIdentityAliases(config, 'Anyachl_bot', 'anya', '')
expectDecision('AC1 keeper recipient', relayEnvelopeDecision({recipient: 'KEEPER', text: 'no mention'}, diana), 'addressed')
expectDecision('AC2 directory mention', relayEnvelopeDecision({text: 'patrol for @AnYa'}, anya), 'mentioned')
expectDecision('AC3 foreign recipient', relayEnvelopeDecision({recipient: 'bella', text: 'no mention'}, anya), 'ignored')
expectDecision('AC4 existing directory recipient', relayEnvelopeDecision({recipient: 'anya'}, anya), 'addressed')
expectDecision('AC4 existing TG mention', relayEnvelopeDecision({text: 'hello @Anyachl_bot'}, anya), 'mentioned')
expectDecision('AC5 self alias skip', relayEnvelopeDecision({from_bot: 'keeper', recipient: 'keeper'}, diana), 'skip-self')
TYPESCRIPT
}

extract_helpers "$SERVER" "$BASE/helpers.ts"
write_behavior_runner "$BASE/helpers.ts" "$BASE/behavior.ts"
bun "$BASE/behavior.ts" "$CONFIG" | tee "$BASE/behavior.out"

# Mutant proof: remove alias-based recipient matching. The keeper fixture must
# turn red, proving AC1 exercises the new addressed path rather than mention or
# unconditional receipt behavior.
sed "s/const addressed = recipient !== '' && selfAliases.has(recipient)/const addressed = false/" \
  "$BASE/helpers.ts" > "$BASE/helpers-mutant.ts"
write_behavior_runner "$BASE/helpers-mutant.ts" "$BASE/behavior-mutant.ts"
set +e
bun "$BASE/behavior-mutant.ts" "$CONFIG" > "$BASE/mutant.out" 2>&1
mutant_rc=$?
set -e
[[ "$mutant_rc" -ne 0 ]] || { echo 'FAIL mutant unexpectedly passed' >&2; exit 1; }
grep -F 'FAIL AC1 keeper recipient' "$BASE/mutant.out"
echo "PASS mutant keeper alias removal rejected exit=$mutant_rc"

BOT_ROSTER_BOTS_DIR="${BOT_ROSTER_BOTS_DIR:-/home/oldrabbit/.claude-bots/bots}" \
  bash "$ROOT/shared/tests/bot-roster-consistency-test.sh"

server_mtime="$(stat -c %Y "$SERVER")"
fresh_time=$((server_mtime + 5))
stale_time=$((server_mtime - 5))
cat > "$BASE/fresh-processes.json" <<EOF
[{"directory":"anya","pid":101,"start_epoch":$fresh_time},{"directory":"diana","pid":102,"start_epoch":$fresh_time}]
EOF
RELAY_IDENTITY_ROOT="$ROOT" \
RELAY_IDENTITY_PROCESS_SNAPSHOT="$BASE/fresh-processes.json" \
  bash "$VERIFY" | tee "$BASE/verify-green.out"

jq '(.readers[] | select(.directory == "diana") | .aliases) -= ["keeper"]' \
  "$CONFIG" > "$BASE/missing-keeper.json"
set +e
RELAY_IDENTITY_ROOT="$ROOT" \
RELAY_IDENTITY_CONFIG="$BASE/missing-keeper.json" \
RELAY_IDENTITY_PROCESS_SNAPSHOT="$BASE/fresh-processes.json" \
  bash "$VERIFY" > "$BASE/missing-keeper.out" 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" -ne 0 ]] || { echo 'FAIL missing-keeper fixture unexpectedly passed' >&2; exit 1; }
grep -F 'alias-missing directory=diana key=system_identity value=keeper' "$BASE/missing-keeper.out"
echo "PASS verifier rejects missing keeper exit=$missing_rc"

cat > "$BASE/stale-processes.json" <<EOF
[{"directory":"anya","pid":201,"start_epoch":$stale_time},{"directory":"diana","pid":202,"start_epoch":$fresh_time}]
EOF
set +e
RELAY_IDENTITY_ROOT="$ROOT" \
RELAY_IDENTITY_PROCESS_SNAPSHOT="$BASE/stale-processes.json" \
  bash "$VERIFY" > "$BASE/stale.out" 2>&1
stale_rc=$?
set -e
[[ "$stale_rc" -ne 0 ]] || { echo 'FAIL stale-process fixture unexpectedly passed' >&2; exit 1; }
grep -F 'process-stale directory=anya pid=201' "$BASE/stale.out"
echo "PASS verifier rejects stale resident process exit=$stale_rc"

[[ -r "$STRANDED" ]] || { echo "FAIL stranded inventory missing: $STRANDED" >&2; exit 1; }
mapfile -t inventory_rows < <(grep '^| `' "$STRANDED")
[[ "${#inventory_rows[@]}" -eq 17 ]] || {
  echo "FAIL stranded inventory expected 17 named rows, got ${#inventory_rows[@]}" >&2
  exit 1
}
while IFS= read -r expected_file; do
  grep -Fq "| \`$expected_file\` |" "$STRANDED" || {
    echo "FAIL stranded inventory missing file=$expected_file" >&2
    exit 1
  }
done <<'FILES'
fatq-20260827-1540-3ef7-relay-consumed-archiver-done-a2-completed-delivery.json
fatq-20260827-1540-3ef7-relay-consumed-archiver-rejected-r1-reject-notify.json
fatq-20260827-1540-3ef7-relay-consumed-archiver-rejected-r2-reject-notify.json
gateway-reply-20260724161456823-anya-f82f7961db04e.json
gateway-reply-20260726195757389-anya-36723e78794e68.json
gateway-reply-20260727160153371-anya-4c623f940ad5f8.json
gateway-reply-20260728160254912-anya-10e4d1c7865b8.json
gateway-reply-20260729160312457-anya-478032680b57e8.json
gateway-reply-20260730160337226-anya-2525b6c8059478.json
gateway-reply-20260731160256889-anya-65c59aeef93068.json
gateway-reply-20260801160333890-anya-3cf532728db288.json
gateway-reply-20260802160619596-anya-7131a3de89b7d8.json
gateway-reply-20260803160534625-anya-e19d9f215940a8.json
gateway-reply-20260804161827188-anya-2c9fb3f121e348.json
gateway-reply-20260805161145514-anya-66af4f0820afc8.json
roster-patrol-2026-08-26-anya.json
roster-patrol-2026-08-27-anya.json
FILES
[[ "$(grep -c 'Diana system identity `keeper`' "$STRANDED")" -eq 15 ]]
[[ "$(grep -c 'Anya directory identity `anya`' "$STRANDED")" -eq 2 ]]
echo 'PASS AC7 stranded inventory names all 17 envelopes with matching identity keys'

echo 'PASS relay-identity-alias suite'

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../bin/bot-identity-key-drift.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT

mkdir -p \
  "$FIXTURE/bots/alpha" "$FIXTURE/bots/beta" "$FIXTURE/bots/gamma" \
  "$FIXTURE/shared/lib" "$FIXTURE/shared/config" \
  "$FIXTURE/pod-system/hooks"

printf '%s\n' '#!/usr/bin/env bash' 'BOT_NAME="alpha-live"' > "$FIXTURE/bots/alpha/start.sh"
printf '%s\n' '#!/usr/bin/env bash' 'BOT_NAME="beta-live"' > "$FIXTURE/bots/beta/start.sh"
printf '%s\n' '#!/usr/bin/env bash' 'BOT_NAME="gamma-live"' > "$FIXTURE/bots/gamma/start.sh"
printf '%s\n' \
  'alpha-live:' \
  '  - cron: "0 1 * * *"' \
  '    prompt: alpha' \
  'beta:' \
  '  - cron: "0 2 * * *"' \
  '    prompt: stale-directory-key' \
  > "$FIXTURE/shared/lib/bot-crons.yml"
printf '%s\n' \
  '{"_comment":"directory subset","alpha":[],"ghost-dir":[]}' \
  > "$FIXTURE/pod-system/hooks/vault-map.json"
printf '%s\n' \
  'bot_roster:' \
  '  - id: alpha-assigned' \
  '    directory: alpha' \
  '  - id: beta-assigned' \
  '    directory: beta' \
  '  - id: gamma-assigned' \
  '    directory: gamma' \
  'builders: []' \
  > "$FIXTURE/shared/config/bot-routing.yml"
printf '%s\n' \
  'bot_defaults:' \
  '  alpha: claude-sonnet' \
  '  beta: claude-sonnet' \
  '  ghost-model: claude-sonnet' \
  '  _default: claude-sonnet' \
  'codex:' \
  '  bot_defaults:' \
  '    unrelated-nested-key: sol' \
  > "$FIXTURE/shared/config/model-router.yml"

set +e
output="$(BOT_IDENTITY_DRIFT_ROOT="$FIXTURE" "$CHECKER" 2>&1)"
rc=$?
set -e
printf '%s\n' "$output"
printf 'EXIT_CODE=%s\n' "$rc"

[[ "$rc" -ne 0 ]]
grep -Fq 'table=shared/lib/bot-crons.yml key_semantics=BOT_NAME type=orphan-key key=beta' <<< "$output"
grep -Fq 'table=shared/lib/bot-crons.yml key_semantics=BOT_NAME type=missing-key key=beta-live' <<< "$output"
grep -Fq 'table=shared/lib/bot-crons.yml key_semantics=BOT_NAME type=missing-key key=gamma-live' <<< "$output"
[[ "$(grep -Fc 'table=shared/lib/bot-crons.yml key_semantics=BOT_NAME type=missing-key key=beta-live' <<< "$output")" -eq 1 ]]
grep -Fq 'table=pod-system/hooks/vault-map.json key_semantics=DIRECTORY_NAME type=orphan-key key=ghost-dir' <<< "$output"
grep -Fq 'table=shared/config/model-router.yml key_semantics=DIRECTORY_NAME type=orphan-key key=ghost-model' <<< "$output"
! grep -Fq 'unrelated-nested-key' <<< "$output"
grep -Fq 'ASSERT table=shared/lib/bot-crons.yml completeness=full-coverage type=count-mismatch keys=2 expected_bot_names=3' <<< "$output"
grep -Fq 'BOT_IDENTITY_KEY_DRIFT FAIL findings=6' <<< "$output"

# Count-only regression: an obsolete empty declaration has no operational
# lookup payload and is deliberately not an orphan-key finding. The independent
# full-coverage cardinality assertion must still make the probe red by itself.
# Real ops: [] incident evidence: Bella's 2026-08-24T10:23:48 review comment.
printf '%s\n' \
  'alpha-live: []' \
  'beta-live: []' \
  'gamma-live: [] # inline role note remains part of the top-level record' \
  'retired-empty: []' \
  > "$FIXTURE/shared/lib/bot-crons.yml"
printf '%s\n' '{"_comment":"authorized subset","alpha":[]}' \
  > "$FIXTURE/pod-system/hooks/vault-map.json"
printf '%s\n' \
  'bot_defaults:' \
  '  alpha: claude-sonnet' \
  '  _default: claude-sonnet' \
  > "$FIXTURE/shared/config/model-router.yml"

set +e
count_output="$(BOT_IDENTITY_DRIFT_ROOT="$FIXTURE" "$CHECKER" 2>&1)"
count_rc=$?
set -e
printf '%s\n' "$count_output"
printf 'COUNT_ASSERT_EXIT_CODE=%s\n' "$count_rc"
[[ "$count_rc" -eq 1 ]]
grep -Fq 'ASSERT table=shared/lib/bot-crons.yml completeness=full-coverage type=count-mismatch keys=4 expected_bot_names=3' <<< "$count_output"
! grep -Fq 'DRIFT ' <<< "$count_output"
grep -Fq 'BOT_IDENTITY_KEY_DRIFT FAIL findings=1' <<< "$count_output"

# The second full-coverage table has the same independent assertion. Its
# existing reverse-difference also names the omitted directory.
printf '%s\n' \
  'alpha-live: []' \
  'beta-live: []' \
  'gamma-live: []' \
  > "$FIXTURE/shared/lib/bot-crons.yml"
printf '%s\n' \
  'bot_roster:' \
  '  - id: alpha-assigned' \
  '    directory: alpha' \
  '  - id: beta-assigned' \
  '    directory: beta' \
  'builders: []' \
  > "$FIXTURE/shared/config/bot-routing.yml"

set +e
routing_output="$(BOT_IDENTITY_DRIFT_ROOT="$FIXTURE" "$CHECKER" 2>&1)"
routing_rc=$?
set -e
printf '%s\n' "$routing_output"
printf 'ROUTING_COUNT_ASSERT_EXIT_CODE=%s\n' "$routing_rc"
[[ "$routing_rc" -eq 1 ]]
grep -Fq 'ASSERT table=shared/config/bot-routing.yml completeness=full-coverage type=count-mismatch linked_directories=2 expected_directories=3' <<< "$routing_output"
grep -Fq 'table=shared/config/bot-routing.yml key_semantics=FATQ_ASSIGNED type=missing-key key=gamma detail=directory-not-in-roster' <<< "$routing_output"

# Permanent replay of the real 33-huizhang incident shape: the BOT_NAME exists,
# but its entire cron block is absent and there is no orphan key to trace.
printf '%s\n' '#!/usr/bin/env bash' 'BOT_NAME="33-huizhang"' > "$FIXTURE/bots/gamma/start.sh"
printf '%s\n' \
  'alpha-live: []' \
  'beta-live: []' \
  > "$FIXTURE/shared/lib/bot-crons.yml"
printf '%s\n' \
  'bot_roster:' \
  '  - id: alpha-assigned' \
  '    directory: alpha' \
  '  - id: beta-assigned' \
  '    directory: beta' \
  '  - id: gamma-assigned' \
  '    directory: gamma' \
  'builders: []' \
  > "$FIXTURE/shared/config/bot-routing.yml"

set +e
huizhang_output="$(BOT_IDENTITY_DRIFT_ROOT="$FIXTURE" "$CHECKER" 2>&1)"
huizhang_rc=$?
set -e
printf '%s\n' "$huizhang_output"
printf 'HUIZHANG_REPLAY_EXIT_CODE=%s\n' "$huizhang_rc"
[[ "$huizhang_rc" -eq 1 ]]
grep -Fq 'table=shared/lib/bot-crons.yml key_semantics=BOT_NAME type=missing-key key=33-huizhang' <<< "$huizhang_output"
grep -Fq 'ASSERT table=shared/lib/bot-crons.yml completeness=full-coverage type=count-mismatch keys=2 expected_bot_names=3' <<< "$huizhang_output"
grep -Fq 'scan_tasks; scan_relays; scan_gateway; scan_event_pairs; scan_identity_drift; send_alert_once' "$SCRIPT_DIR/../bin/patrol-scan.sh"
grep -Fq 'timeout --signal=TERM --kill-after=2s 25s "$IDENTITY_DRIFT_CHECK"' "$SCRIPT_DIR/../bin/patrol-scan.sh"
printf '%s\n' 'PASS bot-identity-key-drift negative fixture'

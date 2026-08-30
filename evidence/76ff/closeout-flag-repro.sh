#!/usr/bin/env bash
set -uo pipefail

CLI_SH="${1:?usage: closeout-flag-repro.sh /path/to/fatq-cli.sh}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

export FATQ_ROOT="$fixture_root/tasks"
export FATQ_TEAM_CONFIG="$fixture_root/team-config.json"
export FATQ_RELAY_DIR="$fixture_root/relay"
export FATQ_DISPATCH_AFFINITY="$fixture_root/dispatch-affinity.json"
export FATQ_BOT_ROUTING="$fixture_root/bot-routing.yml"
mkdir -p "$FATQ_ROOT"/{done,pending,in_progress,review,rejected,cancelled,wont_do,approval_pending,archived,design,design_review,spec_review} "$FATQ_RELAY_DIR"

printf '%s\n' '{"assistants":[{"state_dir":"anya"}],"shared_pools":{"builder":[],"reviewer":[{"state_dir":"bella"}],"designer":[]},"external_identities":[]}' > "$FATQ_TEAM_CONFIG"
printf '%s\n' '{"infra_patterns":[],"lines":{"default":{"builder":"anna","reviewer":"bella"}}}' > "$FATQ_DISPATCH_AFFINITY"
printf '%s\n' 'bot_roster: []' > "$FATQ_BOT_ROUTING"
printf '%s\n' '{"task_id":"closeout-flag-repro","status":"done","reviewer":"bella","live_verify_commands":[],"closeout":{"state":"pending","host_effect_policy":"required_for_commits"},"history":[]}' > "$FATQ_ROOT/done/closeout-flag-repro.json"

set +e
output="$(bash "$CLI_SH" closeout closeout-flag-repro --as anya --state closed \
  --no-host-effect --live-check '{"verified_by":"bella","method":"reviewer-live","evidence":"must not disappear"}' 2>&1)"
rc=$?
set -e

printf 'CLI_OUTPUT=%s\n' "$output"
printf 'EXIT_CODE=%s\n' "$rc"
printf 'CLOSEOUT_JSON='
jq -c '.closeout' "$FATQ_ROOT/done/closeout-flag-repro.json"

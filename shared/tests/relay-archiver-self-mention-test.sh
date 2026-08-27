#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
archiver="$repo/shared/bin/relay-consumed-archiver.sh"
readers_config="$repo/shared/config/relay-consumed-readers.json"
fixture="$(mktemp -d /tmp/relay-archiver-self-mention.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

passed=0
failed=0

run_case() {
  local name="$1" envelope="$2" marker="$3" expected="$4"
  local root="$fixture/$name" output
  mkdir -p "$root/relay/read"
  printf '%s\n' "$envelope" > "$root/relay/$name.json"
  : > "$root/relay/$name.json.read-by-$marker"

  output="$(
    RELAY_ARCHIVER_RELAY_DIR="$root/relay" \
    RELAY_ARCHIVER_READ_DIR="$root/relay/read" \
    RELAY_ARCHIVER_LOCK_FILE="$root/archiver.lock" \
    RELAY_ARCHIVER_READERS_CONFIG="$readers_config" \
      "$archiver" --dry-run
  )"

  if grep -F "$expected" <<<"$output" >/dev/null; then
    echo "PASS $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name expected=$expected"
    echo "  actual=$output"
    failed=$((failed + 1))
  fi
}

# AC1: a sender mention cannot require the marker that the consumer's
# skip-self rule deliberately never creates.
run_case \
  self-mention \
  '{"from_bot":"diana","recipient":"anya","text":"handoff @Anyachl_bot; sender identity @DianaAI_v2_bot"}' \
  Anyachl_bot \
  'ARCHIVE-DRY-RUN file=self-mention.json'

# AC2: a non-sender mention remains a real fan-out reader requirement.
run_case \
  fan-out \
  '{"from_bot":"laotu","recipient":"diana","text":"please include @Anyachl_bot"}' \
  DianaAI_v2_bot \
  'SKIP file=fan-out.json reason=reader-pending reader=Anyachl_bot'

# AC3: bot-shaped unknown mentions still fail closed.
run_case \
  mention-unmapped \
  '{"from_bot":"laotu","recipient":"anya","text":"please include @SomeUnknown_bot"}' \
  Anyachl_bot \
  'SKIP file=mention-unmapped.json reason=mention-unmapped mention=@SomeUnknown_bot'

echo "RESULT passed=$passed failed=$failed"
[[ "$failed" -eq 0 ]]

#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HELPER="$ROOT/shared/lib/boot-relay.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
export BOOT_RELAY_CLEANUP_SECONDS=0
export BOOT_RELAY_KEEP_FILES=1
mkdir -p "$HOME/.claude-bots/shared/lib" "$HOME/.claude-bots/bots/anya" "$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-anya" "$FIX/relay"

cp "$HELPER" "$HOME/.claude-bots/shared/lib/boot-relay.sh"
cat > "$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh" <<'EOF'
#!/usr/bin/env bash
printf '\n\n---\nCRON_INIT_FOR_%s\n---\n' "$1"
EOF
chmod +x "$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh"

source "$HOME/.claude-bots/shared/lib/boot-relay.sh"

assert_contains() {
  local file="$1" needle="$2"
  python3 - "$file" "$needle" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    text = json.load(f)["text"]
if sys.argv[2] not in text:
    raise SystemExit(f"missing {sys.argv[2]!r} in {text!r}")
PY
}

assert_not_contains() {
  local file="$1" needle="$2"
  python3 - "$file" "$needle" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    text = json.load(f)["text"]
if sys.argv[2] in text:
    raise SystemExit(f"unexpected {sys.argv[2]!r} in {text!r}")
PY
}

latest_relay() {
  find "$FIX/relay" -maxdepth 1 -type f -name 'boot-anya-*.json' -printf '%T@\t%p\n' | sort -n | tail -1 | cut -f2-
}

# Same Claude session: second boot gets wake text only, no cron-init.
: > "$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-anya/session-a.jsonl"
send_boot_relay anya Anyachl_bot $$ "$FIX/relay" "$HOME/.claude-bots/bots/anya"
first="$(latest_relay)"
assert_contains "$first" "CRON_INIT_FOR_anya"

send_boot_relay anya Anyachl_bot $$ "$FIX/relay" "$HOME/.claude-bots/bots/anya"
second="$(latest_relay)"
assert_not_contains "$second" "CRON_INIT_FOR_anya"
assert_contains "$second" "@Anyachl_bot 啟動自我檢視"

# New Claude session transcript: cron-init is sent again.
sleep 1
: > "$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-anya/session-b.jsonl"
send_boot_relay anya Anyachl_bot $$ "$FIX/relay" "$HOME/.claude-bots/bots/anya"
third="$(latest_relay)"
assert_contains "$third" "CRON_INIT_FOR_anya"

echo "PASS boot-relay-dedup-fixture"

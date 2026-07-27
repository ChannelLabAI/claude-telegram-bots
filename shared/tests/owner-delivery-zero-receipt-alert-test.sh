#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/shared/scripts/owner-delivery-zero-receipt-alert.ts"
PRODUCER="$ROOT/shared/bin/morning-todo-all.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/pod-system" "$TMP/relay" "$TMP/state" "$TMP/home/.claude-bots/relay"
MORNING_BEFORE="$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)"
cat >"$TMP/morning-owner-delivery-roster.json" <<'JSON'
{"pods":[
  {"bot_username":"a_bot","state_dir":"alpha","vault_dir":"Alpha","journal_file":"日誌總結.md"},
  {"bot_username":"b_bot","state_dir":"beta","vault_dir":"Beta","journal_file":"日誌總結.md"}
]}
JSON
cat >"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-27T01:02:00.000Z] task #1 relay output routed via owner_escalation
LOG
# beta deliberately has no gateway log: a renamed/missing pod must alert rather
# than fall out of monitoring silently.

HOME="$TMP/home" env OWNER_DELIVERY_ROSTER="$TMP/morning-owner-delivery-roster.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T01:30:00.000Z" bun "$SCRIPT"
test -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-beta.json"
test ! -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-alpha.json"
test ! -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-outsider.json"
test "$(find "$TMP/relay" -maxdepth 1 -type f | wc -l)" -eq 1

# The producer and monitor both consume this same roster file. Adding gamma
# therefore changes the monitor's expected set without touching team-config;
# gamma has a receipt and an out-of-roster pod never gains a CRIT.
cat >"$TMP/morning-owner-delivery-roster.json" <<'JSON'
{"pods":[
  {"bot_username":"a_bot","state_dir":"alpha","vault_dir":"Alpha","journal_file":"日誌總結.md"},
  {"bot_username":"b_bot","state_dir":"beta","vault_dir":"Beta","journal_file":"日誌總結.md"},
  {"bot_username":"g_bot","state_dir":"gamma","vault_dir":"Gamma","journal_file":"日誌總結.md"}
]}
JSON
cat >>"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-27T01:03:00.000Z] task #2 relay output routed via owner_escalation
LOG
cat >"$TMP/pod-system/gateway-assist-gamma.log" <<'LOG'
[2026-07-27T01:03:00.000Z] task #3 relay output routed via owner_escalation
LOG
HOME="$TMP/home" env OWNER_DELIVERY_ROSTER="$TMP/morning-owner-delivery-roster.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T01:30:00.000Z" bun "$SCRIPT"
test ! -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-gamma.json"
test ! -f "$TMP/relay/2026-07-27-diana-crit-owner-delivery-zero-outsider.json"
test "$(jq -r '.pods | join(",")' "$TMP/state/2026-07-27.json")" = "alpha,beta,gamma"
test "$MORNING_BEFORE" -eq "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)"

# Exercise the producer with the same roster file in an isolated HOME.  These
# are existing team-config bot usernames, so this catches runtime failures in
# roster parsing and owner lookup without contacting Telegram.
PRODUCER_ROSTER="$TMP/producer-roster.json"
mkdir -p "$TMP/home/Documents/Obsidian Vault - Ron/00Daily" "$TMP/home/Documents/Obsidian Vault - Nicky/00Daily" "$TMP/home/Documents/Obsidian Vault - 桃桃/00Daily"
printf '### 進行中\n- 🟡 Ron task\n' >"$TMP/home/Documents/Obsidian Vault - Ron/00Daily/日誌總結.md"
printf '### 進行中\n- 🟡 Nicky task\n' >"$TMP/home/Documents/Obsidian Vault - Nicky/00Daily/日誌總結.md"
printf '### 進行中\n- 🟡 Tao task\n' >"$TMP/home/Documents/Obsidian Vault - 桃桃/00Daily/日誌總結.md"
cat >"$PRODUCER_ROSTER" <<'JSON'
{"pods":[
  {"bot_username":"Ron0001_bot","state_dir":"panda","vault_dir":"Ron","journal_file":"日誌總結.md"},
  {"bot_username":"ZhangLingheAI_bot","state_dir":"zhanglinghe","vault_dir":"Nicky","journal_file":"日誌總結.md"}
]}
JSON
HOME="$TMP/home" MORNING_TODO_ROSTER="$PRODUCER_ROSTER" MORNING_TODO_TASK_ROOT="$TMP/tasks" MORNING_TODO_ANYA_DB="$TMP/anya.db" bash "$PRODUCER" >/dev/null
test "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)" -eq 2
test -f "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*-morning-Ron0001_bot.json' -print -quit)"
test -f "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*-morning-ZhangLingheAI_bot.json' -print -quit)"

# Adding an existing bot to the one roster changes the producer immediately.
rm -f "$TMP/home/.claude-bots/relay"/*
cat >"$PRODUCER_ROSTER" <<'JSON'
{"pods":[
  {"bot_username":"Ron0001_bot","state_dir":"panda","vault_dir":"Ron","journal_file":"日誌總結.md"},
  {"bot_username":"ZhangLingheAI_bot","state_dir":"zhanglinghe","vault_dir":"Nicky","journal_file":"日誌總結.md"},
  {"bot_username":"chltao_bot","state_dir":"elon","vault_dir":"桃桃","journal_file":"日誌總結.md"}
]}
JSON
HOME="$TMP/home" MORNING_TODO_ROSTER="$PRODUCER_ROSTER" MORNING_TODO_TASK_ROOT="$TMP/tasks" MORNING_TODO_ANYA_DB="$TMP/anya.db" bash "$PRODUCER" >/dev/null
test "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l)" -eq 3
test -f "$(find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*-morning-chltao_bot.json' -print -quit)"

# The checked-in operational roster must preserve the actual eight-recipient
# batch.  Run the real source file under an isolated HOME/relay directory; no
# production relay is touched and missing journals still produce their normal
# reminder relay.
REAL_ROSTER="$ROOT/shared/config/morning-owner-delivery-roster.json"
BROKEN_REAL_ROSTER="$TMP/broken-morning-owner-delivery-roster.json"
count_morning_relays() {
  find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' | wc -l
}
expect_eight_morning_relays() {
  test "$(count_morning_relays)" -eq 8
}
rm -f "$TMP/home/.claude-bots/relay"/*
HOME="$TMP/home" MORNING_TODO_TASK_ROOT="$TMP/tasks" MORNING_TODO_ANYA_DB="$TMP/anya.db" bash "$PRODUCER" >/dev/null
expect_eight_morning_relays
find "$TMP/home/.claude-bots/relay" -maxdepth 1 -name '*morning*.json' -printf '%f\n' | sort >"$TMP/real-roster-relays.txt"
test "$(wc -l <"$TMP/real-roster-relays.txt")" -eq 8

# Negative proof: one invalid owner mapping must remove exactly one relay, and
# the eight-recipient assertion must fail.  This prevents a future roster
# omission from passing merely because the producer itself exits successfully.
jq '.pods[0].bot_username = "missing_owner_mapping_bot"' "$REAL_ROSTER" >"$BROKEN_REAL_ROSTER"
rm -f "$TMP/home/.claude-bots/relay"/*
HOME="$TMP/home" MORNING_TODO_ROSTER="$BROKEN_REAL_ROSTER" MORNING_TODO_TASK_ROOT="$TMP/tasks" MORNING_TODO_ANYA_DB="$TMP/anya.db" bash "$PRODUCER" >/dev/null 2>"$TMP/broken-roster.stderr"
test "$(count_morning_relays)" -eq 7
if expect_eight_morning_relays; then
  echo "broken roster unexpectedly satisfied the eight-relay assertion" >&2
  exit 1
fi
grep -Fq 'missing owner mapping for @missing_owner_mapping_bot' "$TMP/broken-roster.stderr"
# Same date/pod is a single fact: rerunning must not emit a second alert.
HOME="$TMP/home" env OWNER_DELIVERY_ROSTER="$TMP/morning-owner-delivery-roster.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T03:00:00.000Z" bun "$SCRIPT"
test "$(find "$TMP/relay" -maxdepth 1 -type f | wc -l)" -eq 1

# Negative proof: if the alert branch is disabled, the fixture must fail.
rm -rf "$TMP/relay" "$TMP/state"
mkdir -p "$TMP/relay" "$TMP/state"
# Rebuild a genuinely missing receipt after clearing prior roster state.  The
# injected failure must execute the alert branch, rather than passing because
# the test data accidentally has no missing pods.
cat >"$TMP/pod-system/gateway-assist-alpha.log" <<'LOG'
[2026-07-28T01:02:00.000Z] task #2 relay output routed via owner_escalation
LOG
if HOME="$TMP/home" env OWNER_DELIVERY_INJECT_BROKEN=1 OWNER_DELIVERY_ROSTER="$TMP/morning-owner-delivery-roster.json" OWNER_DELIVERY_POD_SYSTEM="$TMP/pod-system" OWNER_DELIVERY_RELAY_DIR="$TMP/relay" OWNER_DELIVERY_STATE_DIR="$TMP/state" OWNER_DELIVERY_NOW_ISO="2026-07-27T01:30:00.000Z" bun "$SCRIPT"; then
  echo "negative proof unexpectedly passed" >&2
  exit 1
fi
echo "owner-delivery zero-receipt fixture: PASS"

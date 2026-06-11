#!/usr/bin/env bash
# Tests for cove-inbox-inject.sh
# Run: bash ~/.claude-bots/shared/hooks/tests/test_cove_inbox_inject.sh
set -uo pipefail

HOOK="$HOME/.claude-bots/shared/hooks/cove-inbox-inject.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

run_case() {
  local name="$1" expected_rc="$2"
  local actual_rc actual_out
  actual_out=$(TELEGRAM_STATE_DIR="$TMPROOT/state/testbot" COVE_STATE_INBOX_DIR="$TMPROOT/state/testbot/inbox/messages" bash "$HOOK" 2>"$TMPROOT/err")
  actual_rc=$?
  shift 2
  # remaining args: expected_output_contains strings
  local ok=1
  [[ "$actual_rc" != "$expected_rc" ]] && ok=0
  for substr in "$@"; do
    [[ "$actual_out" != *"$substr"* ]] && ok=0
  done
  if [[ "$ok" == 1 ]]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s (rc=%s expected=%s)\n' "$name" "$actual_rc" "$expected_rc"
    printf '        output: %s\n' "$actual_out"
    printf '        stderr: %s\n' "$(cat "$TMPROOT/err")"
    FAIL=$((FAIL+1))
  fi
}

MSG_DIR="$TMPROOT/state/testbot/inbox/messages"
mkdir -p "$MSG_DIR"

# Case (a): 1 message → hook outputs XML + file becomes .delivered
echo "--- case (a): single message injection ---"
cat > "$MSG_DIR/1000-cove-msg.json" <<'EOF'
{
  "method": "notifications/claude/channel",
  "params": {
    "content": "<channel source=\"plugin:cove\" chat_id=\"aabbccdd\" message_id=\"eeee\" user=\"@alice\" ts=\"2026-04-22T06:00:00.000Z\">hello cove</channel>",
    "meta": { "source": "cove-daemon" }
  }
}
EOF

out=$(TELEGRAM_STATE_DIR="$TMPROOT/state/testbot" COVE_STATE_INBOX_DIR="$MSG_DIR" bash "$HOOK" 2>/dev/null)
if echo "$out" | grep -q 'source="plugin:cove"' && [[ -f "$MSG_DIR/1000-cove-msg.json.delivered" ]] && [[ ! -f "$MSG_DIR/1000-cove-msg.json" ]]; then
  printf '  PASS  (a) single message: XML output + .delivered marker\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  (a) single message: output=%s, delivered=%s\n' "$out" "$(ls "$MSG_DIR")"
  FAIL=$((FAIL+1))
fi

# Case (b): empty inbox → hook exits 0 + empty output
echo "--- case (b): empty inbox ---"
EMPTY_DIR="$TMPROOT/state/empty/inbox/messages"
mkdir -p "$EMPTY_DIR"
out2=$(TELEGRAM_STATE_DIR="$TMPROOT/state/empty" COVE_STATE_INBOX_DIR="$EMPTY_DIR" bash "$HOOK" 2>/dev/null)
rc2=$?
if [[ "$rc2" == 0 ]] && [[ -z "$out2" ]]; then
  printf '  PASS  (b) empty inbox: exit 0, no output\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  (b) empty inbox: rc=%s output=%s\n' "$rc2" "$out2"
  FAIL=$((FAIL+1))
fi

# Case (c): damaged JSON → skip without error, valid file still processed
echo "--- case (c): damaged JSON skipped, valid file processed ---"
MIXED_DIR="$TMPROOT/state/mixed/inbox/messages"
mkdir -p "$MIXED_DIR"
echo 'NOT_JSON{{{' > "$MIXED_DIR/2000-cove-msg.json"
cat > "$MIXED_DIR/2001-cove-msg.json" <<'EOF'
{
  "method": "notifications/claude/channel",
  "params": {
    "content": "<channel source=\"plugin:cove\" chat_id=\"bbcc\" message_id=\"f\" user=\"@bob\" ts=\"2026-04-22T07:00:00.000Z\">world</channel>",
    "meta": {}
  }
}
EOF

out3=$(TELEGRAM_STATE_DIR="$TMPROOT/state/mixed" COVE_STATE_INBOX_DIR="$MIXED_DIR" bash "$HOOK" 2>/dev/null)
rc3=$?
if [[ "$rc3" == 0 ]] && echo "$out3" | grep -q 'world' && [[ -f "$MIXED_DIR/2001-cove-msg.json.delivered" ]]; then
  printf '  PASS  (c) damaged JSON skipped, valid processed\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  (c): rc=%s, output=%s, delivered=%s\n' "$rc3" "$out3" "$(ls "$MIXED_DIR")"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

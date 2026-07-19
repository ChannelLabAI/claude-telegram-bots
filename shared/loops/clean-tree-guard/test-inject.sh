#!/usr/bin/env bash
# Isolated injection test: no production checkout, relay, or Mattermost call.
set -euo pipefail

LOOP_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$LOOP_DIR/clean-tree-guard.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
PASS=0
FAIL=0

check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS $label"; PASS=$((PASS + 1))
  else
    echo "FAIL $label (got=$actual expected=$expected)" >&2; FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$FIXTURE/shared/hooks" "$FIXTURE/shared/bin" "$FIXTURE/bots/anya" "$FIXTURE/relay"
printf '#!/usr/bin/env bash\necho baseline\n' > "$FIXTURE/shared/hooks/workspace-protect.sh"
printf '{}' > "$FIXTURE/bots/anya/access.json"
printf '# fixture MM environment\n' > "$FIXTURE/anya-mm.env"
cat > "$FIXTURE/mm-post" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$TEST_MM_LOG"
EOF
chmod +x "$FIXTURE/mm-post"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email fixture@example.test
git -C "$FIXTURE" config user.name fixture
git -C "$FIXTURE" add shared/hooks/workspace-protect.sh bots/anya/access.json
git -C "$FIXTURE" commit -qm baseline

run_guard() {
  CLEAN_TREE_GUARD_ROOT="$FIXTURE" \
  CLEAN_TREE_GUARD_STATE_DIR="$FIXTURE/state" \
  CLEAN_TREE_GUARD_RELAY_DIR="$FIXTURE/relay" \
  CLEAN_TREE_GUARD_MM_POST="$FIXTURE/mm-post" \
  CLEAN_TREE_GUARD_MM_ENV="$FIXTURE/anya-mm.env" \
  TEST_MM_LOG="$FIXTURE/mm.log" \
  CLEAN_TREE_GUARD_NOW_EPOCH="$1" \
  CLEAN_TREE_GUARD_NOW_ISO="2026-07-19T22:00:00+08:00" \
  bash "$GUARD" >/dev/null
}

# A short-lived edit is first seen then cleared: it must never relay.
printf '# dirty once\n' >> "$FIXTURE/shared/hooks/workspace-protect.sh"
run_guard 1000
check 'single dirty round has no relay' "$(find "$FIXTURE/relay" -name '*.json' | wc -l)" 0
git -C "$FIXTURE" checkout -- shared/hooks/workspace-protect.sh
run_guard 1100
check 'clean round clears state' "$(test -e "$FIXTURE/state/pending-diff.json"; echo $?)" 1

# The same content at least 30 minutes apart alerts via the Anya relay.
printf '# persistent dirty\n' >> "$FIXTURE/shared/hooks/workspace-protect.sh"
run_guard 2000
check 'first persistent round suppressed' "$(find "$FIXTURE/relay" -name '*.json' | wc -l)" 0
run_guard 3800
relay="$(find "$FIXTURE/relay" -name '*.json' -print -quit)"
check 'persistent second round emits relay' "$(test -n "$relay"; echo $?)" 0
check 'relay routes to anya' "$(jq -r .recipient "$relay")" anya
check 'relay identifies dirty hook' "$(jq -r .text "$relay" | grep -c workspace-protect.sh)" 1
check 'persistent second round posts Mattermost' "$(wc -l < "$FIXTURE/mm.log")" 1
check 'Mattermost channel is agent-comms' "$(cut -f2 "$FIXTURE/mm.log")" '#agent-comms'
run_guard 5600
check 'same fingerprint alerts once' "$(find "$FIXTURE/relay" -name '*.json' | wc -l)" 1

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

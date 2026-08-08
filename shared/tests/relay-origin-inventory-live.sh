#!/usr/bin/env bash
# Live, read-mostly gate: trigger the real patrol writer into canonical relay/
# and prove a running gateway archives it instead of quarantining it.
set -euo pipefail

ROOT="${RELAY_LIVE_ROOT:-/home/oldrabbit/.claude-bots}"
PATROL_SH="${PATROL_SCAN_SH:-$ROOT/shared/bin/patrol-scan.sh}"
RELAY_DIR="${RELAY_LIVE_DIR:-$ROOT/relay}"
WAIT_SECS="${RELAY_LIVE_WAIT_SECS:-45}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{tasks/{pending,in_progress,review,archived},logs,pod-system/pods,shared/config}

now="$(date +%s)"
old="$((now-1000))"
cat > "$TMP/shared/config/patrol-scan.json" <<'EOF'
{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":10,"in_progress":43200,"review":14400,"relay_unconsumed":900,"event_injection":120},"gateway":{"expected_processes":0,"tolerance":1000},"whitelist":[],"true_bot_recipients_fallback":["anya"]}
EOF
printf '%s\n' '{"task_id":"relay-origin-live-fixture","assigned":"anna","history":[]}' > "$TMP/tasks/pending/relay-origin-live-fixture.json"
touch -d "@$old" "$TMP/tasks/pending/relay-origin-live-fixture.json"
: > "$TMP/ps"

before="$(find "$RELAY_DIR/quarantine" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"
PATROL_ROOT="$TMP" PATROL_CONFIG="$TMP/shared/config/patrol-scan.json" \
PATROL_LOG_DIR="$TMP/logs" PATROL_RELAY_DIR="$RELAY_DIR" \
PATROL_INOTIFY_LOG="$TMP/logs/missing.log" PATROL_PODS_DIR="$TMP/pod-system/pods" \
PATROL_PS_FILE="$TMP/ps" PATROL_NOW_EPOCH="$now" bash "$PATROL_SH" > "$TMP/patrol-output.json"

file="$(find "$RELAY_DIR" -maxdepth 1 -type f -name "patrol-scan-$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)-anya.json" -printf '%f\n' -quit)"
[[ -n "$file" ]] || { echo "FAIL live: patrol writer produced no relay file" >&2; exit 1; }
for ((i=0; i<WAIT_SECS; i++)); do
  [[ -f "$RELAY_DIR/read/$file" || -f "$RELAY_DIR/quarantine/$file" ]] && break
  sleep 1
done

after="$(find "$RELAY_DIR/quarantine" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"
[[ "$before" == "$after" ]] || { echo "FAIL live: new patrol-scan quarantine file appeared: $file" >&2; exit 1; }
[[ -f "$RELAY_DIR/read/$file" ]] || { echo "FAIL live: gateway did not archive $file within ${WAIT_SECS}s" >&2; exit 1; }
jq -e '.from_bot == "patrol-scan" and .recipient == "anya"' "$RELAY_DIR/read/$file" >/dev/null
echo "PASS live: patrol writer path produced $file; gateway archived it; quarantine set unchanged"

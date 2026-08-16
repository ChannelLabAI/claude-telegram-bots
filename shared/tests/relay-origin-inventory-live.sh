#!/usr/bin/env bash
# Live read-only gate: a fixture ROOT must not write into canonical relay/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${RELAY_LIVE_ROOT:-/home/oldrabbit/.claude-bots}"
PATROL_SH="${PATROL_SCAN_SH:-$SCRIPT_DIR/../bin/patrol-scan.sh}"
RELAY_DIR="${RELAY_LIVE_DIR:-$ROOT/relay}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"/{tasks/{pending,in_progress,review},logs,pod-system/pods,shared/config}

cat > "$TMP/shared/config/patrol-scan.json" <<'EOF'
{"alert_owner_recipient":"anya","thresholds_seconds":{"pending_unclaimed":10,"in_progress":43200,"review":14400,"relay_unconsumed":900,"event_injection":120},"gateway":{"expected_processes":0,"tolerance":1000},"whitelist":[],"true_bot_recipients_fallback":["anya"]}
EOF
: > "$TMP/ps"

before_relay="$(find "$RELAY_DIR" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"
before_quarantine="$(find "$RELAY_DIR/quarantine" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"
set +e
PATROL_ROOT="$TMP" PATROL_CONFIG="$TMP/shared/config/patrol-scan.json" \
  PATROL_LOG_DIR="$TMP/logs" PATROL_RELAY_DIR="$RELAY_DIR" \
  PATROL_INOTIFY_LOG="$TMP/logs/missing.log" PATROL_PODS_DIR="$TMP/pod-system/pods" \
  PATROL_PS_FILE="$TMP/ps" bash "$PATROL_SH" > "$TMP/output.json" 2> "$TMP/error.log"
rc=$?
set -e
after_relay="$(find "$RELAY_DIR" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"
after_quarantine="$(find "$RELAY_DIR/quarantine" -maxdepth 1 -type f -name 'patrol-scan-*.json' -printf '%f\n' 2>/dev/null | sort)"

[[ "$rc" -ne 0 ]] || { echo "FAIL live: fixture patrol unexpectedly accepted canonical relay" >&2; exit 1; }
grep -q 'PATROL_RELAY_DIR resolves outside PATROL_ROOT' "$TMP/error.log" || { echo "FAIL live: missing clear fail-closed diagnostic" >&2; exit 1; }
[[ "$before_relay" == "$after_relay" ]] || { echo "FAIL live: fixture wrote a canonical patrol relay" >&2; exit 1; }
[[ "$before_quarantine" == "$after_quarantine" ]] || { echo "FAIL live: fixture caused a new quarantine record" >&2; exit 1; }
grep -q 'origin_root' "$PATROL_SH" || { echo "FAIL live: patrol source lacks origin_root marker" >&2; exit 1; }
echo "PASS live: fixture ROOT was rejected before canonical relay write; relay/quarantine unchanged; origin_root marker present"

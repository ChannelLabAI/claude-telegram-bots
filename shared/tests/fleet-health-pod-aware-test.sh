#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLEET_HEALTH="$WT_ROOT/shared/bin/fleet-health"

TMP="$(mktemp -d /tmp/fleet-health-pod-aware.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/bots/keeper" \
  "$TMP/root/logs/section11" \
  "$TMP/root/logs" \
  "$TMP/root/gateway-builder/pods" \
  "$TMP/root/gateway-builder" \
  "$TMP/bin"

cat > "$TMP/root/bots/keeper/state.json" <<'JSON'
{"status":"idle","last_run":"2026-07-11T00:00:00Z","last_batch_summary":"inbox:0 ontology:0 conflicts:0"}
JSON
: > "$TMP/root/logs/section11/observations.jsonl"
: > "$TMP/root/logs/usage.jsonl"

cat > "$TMP/root/gateway-builder/pods/assist-alpha.json" <<'JSON'
{"podName":"assist-alpha","bots":[{"name":"alpha","model":"claude-sonnet-5"}]}
JSON
cat > "$TMP/root/gateway-builder/pods/assist-beta.json" <<'JSON'
{"podName":"assist-beta","bots":[{"name":"beta","model":"claude-sonnet-5"}]}
JSON
cat > "$TMP/root/gateway-builder/pods/assist-ignored.json.bak-20260711" <<'JSON'
{"podName":"assist-ignored","bots":[{"name":"ignored-bak","model":"claude-sonnet-5"}]}
JSON
mkdir -p "$TMP/root/gateway-builder/pods/bak-archive"
cat > "$TMP/root/gateway-builder/pods/bak-archive/assist-ignored-dir.json" <<'JSON'
{"podName":"assist-ignored-dir","bots":[{"name":"ignored-dir","model":"claude-sonnet-5"}]}
JSON

cat > "$TMP/bot-status" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"bot":"alpha","alive":false,"pid":null,"model":"n/a","autocompact":"off","context_pct":"n/a","last_activity":"n/a"},
  {"bot":"beta","alive":false,"pid":null,"model":"n/a","autocompact":"off","context_pct":"n/a","last_activity":"n/a"},
  {"bot":"anya","alive":true,"pid":123,"model":"claude-opus-4","autocompact":"80","context_pct":"10%","last_activity":"09:00:00"},
  {"bot":"keeper","alive":false,"pid":null,"model":"n/a","autocompact":"off","context_pct":"n/a","last_activity":"n/a"}
]
JSON
SH
chmod +x "$TMP/bot-status"

cat > "$TMP/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *gateway@assist-alpha.service*) echo active; exit 0 ;;
  *gateway@assist-beta.service*) echo active; exit 0 ;;
  *) echo inactive; exit 3 ;;
esac
SH
chmod +x "$TMP/systemctl"

touch "$TMP/root/gateway-builder/heartbeat-assist-alpha.txt"
touch -d '10 minutes ago' "$TMP/root/gateway-builder/heartbeat-assist-beta.txt"

OUT="$TMP/out.txt"
FLEET_HEALTH_BASE="$TMP/root" \
FLEET_HEALTH_BOT_STATUS="$TMP/bot-status" \
FLEET_HEALTH_SYSTEMCTL="$TMP/systemctl" \
"$FLEET_HEALTH" > "$OUT"

grep -Eq "✅ alpha[[:space:]]+✓[[:space:]]+n/a[[:space:]]+off[[:space:]]+assist-alpha \\(pod\\)" "$OUT"
grep -Eq "🔴 beta[[:space:]]+✗[[:space:]]+DEAD[[:space:]]+off[[:space:]]+assist-beta \\(pod\\)" "$OUT"
grep -Eq "✅ anya[[:space:]]+✓[[:space:]]+10%[[:space:]]+80[[:space:]]+tmux" "$OUT"
! grep -q "ignored-bak" "$OUT"
! grep -q "ignored-dir" "$OUT"

echo "fleet-health pod-aware fixture: PASS"

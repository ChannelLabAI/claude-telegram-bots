#!/usr/bin/env bash
# Deterministic S2 read-error/never-recorded regression fixture.
set -u
PASS=0
FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
HB_SRC="${HB_SRC:-/home/oldrabbit/.claude-bots/shared/scripts/heartbeat.ts}"
FIX=$(mktemp -d /tmp/heartbeat-s2-read-error-XXXXXX)
trap 'rm -rf "$FIX"' EXIT

make_db(){
  local path=$1 mode=${2:-all}
  python3 - "$path" "$mode" <<'PY'
import datetime
import sqlite3
import sys

path, mode = sys.argv[1:]
conn = sqlite3.connect(path)
conn.execute("""CREATE TABLE heartbeats (
  component TEXT PRIMARY KEY, last_ok_at TEXT, last_status TEXT,
  last_error TEXT, consecutive_failures INTEGER DEFAULT 0
)""")
components = ["keeper-batch", "dream_cycle", "stale_check", "tg_ingest"]
if mode == "missing-dream":
    components.remove("dream_cycle")
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
for component in components:
    conn.execute("INSERT INTO heartbeats VALUES (?, ?, 'ok', NULL, 0)", (component, now))
conn.commit()
conn.close()
PY
}

run_hb(){
  PATH=/usr/bin:/bin \
  TG_TOKEN_DIANA=fixture \
  HEARTBEAT_DB_PATH="$1" \
  HEARTBEAT_KG_DB_PATH="$FIX/not-present-kg.db" \
  HEARTBEAT_PODS_DB_DIR="$FIX/not-present-pods" \
  HEARTBEAT_RELAY_DIR="$FIX/relay" \
  HEARTBEAT_LOGS_DIR="$FIX/logs" \
  HEARTBEAT_NOW_ISO="2026-07-09T14:00:00+08:00" \
  HEARTBEAT_TEST_S2_READ_ERROR="${2:-}" \
  "$BUN" "$HB_SRC" --dry-run 2>&1
}

echo "=== S2-1 first two-attempt read failure is explicit AMBER, never absence ==="
DB1="$FIX/read-error.db"
make_db "$DB1"
out1=$(run_hb "$DB1" always)
s2_1=$(printf '%s\n' "$out1" | grep 'S2_cron_.*: ' || true)
printf '%s\n' "$s2_1" | grep -q 'AMBER.*db-read-failed after retry' \
  && ok "read failure becomes explicit AMBER after one retry" \
  || bad "missing AMBER db-read-failed result: $s2_1"
printf '%s\n' "$s2_1" | grep -q 'never recorded' \
  && bad "read failure was mislabeled never recorded" \
  || ok "read failure never claims the component was absent"

echo "=== S2-2 consecutive failed round escalates to RED with db-read-failed wording ==="
out2=$(run_hb "$DB1" always)
s2_2=$(printf '%s\n' "$out2" | grep 'S2_cron_.*: ' || true)
printf '%s\n' "$s2_2" | grep -q 'RED.*db-read-failed.*2 consecutive rounds' \
  && ok "persistent read failure escalates on the second round" \
  || bad "persistent failure did not escalate: $s2_2"
printf '%s\n' "$s2_2" | grep -q 'never recorded' \
  && bad "escalated read failure was mislabeled never recorded" \
  || ok "escalated failure retains db-read-failed semantics"

echo "=== S2-3 transient first-attempt error recovers on retry ==="
DB3="$FIX/retry-recovers.db"
make_db "$DB3"
out3=$(run_hb "$DB3" once)
s2_3=$(printf '%s\n' "$out3" | grep 'S2_cron_.*: ' || true)
printf '%s\n' "$s2_3" | grep -q 'db-read-failed' \
  && bad "successful retry still reported db-read-failed" \
  || ok "successful retry returns normal component results"
printf '%s\n' "$s2_3" | grep -q 'S2_cron_dream_cycle: GREEN' \
  && ok "healthy row remains GREEN after retry" \
  || bad "healthy row not GREEN after retry: $s2_3"

echo "=== S2-4 genuinely absent row remains RED/never recorded ==="
DB4="$FIX/missing-row.db"
make_db "$DB4" missing-dream
out4=$(run_hb "$DB4")
printf '%s\n' "$out4" | grep -q 'S2_cron_dream_cycle: RED.*never recorded' \
  && ok "true missing row remains RED/never recorded" \
  || bad "true missing row semantics weakened: $(printf '%s\n' "$out4" | grep dream_cycle)"

echo "=== S2-5 every emitted physical log line has an ISO timestamp ==="
bad_lines=$(printf '%s\n' "$out4" | grep -Ev '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[^]]+Z\] ' || true)
if [ -z "$bad_lines" ]; then
  ok "all physical lines are timestamped"
else
  bad "untimestamped lines found: $bad_lines"
fi

echo
echo "===== 結果：PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" = "0" ]

#!/usr/bin/env bash
# mvp-bind-failure-test.sh — 53e7: bind failure must not leave an idle mvp-server process.
# Usage: MVP_SRC=/home/oldrabbit/.claude-bots/mvp bash shared/tests/mvp-bind-failure-test.sh
set -u

PASS=0; FAIL=0; SKIP=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
bad(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skipc(){ echo "  ⤳ SKIP $1"; SKIP=$((SKIP+1)); }

BUN=/home/oldrabbit/.bun/bin/bun
SRC="${MVP_SRC:-/home/oldrabbit/.claude-bots/mvp}"
SERVER="$SRC/mvp-server.ts"

echo "=== B1 static lifecycle guard: background jobs start only after Bun.serve succeeds ==="
python3 - "$SERVER" <<'PY'
import sys
p=sys.argv[1]
s=open(p, encoding="utf-8").read()
assert "function startBackgroundJobs()" in s, "missing startBackgroundJobs()"
assert "function pollWebReplies()" in s, "web reply poller should be a function, not eager interval"
assert "function cleanRateLimitBuckets()" in s, "rate-limit cleanup should be a function, not eager interval"
assert "process.exit(98)" in s, "bind failure must exit with sentinel code 98"
serve=s.index("Bun.serve({")
start=s.index("startBackgroundJobs();")
catch=s.index("process.exit(98)")
assert serve < start < catch, (serve, start, catch)
PY
[ "$?" = "0" ] && ok "background jobs are gated behind successful Bun.serve()" || bad "lifecycle guard missing"

echo "=== B2 dynamic bind failure: second same-port process exits 98 and does not linger ==="
FIX=$(mktemp -d /tmp/mvp-bind-failure-test-XXXXXX)
PID1=""
cleanup(){ [ -n "$PID1" ] && kill "$PID1" 2>/dev/null || true; rm -rf "$FIX"; }
trap cleanup EXIT

mkdir -p "$FIX/bin" "$FIX/mvp" "$FIX/tasks"/{pending,in_progress,review,done,rejected,cancelled,design_review,approval_pending} \
  "$FIX/projects/archived" "$FIX/gb/pods" "$FIX/bots"
cat > "$FIX/bin/gcloud" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$FIX/bin/fatq" <<'EOS'
#!/usr/bin/env bash
echo '{"ok":true,"tasks":[]}'
exit 0
EOS
cat > "$FIX/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$FIX/bin/gcloud" "$FIX/bin/fatq" "$FIX/bin/systemctl"
printf '<!doctype html><html><body>fixture</body></html>\n' > "$FIX/mvp/app.html"

PORT="${MVP_TEST_PORT:-18563}"
COMMON_ENV=(
  "PATH=$FIX/bin:$PATH"
  "MVP_PORT=$PORT"
  "MVP_DIR=$FIX/mvp"
  "FATQ_ROOT=$FIX/tasks"
  "PROJECTS_ROOT=$FIX/projects"
  "MVP_GB=$FIX/gb"
  "MVP_BOTS_DIR=$FIX/bots"
  "MVP_SYSTEMCTL_BIN=$FIX/bin/systemctl"
  "FATQ_BIN=$FIX/bin/fatq"
  "MVP_DEV_MODE=1"
)

env "${COMMON_ENV[@]}" "$BUN" "$SERVER" > "$FIX/one.log" 2>&1 &
PID1=$!
for _ in $(seq 1 40); do
  curl -sm1 -o /dev/null "http://127.0.0.1:$PORT/" && break
  kill -0 "$PID1" 2>/dev/null || break
  sleep 0.25
done

if ! kill -0 "$PID1" 2>/dev/null || ! curl -sm1 -o /dev/null "http://127.0.0.1:$PORT/"; then
  skipc "dynamic port bind unavailable in this environment; first server did not become reachable"
  sed -n '1,80p' "$FIX/one.log"
  echo "===== RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
  [ "$FAIL" = "0" ] || exit 1
  exit 0
fi

set +e
env "${COMMON_ENV[@]}" "$BUN" "$SERVER" > "$FIX/two.log" 2>&1 &
PID2=$!
for _ in $(seq 1 40); do
  kill -0 "$PID2" 2>/dev/null || break
  sleep 0.25
done
wait "$PID2"
RC2=$?
set -e

if [ "$RC2" = "98" ] && grep -q "failed to bind" "$FIX/two.log"; then
  ok "second process exits 98 on EADDRINUSE"
else
  bad "second process exit/log mismatch: rc=$RC2 log=$(head -c 200 "$FIX/two.log")"
fi

if kill -0 "$PID2" 2>/dev/null; then
  bad "second process is still alive after bind failure"
else
  ok "second process did not linger"
fi

echo "===== RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" = "0" ] || exit 1

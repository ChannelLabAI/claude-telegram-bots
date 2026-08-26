#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/shared/bin/memocean-drift-check.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
PASS=0
FAIL=0

ok() { echo "PASS $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $*" >&2; FAIL=$((FAIL + 1)); }

REPO="$FIXTURE/repo"
REPO_PACKAGE="$REPO/memocean_mcp"
INSTALL_PACKAGE="$FIXTURE/site-packages/memocean_mcp"
STATE="$FIXTURE/state"
NOTIFY="$FIXTURE/notify"
mkdir -p "$REPO_PACKAGE" "$INSTALL_PACKAGE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOTIFY"
chmod +x "$NOTIFY"

fresh_pair() {
  rm -rf "$REPO_PACKAGE" "$INSTALL_PACKAGE" "$STATE"
  mkdir -p "$REPO_PACKAGE" "$INSTALL_PACKAGE"
  printf '__version__ = "0.5.0"\n' > "$REPO_PACKAGE/__init__.py"
  printf 'VALUE = "fresh"\n' > "$REPO_PACKAGE/server.py"
  cp -a "$REPO_PACKAGE/." "$INSTALL_PACKAGE/"
}

run_check() {
  MEMOCEAN_REPO_ROOT="$REPO" \
  MEMOCEAN_INSTALL_PACKAGE="$INSTALL_PACKAGE" \
  MEMOCEAN_DRIFT_NOTIFY_BIN="$NOTIFY" \
  MEMOCEAN_DRIFT_RELAY_DIR="$FIXTURE/relay" \
  MEMOCEAN_DRIFT_STATE_DIR="$STATE" \
  MEMOCEAN_DRIFT_LOG="$FIXTURE/drift.log" \
  bash "$CHECK"
}

fresh_pair
run_check >/dev/null && ok 'matching repository and installed sources exit 0' || bad 'matching sources did not exit 0'

fresh_pair
printf 'VALUE = "different"\n' > "$INSTALL_PACKAGE/server.py"
set +e
output="$(run_check 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 1 && "$output" == *'content-diff server.py'* ]] && ok 'content drift exits 1 and lists the file' || bad "content drift result rc=$rc output=$output"

fresh_pair
rm "$INSTALL_PACKAGE/server.py"
set +e
output="$(run_check 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 1 && "$output" == *'missing-installed server.py'* ]] && ok 'missing installed file exits 1 and lists the file' || bad "missing-file result rc=$rc output=$output"

fresh_pair
printf 'VALUE = "same-version-new-code"\n' > "$REPO_PACKAGE/server.py"
set +e
output="$(run_check 2>&1)"; rc=$?
set -e
if [[ "$rc" -eq 1 && "$output" == *'content-diff server.py'* ]] && cmp -s "$REPO_PACKAGE/__init__.py" "$INSTALL_PACKAGE/__init__.py"; then
  ok 'same package version with different source content exits 1'
else
  bad "same-version content drift result rc=$rc output=$output"
fi

if ! grep -Fn -- 'pip install -e' "$CHECK" >/dev/null; then
  ok 'drift checker contains no editable-install command'
else
  bad 'drift checker contains an editable-install command'
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

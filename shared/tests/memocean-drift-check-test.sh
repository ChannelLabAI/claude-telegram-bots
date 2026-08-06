#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/shared/bin/memocean-drift-check.sh"
DEPLOY="$ROOT/shared/bin/memocean-deploy.sh"
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
NOTIFY_ENV="$FIXTURE/notify.env"
DEPLOY_IMPL="$FIXTURE/deploy-impl"
RECORD="$FIXTURE/deployment.json"
mkdir -p "$REPO_PACKAGE" "$INSTALL_PACKAGE"
printf 'fixture=1\n' > "$NOTIFY_ENV"
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
  MEMOCEAN_DRIFT_NOTIFY_ENV="$NOTIFY_ENV" \
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

fresh_pair
git -C "$REPO" init -q
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name Fixture
printf '[build-system]\nrequires=[]\nbuild-backend="fixture"\n' > "$REPO/pyproject.toml"
git -C "$REPO" add memocean_mcp pyproject.toml
git -C "$REPO" commit -qm fixture
cat > "$DEPLOY_IMPL" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
rm -rf "$MEMOCEAN_FIXTURE_INSTALL"
mkdir -p "$MEMOCEAN_FIXTURE_INSTALL"
cp -a "$MEMOCEAN_REPO_ROOT/memocean_mcp/." "$MEMOCEAN_FIXTURE_INSTALL/"
SH
chmod +x "$DEPLOY_IMPL"
printf 'VALUE = "stale"\n' > "$INSTALL_PACKAGE/server.py"
if MEMOCEAN_REPO_ROOT="$REPO" \
  MEMOCEAN_DEPLOY_IMPL="$DEPLOY_IMPL" \
  MEMOCEAN_DRIFT_CHECK="$CHECK" \
  MEMOCEAN_INSTALL_PACKAGE="$INSTALL_PACKAGE" \
  MEMOCEAN_FIXTURE_INSTALL="$INSTALL_PACKAGE" \
  MEMOCEAN_DRIFT_NOTIFY_BIN="$NOTIFY" \
  MEMOCEAN_DRIFT_NOTIFY_ENV="$NOTIFY_ENV" \
  MEMOCEAN_DRIFT_STATE_DIR="$STATE" \
  MEMOCEAN_DEPLOY_RECORD="$RECORD" \
  bash "$DEPLOY" >/dev/null && run_check >/dev/null; then
  expected_commit="$(git -C "$REPO" rev-parse HEAD)"
  recorded_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo_commit"])' "$RECORD")"
  [[ "$recorded_commit" == "$expected_commit" ]] && ok 'canonical deploy restores green drift state and records the exact commit' || bad 'deployment record commit mismatch'
else
  bad 'canonical deployment did not restore a green drift state'
fi

if ! grep -Fn -- 'pip install -e' "$DEPLOY" "$CHECK" >/dev/null; then
  ok 'canonical scripts contain no editable-install command'
else
  bad 'canonical scripts contain an editable-install command'
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]

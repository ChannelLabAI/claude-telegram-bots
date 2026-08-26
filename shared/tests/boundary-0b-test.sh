#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FIXTURE="$(mktemp -d /tmp/boundary-0b-test.XXXXXX)"

cleanup() {
  case "$FIXTURE" in
    /tmp/boundary-0b-test.*)
      chmod -R u+w "$FIXTURE" 2>/dev/null || true
      find "$FIXTURE" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

paths=(
  shared/bin/fatq-cli.sh
  shared/bin/fatq-deploy-gate.sh
  pod-system/gateway.ts
  mvp/.git/config
  mvp/.git/hooks/reference-transaction
)

for relative in "${paths[@]}"; do
  mkdir -p "$FIXTURE/$(dirname "$relative")"
  printf 'fixture:%s\n' "$relative" > "$FIXTURE/$relative"
  chmod 0644 "$FIXTURE/$relative"
done
chmod 0755 "$FIXTURE/shared/bin/fatq-cli.sh" \
  "$FIXTURE/shared/bin/fatq-deploy-gate.sh" \
  "$FIXTURE/mvp/.git/hooks/reference-transaction"

manifest="$FIXTURE/manifest.json"
echo '=== SNAPSHOT ==='
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" --snapshot --root "$FIXTURE" --manifest "$manifest"

echo '=== MANIFEST TARGET SET TAMPER REJECTED ==='
tampered_manifest="$FIXTURE/tampered-manifest.json"
jq '.files[0].path = "logs/runtime.log"' "$manifest" > "$tampered_manifest"
set +e
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" \
  --check --root "$FIXTURE" --manifest "$tampered_manifest"
tampered_rc=$?
set -e
printf 'TAMPERED_MANIFEST_EXIT=%s\n' "$tampered_rc"
[[ "$tampered_rc" -ne 0 ]]

echo '=== CHECK POSITIVE ==='
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" --check --root "$FIXTURE" --manifest "$manifest"

echo '=== CHECK NEGATIVE MODE ==='
chmod 0600 "$FIXTURE/pod-system/gateway.ts"
set +e
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" --check --root "$FIXTURE" --manifest "$manifest"
negative_rc=$?
set -e
printf 'NEGATIVE_CHECK_EXIT=%s\n' "$negative_rc"
[[ "$negative_rc" -ne 0 ]]
chmod 0644 "$FIXTURE/pod-system/gateway.ts"

echo '=== REAL NOTIFY SOURCE RESOLUTION ==='
notify_source="$FIXTURE/production-alert-notify.py"
notify_copy="$FIXTURE/verified-alert-notify.py"
cat > "$notify_source" <<'EOF'
def relay_notify(text: str, source: str) -> bool:
    return True
EOF
resolved_notify_source="$(
  BOUNDARY_0B_ALERT_NOTIFY_SRC="$notify_source" \
    bash "$REPO_ROOT/shared/tests/boundary-0b-host-test.sh" \
      --check-real-notify-source
)"
printf 'REAL_NOTIFY_SOURCE_OK|%s\n' "$resolved_notify_source"
cp -- "$resolved_notify_source" "$notify_copy"
cmp -- "$notify_source" "$notify_copy"

missing_notify_source="$FIXTURE/missing-alert-notify.py"
set +e
missing_notify_output="$(
  BOUNDARY_0B_ALERT_NOTIFY_SRC="$missing_notify_source" \
    bash "$REPO_ROOT/shared/tests/boundary-0b-host-test.sh" \
      --check-real-notify-source 2>&1
)"
missing_notify_rc=$?
set -e
printf '%s\n' "$missing_notify_output"
printf 'REAL_NOTIFY_MISSING_EXIT=%s\n' "$missing_notify_rc"
[[ "$missing_notify_rc" -eq 3 ]]
grep -Fx "ERROR|missing-prod-alert-notify|$missing_notify_source" \
  <<< "$missing_notify_output"

echo '=== CONFIRMED APPLY PREFLIGHT IS ALL-OR-NOTHING ON BASELINE DRIFT ==='
chmod 0600 "$FIXTURE/mvp/.git/hooks/reference-transaction"
preflight_log_before="$FIXTURE/preflight-chattr-before.log"
: > "$preflight_log_before"
preflight_chattr="$FIXTURE/preflight-chattr"
cat > "$preflight_chattr" <<'EOF'
#!/usr/bin/env bash
printf 'UNEXPECTED_CHATTR|%s\n' "$*" >> "$PREFLIGHT_CHATTR_LOG"
EOF
chmod 0755 "$preflight_chattr"
export PREFLIGHT_CHATTR_LOG="$preflight_log_before"
set +e
BOUNDARY_0B_CHATTR_BIN="$preflight_chattr" \
  bash "$REPO_ROOT/shared/bin/boundary-0b-apply.sh" --confirm --root "$FIXTURE" --manifest "$manifest"
preflight_rc=$?
set -e
printf 'PREFLIGHT_NEGATIVE_EXIT=%s\n' "$preflight_rc"
printf 'PREFLIGHT_CHATTR_CALLS=%s\n' "$(wc -l < "$preflight_log_before" | tr -d ' ')"
[[ "$preflight_rc" -ne 0 ]]
[[ ! -s "$preflight_log_before" ]]
chmod 0755 "$FIXTURE/mvp/.git/hooks/reference-transaction"

echo '=== APPLY DRY RUN LSATTR BEFORE ==='
before_attrs="$(lsattr -d "${paths[@]/#/$FIXTURE/}")"
printf '%s\n' "$before_attrs"
bash "$REPO_ROOT/shared/bin/boundary-0b-apply.sh" --root "$FIXTURE" --manifest "$manifest"
echo '=== APPLY DRY RUN LSATTR AFTER ==='
after_attrs="$(lsattr -d "${paths[@]/#/$FIXTURE/}")"
printf '%s\n' "$after_attrs"
[[ "$before_attrs" == "$after_attrs" ]]
echo 'DRY_RUN_LSATTR_IDENTICAL=yes'

state_dir="$FIXTURE/fake-attrs"
mkdir -p "$state_dir"
fake_chattr="$FIXTURE/fake-chattr"
fake_lsattr="$FIXTURE/fake-lsattr"

cat > "$fake_chattr" <<'EOF'
#!/usr/bin/env bash
set -u
op="$1"
target="${3:-}"
key="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
printf 'CHATTR_CALL|%s|%s\n' "$op" "$target" >> "$FAKE_CHATTR_LOG"
if [[ "${FAIL_MATCH:-}" && "$op" == "-i" && "$target" == *"$FAIL_MATCH"* ]]; then
  printf 'FAKE_CHATTR_FAILURE|%s|%s\n' "$op" "$target" >&2
  exit 9
fi
case "$op" in
  +i) printf 'immutable\n' > "$FAKE_ATTR_STATE/$key" ;;
  -i) unlink "$FAKE_ATTR_STATE/$key" 2>/dev/null || true ;;
  *) exit 2 ;;
esac
EOF

cat > "$fake_lsattr" <<'EOF'
#!/usr/bin/env bash
set -u
target="${3:-}"
if [[ "${FAIL_LSATTR_MATCH:-}" && "$target" == *"$FAIL_LSATTR_MATCH"* ]]; then
  printf 'FAKE_LSATTR_FAILURE|%s\n' "$target" >&2
  exit 8
fi
key="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
if [[ -f "$FAKE_ATTR_STATE/$key" ]]; then
  printf '%s %s\n' '----i---------e-------' "$target"
else
  printf '%s %s\n' '--------------e-------' "$target"
fi
EOF

mkdir -p "$FIXTURE/shared/scripts"
cat > "$FIXTURE/shared/scripts/alert_notify.py" <<'EOF'
def relay_notify(text: str, source: str) -> bool:
    print(f"ALERT_NOTIFY_FIXTURE|source={source}|text={text}")
    return True
EOF
chmod 0755 "$fake_chattr" "$fake_lsattr"
export FAKE_ATTR_STATE="$state_dir"
export FAKE_CHATTR_LOG="$FIXTURE/chattr.log"
export BOUNDARY_0B_CHATTR_BIN="$fake_chattr"
export BOUNDARY_0B_LSATTR_BIN="$fake_lsattr"

echo '=== ISOLATED APPLY (injected attribute fixture) ==='
bash "$REPO_ROOT/shared/bin/boundary-0b-apply.sh" --confirm --root "$FIXTURE" --manifest "$manifest"
"$fake_lsattr" -d -- "$FIXTURE/shared/bin/fatq-cli.sh"
"$fake_lsattr" -d -- "$FIXTURE/shared/bin/fatq-deploy-gate.sh"
"$fake_lsattr" -d -- "$FIXTURE/pod-system/gateway.ts"

echo '=== ALERT ACTUAL TRIGGER ==='
"$fake_chattr" -i -- "$FIXTURE/pod-system/gateway.ts"
chmod 0600 "$FIXTURE/pod-system/gateway.ts"
export FAIL_LSATTR_MATCH='mvp/.git/config'
set +e
bash "$REPO_ROOT/shared/bin/boundary-0b-alert.sh" \
  --root "$FIXTURE" --manifest "$manifest"
alert_rc=$?
set -e
printf 'ALERT_EXIT=%s\n' "$alert_rc"
[[ "$alert_rc" -eq 1 ]]
unset FAIL_LSATTR_MATCH
chmod 0644 "$FIXTURE/pod-system/gateway.ts"
"$fake_chattr" +i -- "$FIXTURE/pod-system/gateway.ts"

echo '=== ROLLBACK CONTINUES AFTER ONE FAILURE ==='
export FAIL_MATCH='fatq-deploy-gate.sh'
export FAIL_LSATTR_MATCH='fatq-deploy-gate.sh'
set +e
bash "$REPO_ROOT/shared/bin/boundary-0b-rollback.sh" --root "$FIXTURE" --manifest "$manifest"
rollback_failure_rc=$?
set -e
printf 'ROLLBACK_FAILURE_EXIT=%s\n' "$rollback_failure_rc"
[[ "$rollback_failure_rc" -ne 0 ]]
grep 'CHATTR_CALL|-i|.*/pod-system/gateway.ts' "$FAKE_CHATTR_LOG"

echo '=== CLEAN ROLLBACK ==='
unset FAIL_MATCH
unset FAIL_LSATTR_MATCH
bash "$REPO_ROOT/shared/bin/boundary-0b-rollback.sh" --root "$FIXTURE" --manifest "$manifest"
echo '=== THREE-FILE LSATTR RESTORED ==='
"$fake_lsattr" -d -- "$FIXTURE/shared/bin/fatq-cli.sh"
"$fake_lsattr" -d -- "$FIXTURE/shared/bin/fatq-deploy-gate.sh"
"$fake_lsattr" -d -- "$FIXTURE/pod-system/gateway.ts"

echo '=== FINAL BASELINE CHECK ==='
unset BOUNDARY_0B_LSATTR_BIN BOUNDARY_0B_CHATTR_BIN
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" --check --root "$FIXTURE" --manifest "$manifest"
echo 'BOUNDARY_0B_TEST_OK'

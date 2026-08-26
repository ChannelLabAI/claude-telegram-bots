#!/usr/bin/env bash
set -euo pipefail

boundary_0b_real_notify_source() {
  local source_path
  source_path="${BOUNDARY_0B_ALERT_NOTIFY_SRC:-/home/oldrabbit/.claude-bots/shared/scripts/alert_notify.py}"
  if [[ ! -f "$source_path" ]]; then
    printf 'ERROR|missing-prod-alert-notify|%s\n' "$source_path" >&2
    return 3
  fi
  realpath -e -- "$source_path"
}

if [[ "${1:-}" == "--check-real-notify-source" ]]; then
  [[ $# -eq 1 ]] || {
    printf 'ERROR|usage|%s --check-real-notify-source\n' "$0" >&2
    exit 2
  }
  boundary_0b_real_notify_source
  exit $?
fi

if (( EUID != 0 )); then
  printf 'HOST_TEST_BLOCKED|requires-root|run=sudo -n bash shared/tests/boundary-0b-host-test.sh\n' >&2
  exit 77
fi

alert_notify_source=""
if [[ "${BOUNDARY_0B_REAL_NOTIFY:-0}" == "1" ]]; then
  alert_notify_source="$(boundary_0b_real_notify_source)"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FIXTURE="$(mktemp -d /tmp/boundary-0b-host-test.XXXXXX)"

cleanup() {
  case "$FIXTURE" in
    /tmp/boundary-0b-host-test.*)
      find "$FIXTURE" -type f -exec chattr -i -- {} + 2>/dev/null || true
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
  printf 'host-fixture:%s\n' "$relative" > "$FIXTURE/$relative"
  chmod 0644 "$FIXTURE/$relative"
done
chmod 0755 "$FIXTURE/shared/bin/fatq-cli.sh" \
  "$FIXTURE/shared/bin/fatq-deploy-gate.sh" \
  "$FIXTURE/mvp/.git/hooks/reference-transaction"

manifest="$FIXTURE/manifest.json"
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" \
  --snapshot --root "$FIXTURE" --manifest "$manifest"

echo '=== REAL CHATTR APPLY ==='
bash "$REPO_ROOT/shared/bin/boundary-0b-apply.sh" \
  --confirm --root "$FIXTURE" --manifest "$manifest"
echo '=== REAL CHATTR THREE-FILE APPLIED ==='
lsattr -d \
  "$FIXTURE/shared/bin/fatq-cli.sh" \
  "$FIXTURE/shared/bin/fatq-deploy-gate.sh" \
  "$FIXTURE/pod-system/gateway.ts"

mkdir -p "$FIXTURE/shared/scripts"
if [[ "${BOUNDARY_0B_REAL_NOTIFY:-0}" == "1" ]]; then
  cp -- "$alert_notify_source" "$FIXTURE/shared/scripts/alert_notify.py"
  printf 'HOST_ALERT_NOTIFY_SOURCE=%s\n' "$alert_notify_source"
  echo 'HOST_ALERT_ROUTE=real-alert_notify.py:relay_notify'
else
  cat > "$FIXTURE/shared/scripts/alert_notify.py" <<'EOF'
def relay_notify(text: str, source: str) -> bool:
    print(f"HOST_ALERT_NOTIFY_FIXTURE|source={source}|text={text}")
    return True
EOF
  echo 'HOST_ALERT_ROUTE=fixture-alert_notify.py:relay_notify'
fi

echo '=== REAL IMMUTABLE REMOVAL ALERT TRIGGER ==='
chattr -i -- "$FIXTURE/pod-system/gateway.ts"
chmod 0600 "$FIXTURE/pod-system/gateway.ts"
set +e
bash "$REPO_ROOT/shared/bin/boundary-0b-alert.sh" \
  --root "$FIXTURE" --manifest "$manifest"
alert_rc=$?
set -e
printf 'HOST_ALERT_EXIT=%s\n' "$alert_rc"
[[ "$alert_rc" -eq 1 ]]
chmod 0644 "$FIXTURE/pod-system/gateway.ts"
chattr +i -- "$FIXTURE/pod-system/gateway.ts"

echo '=== REAL CHATTR ROLLBACK ==='
bash "$REPO_ROOT/shared/bin/boundary-0b-rollback.sh" \
  --root "$FIXTURE" --manifest "$manifest"
echo '=== REAL CHATTR THREE-FILE RESTORED ==='
lsattr -d \
  "$FIXTURE/shared/bin/fatq-cli.sh" \
  "$FIXTURE/shared/bin/fatq-deploy-gate.sh" \
  "$FIXTURE/pod-system/gateway.ts"
bash "$REPO_ROOT/shared/bin/boundary-0b-manifest.sh" \
  --check --root "$FIXTURE" --manifest "$manifest"
echo 'BOUNDARY_0B_HOST_TEST_OK'

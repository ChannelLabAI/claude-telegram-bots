#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="${PROVISION_UNDER_TEST:-$ROOT/shared/bin/provision-customer-env.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/systemd" "$TMP/config" "$TMP/code" "$TMP/vault" "$TMP/existing-data"
touch "$TMP/code/mvp-server.ts"
printf 'existing-instance-only\n' > "$TMP/existing-data/existing-only.txt"

cat > "$TMP/fake-bun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/fake-bun"

cat > "$TMP/fake-ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/fake-ss"

cat > "$TMP/fake-systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  daemon-reload) exit 0 ;;
  is-active)
    shift
    [[ "${1:-}" == "--quiet" ]] && shift
    [[ -f "$FAKE_SYSTEMCTL_STATE/${1:?unit}.active" ]]
    ;;
  enable)
    shift
    [[ "${1:-}" == "--now" ]] && shift
    touch "$FAKE_SYSTEMCTL_STATE/${1:?unit}.active"
    ;;
  disable)
    shift
    [[ "${1:-}" == "--now" ]] && shift
    rm -f -- "$FAKE_SYSTEMCTL_STATE/${1:?unit}.active"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/fake-systemctl"
mkdir -p "$TMP/systemctl-state"
touch "$TMP/systemctl.log"

export PROVISION_SYSTEMD_USER_DIR="$TMP/systemd"
export PROVISION_CONFIG_ROOT="$TMP/config"
export PROVISION_SYSTEMCTL_BIN="$TMP/fake-systemctl"
export PROVISION_SS_BIN="$TMP/fake-ss"
export PROVISION_BUN_BIN="$TMP/fake-bun"
export FAKE_SYSTEMCTL_STATE="$TMP/systemctl-state"
export FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log"

args=(
  --target local
  --customer NOXCAT
  --port 18091
  --emails owner@noxcat.example,ops@noxcat.example
  --data-dir "$TMP/noxcat-data"
  --vault-root "$TMP/vault"
  --code-dir "$TMP/code"
)

"$PROVISION" provision "${args[@]}"
[[ -f "$TMP/systemd/mvp-customer-noxcat.service" ]]
[[ -f "$TMP/config/noxcat.env" ]]
[[ -f "$TMP/systemctl-state/mvp-customer-noxcat.service.active" ]]
[[ -f "$TMP/noxcat-data/.mvp-customer-instance" ]]
if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify "$TMP/systemd/mvp-customer-noxcat.service" >"$TMP/systemd-verify.out" 2>&1; then
    cat "$TMP/systemd-verify.out" >&2
    exit 1
  fi
fi
printf 'new-instance-only\n' > "$TMP/noxcat-data/new-only.txt"

# Two-way data separation proof: each marker exists only below its own root.
[[ -f "$TMP/noxcat-data/new-only.txt" ]]
[[ ! -e "$TMP/existing-data/new-only.txt" ]]
[[ -f "$TMP/existing-data/existing-only.txt" ]]
[[ ! -e "$TMP/noxcat-data/existing-only.txt" ]]

find "$TMP/systemd" -maxdepth 1 -type f -printf '%f\n' | sort > "$TMP/units.before"
find "$TMP/noxcat-data" -xdev -printf '%P\t%y\n' | sort > "$TMP/files.before"
sha256sum "$TMP/noxcat-data/new-only.txt" > "$TMP/sentinel.before"
"$PROVISION" provision "${args[@]}"
find "$TMP/systemd" -maxdepth 1 -type f -printf '%f\n' | sort > "$TMP/units.after"
find "$TMP/noxcat-data" -xdev -printf '%P\t%y\n' | sort > "$TMP/files.after"
sha256sum "$TMP/noxcat-data/new-only.txt" > "$TMP/sentinel.after"
cmp "$TMP/units.before" "$TMP/units.after"
cmp "$TMP/files.before" "$TMP/files.after"
cmp "$TMP/sentinel.before" "$TMP/sentinel.after"
[[ "$(awk '$0 == "mvp-customer-noxcat.service" {n++} END {print n+0}' "$TMP/units.after")" == 1 ]]

# Every product-owned mutable source is customer scoped; code/vault are the only
# deliberate external read roots. Dangerous control-plane writers fail closed.
grep -Fq "MVP_DATA_DIR=\"$TMP/noxcat-data\"" "$TMP/config/noxcat.env"
grep -Fq 'MVP_BASE_URL="http://127.0.0.1:18091"' "$TMP/config/noxcat.env"
grep -Fq 'MVP_ATTACH_ORIGIN="http://localhost:18091"' "$TMP/config/noxcat.env"
python3 - "$TMP/config/noxcat.env" <<'PY'
import shlex, sys
from urllib.parse import urlsplit

values = {}
for line in open(sys.argv[1], encoding="utf-8"):
    key, raw = line.rstrip("\n").split("=", 1)
    values[key] = shlex.split(raw)[0]
base = values["MVP_BASE_URL"]
attach = values["MVP_ATTACH_ORIGIN"]
base_host = urlsplit(base).hostname
attach_host = urlsplit(attach).hostname
print(f"PROVISIONED_BASE_URL={base}")
print(f"PROVISIONED_ATTACH_ORIGIN={attach}")
print(f"PROVISIONED_HOSTS={base_host}|{attach_host}")
if not base_host or not attach_host or base_host.lower() == attach_host.lower():
    raise SystemExit("generated customer env has colliding base/attach hostnames")
PY
grep -Fq "MVP_FATQ_ROOT=\"$TMP/noxcat-data/fatq\"" "$TMP/config/noxcat.env"
grep -Fq "MVP_PROJECTS_ROOT=\"$TMP/noxcat-data/projects\"" "$TMP/config/noxcat.env"
grep -Fq 'MVP_SYSTEMCTL_BIN="/usr/bin/false"' "$TMP/config/noxcat.env"
grep -Fq 'MVP_FATQ_BIN="/usr/bin/false"' "$TMP/config/noxcat.env"
if grep -Eq '^(FATQ_ROOT|PROJECTS_ROOT|FATQ_BIN)=' "$TMP/config/noxcat.env"; then
  echo "customer config contains an unprefixed MVP-owned variable" >&2
  exit 1
fi
grep -E '^(MVP_FATQ_ROOT|MVP_PROJECTS_ROOT|MVP_FATQ_BIN)=' "$TMP/config/noxcat.env" \
  | sed 's/^/TENANT_CONFIG_/'

# Parameter drift must fail without changing installed metadata or customer data.
cp "$TMP/config/noxcat.env" "$TMP/config.snapshot"
if "$PROVISION" provision "${args[@]/18091/18092}" >"$TMP/drift.out" 2>&1; then
  echo "expected drifted rerun to fail" >&2
  exit 1
fi
cmp "$TMP/config.snapshot" "$TMP/config/noxcat.env"
[[ -f "$TMP/noxcat-data/new-only.txt" ]]

"$PROVISION" list --target local | tee "$TMP/list.out"
grep -Fq $'NOXCAT\tmvp-customer-noxcat.service\t18091' "$TMP/list.out"

# Default uninstall removes service metadata but preserves customer data.
"$PROVISION" uninstall --target local --customer NOXCAT
[[ ! -e "$TMP/systemd/mvp-customer-noxcat.service" ]]
[[ ! -e "$TMP/config/noxcat.env" ]]
[[ -f "$TMP/noxcat-data/new-only.txt" ]]

# Reprovision preserved data, then explicit purge removes only marker-owned data.
"$PROVISION" provision "${args[@]}"
[[ -f "$TMP/noxcat-data/new-only.txt" ]]
"$PROVISION" uninstall --target local --customer NOXCAT --purge-data
[[ ! -e "$TMP/noxcat-data" ]]
[[ -f "$TMP/existing-data/existing-only.txt" ]]

if "$PROVISION" provision "${args[@]/18091/8090}" >"$TMP/8090.out" 2>&1; then
  echo "expected production port rejection" >&2
  exit 1
fi
grep -Fq 'port 8090 is reserved' "$TMP/8090.out"

if "$PROVISION" provision "${args[@]/local/remote}" >"$TMP/remote.out" 2>&1; then
  echo "expected remote target rejection" >&2
  exit 1
fi
grep -Fq "unsupported in v1" "$TMP/remote.out"

mkdir -p "$TMP/occupied-data"
printf 'do-not-adopt\n' > "$TMP/occupied-data/preexisting.txt"
occupied_args=("${args[@]/$TMP\/noxcat-data/$TMP\/occupied-data}")
if "$PROVISION" provision "${occupied_args[@]}" >"$TMP/occupied.out" 2>&1; then
  echo "expected non-empty unmarked data-dir rejection" >&2
  exit 1
fi
grep -Fq 'refusing to adopt non-empty unmarked data-dir' "$TMP/occupied.out"
grep -Fxq 'do-not-adopt' "$TMP/occupied-data/preexisting.txt"

echo "provision-customer-env-test: PASS"

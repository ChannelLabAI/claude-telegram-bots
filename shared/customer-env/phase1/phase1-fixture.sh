#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: phase1-fixture.sh MVP_SOURCE" >&2; exit 2; }
mvp_source="$(realpath -e "$1")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT

release_out="$fixture_root/build"
bash "$here/build-customer-release.sh" "$mvp_source" "$release_out"
bash "$here/../../tests/customer-bundle-internal-leak-scan.sh" "$release_out/release"
bash "$here/../../tests/customer-pm-route-fixture.sh" "$release_out/release"
manifest="$release_out/release/dist/env-manifest.json"
customer_env="$fixture_root/customer.env"
secrets_env="$fixture_root/secrets.env"
: > "$secrets_env"
jq -r '.required[] | .name as $n | if $n=="MVP_GBRAIN_MODE" then "\($n)=disabled" elif $n=="MVP_PUBLIC_MODE" or $n=="MVP_DEV_MODE" or $n=="MVP_SKIP_SERVE" then "\($n)=0" elif .type=="integer" then "\($n)=8091" elif .type=="url" then "\($n)=https://customer.invalid" elif .type=="absolute_path" then "\($n)=/var/lib/channellab-mvp/fixture/\($n)" else "\($n)=fixture" end' "$manifest" > "$customer_env"

bun "$here/preflight.ts" --manifest "$manifest" --customer-env "$customer_env" --secrets-env "$secrets_env" | tee "$fixture_root/green.out"
grep -v '^MVP_ADMIN_GATE_IDENTITY=' "$customer_env" > "$fixture_root/missing.env"
set +e
bun "$here/preflight.ts" --manifest "$manifest" --customer-env "$fixture_root/missing.env" --secrets-env "$secrets_env" >"$fixture_root/red.out" 2>&1
red_exit=$?
set -e
[[ $red_exit -ne 0 ]]
grep -Fx 'MISSING_REQUIRED_ENV=MVP_ADMIN_GATE_IDENTITY' "$fixture_root/red.out"
printf '\nMVP_GBRAIN_URL=http://127.0.0.1:5099/query\n' >> "$customer_env"
set +e
bun "$here/preflight.ts" --manifest "$manifest" --customer-env "$customer_env" --secrets-env "$secrets_env" >"$fixture_root/gbrain-url.out" 2>&1
gbrain_url_exit=$?
set -e
[[ $gbrain_url_exit -ne 0 ]]
grep -Fx 'FORBIDDEN_ENV=MVP_GBRAIN_URL' "$fixture_root/gbrain-url.out"

unit="$release_out/release/systemd/channellab-mvp.service"
for setting in 'User=channellab-mvp' 'NoNewPrivileges=yes' 'ProtectSystem=strict' 'ProtectHome=yes' 'PrivateTmp=yes' 'PrivateDevices=yes' 'RestrictSUIDSGID=yes' 'ReadWritePaths=/var/lib/channellab-mvp /var/lib/channellab-mvp/vault' 'ExecStartPre='; do grep -F "$setting" "$unit" >/dev/null; done
grep -E '老兔|laotu|bthare|1050312492|assist-anya|caijie-zhuchu|ron-assistant|lilai-fengfeng|nicky-zhanglinghe|chltao|wes-buddy|33-huizhang' "$release_out/release/dist/app.html" > "$fixture_root/app-scan.out" || true
[[ ! -s "$fixture_root/app-scan.out" ]]
echo "BUILT_APP_INTERNAL_HITS=0"
grep -aEi 'oldrabbit|\.claude-bots|bthare|laotu|1050312492|assist-anya|caijie-zhuchu|ron-assistant|lilai-fengfeng|nicky-zhanglinghe|chltao|wes-buddy|33-huizhang|\banya\b|\bnicky\b|\bcarrot\b|\blilai\b|\bthreethree\b|\bwes\b|\bron\b' "$release_out/release/dist/mvp-server.js" > "$fixture_root/server-scan.out" || true
[[ ! -s "$fixture_root/server-scan.out" ]]
echo "BUILT_SERVER_INTERNAL_HITS=0"

contaminated="$fixture_root/contaminated-release"
cp -a "$release_out/release" "$contaminated"
printf '\nchannellab-prod\n' >> "$contaminated/dist/mvp-server.js"
set +e
bash "$here/../../tests/customer-bundle-internal-leak-scan.sh" "$contaminated" > "$fixture_root/internal-leak-red.out" 2>&1
leak_exit=$?
set -e
[[ $leak_exit -eq 1 ]]
grep -F 'token=channellab-prod' "$fixture_root/internal-leak-red.out" >/dev/null
grep -F 'file=dist/mvp-server.js' "$fixture_root/internal-leak-red.out" >/dev/null
echo "INTERNAL_IDENTIFIER_MUTATION_TEST=PASS"
echo "PHASE1_FIXTURE_OK"

#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $# -eq 2 ]] || { echo "usage: build-customer-release.sh REVIEWED_MVP_SOURCE NEW_OUTPUT_DIR" >&2; exit 2; }
source_root="$(realpath -e "$1")"
output="$2"
[[ ! -e "$output" ]] || { echo "OUTPUT_ALREADY_EXISTS=$output" >&2; exit 1; }
mkdir -p "$output/release/dist" "$output/release/ops" "$output/release/systemd" "$output/evidence"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepared_source="$(mktemp -d)"
trap 'rm -rf -- "$prepared_source"' EXIT

while IFS= read -r file; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  [[ -f "$source_root/$file" ]] || { echo "ALLOWLIST_SOURCE_MISSING=$file" >&2; exit 1; }
done < "$here/customer-source-allowlist.txt"

bun "$here/prepare-customer-source.ts" "$source_root" "$here/customer-source-allowlist.txt" "$prepared_source"
bun "$here/generate-env-manifest.ts" "$prepared_source" "$here/customer-source-allowlist.txt" \
  "$output/release/dist/env-manifest.json" "$output/evidence/customer.env.template"
install -m 0644 "$here/customer-app.html" "$output/release/dist/app.html"
install -m 0644 "$here/systemd/channellab-mvp.service" "$output/release/systemd/channellab-mvp.service"
bun build "$prepared_source/mvp-server.ts" --target=bun --minify --outfile="$output/release/dist/mvp-server.js"
bun "$here/sanitize-customer-server.ts" "$output/release/dist/mvp-server.js"
bun build "$output/release/dist/mvp-server.js" --target=bun --outfile="$output/evidence/customer-server-syntax.js" >/dev/null
bun build --compile "$here/preflight.ts" --outfile="$output/release/ops/preflight"
git -C "$source_root" rev-parse HEAD > "$output/release/VERSION"

for token in '老兔' 'laotu' 'bthare' '1050312492' 'assist-anya' 'caijie-zhuchu' 'ron-assistant' 'lilai-fengfeng' 'nicky-zhanglinghe' 'chltao' 'wes-buddy' '33-huizhang'; do
  if grep -Fq "$token" "$output/release/dist/app.html"; then echo "CUSTOMER_APP_INTERNAL_TOKEN=$token" >&2; exit 1; fi
done
if grep -aEiq 'oldrabbit|\.claude-bots|bthare|laotu|1050312492|assist-anya|caijie-zhuchu|ron-assistant|lilai-fengfeng|nicky-zhanglinghe|chltao|wes-buddy|33-huizhang|\banya\b|\bnicky\b|\bcarrot\b|\blilai\b|\bthreethree\b|\bwes\b|\bron\b' "$output/release/dist/mvp-server.js"; then
  echo "CUSTOMER_SERVER_INTERNAL_TOKEN" >&2; exit 1
fi

(cd "$output/release" && find . -type f ! -name manifest.sha256 -printf '%P\n' | sort | xargs sha256sum) > "$output/release/manifest.sha256"
find "$output/release" -type f -printf '%P\n' | sort > "$output/evidence/distribution-files.txt"
sort -u "$here/customer-distribution-allowlist.txt" > "$output/evidence/allowed-files.txt"
diff -u "$output/evidence/allowed-files.txt" "$output/evidence/distribution-files.txt"
bash "$here/../../tests/customer-bundle-internal-leak-scan.sh" "$output/release"
echo "CUSTOMER_RELEASE_OK=$(realpath "$output/release")"

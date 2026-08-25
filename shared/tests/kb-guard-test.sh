#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/shared/bin/kb-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/truth/projects" "$TMP/archive" "$TMP/state"

git -C "$TMP/truth" init -q -b main
git -C "$TMP/truth" config user.name fixture
git -C "$TMP/truth" config user.email fixture@example.invalid
cp /dev/null "$TMP/archive/ARCHIVE-LOG.md"

cat > "$TMP/truth/projects/bonk-geo.md" <<'EOF'
---
id: bonk-geo
contract:
  terms: Net 7
---
## 日誌
- old immutable log
EOF
cat > "$TMP/truth/projects/transtar.md" <<'EOF'
---
id: transtar
contract:
  品牌授權: 2027-07-31
---
EOF
git -C "$TMP/truth" add .
git -C "$TMP/truth" commit -qm baseline
BEFORE="$(git -C "$TMP/truth" rev-parse HEAD)"
sed -i 's/terms: Net 7/terms: Net 14/' "$TMP/truth/projects/bonk-geo.md"
git -C "$TMP/truth" add .
git -C "$TMP/truth" commit -qm 'contract change'
AFTER="$(git -C "$TMP/truth" rev-parse HEAD)"

cat > "$TMP/config.json" <<EOF
{
  "schema":"kb-guard-config-v1",
  "space_id":"7677673820513128186",
  "lark_host":"fixture.larksuite.com",
  "truth_repo":"$TMP/truth",
  "archive_log":"$TMP/archive/ARCHIVE-LOG.md",
  "state_dir":"$TMP/state",
  "pm_hub_url_patterns":["https://mvp.channellab.io/pm/"],
  "dynamic_value_exempt_title_patterns":["時間線","Timeline"],
  "knowledge_bases":[
    {"project":"bonk-geo","name":"Bonk GEO","root_node_token":"root-bonk","truth_path":"projects/bonk-geo.md","archive_keywords":["bonk","geo"],"archive_target_title":"素材"},
    {"project":"transtar","name":"Transtar","root_node_token":"root-transtar","truth_path":"projects/transtar.md","archive_keywords":["transtar","dappos"],"archive_target_title":"憑證"}
  ]
}
EOF
cat > "$TMP/snapshot.json" <<EOF
{
  "schema":"kb-guard-snapshot-v1","fetched_at":"2026-08-26T00:00:00Z","pages":[
    {"project":"bonk-geo","kb":"Bonk GEO","title":"商務財務","node_token":"n1","obj_token":"d1","url":"https://fixture.larksuite.com/wiki/n1","text":"合約 terms: Net 7\n健康度：🟢\n@nicky due:2026-09-05\nPM https://mvp.channellab.io/pm/bonk-geo.html\nUnrelated https://github.com/channellab/projects/bonk and https://mvp.channellab.io.evil/pm/bonk-geo.html\nArchive ~/agency/archive/missing-bonk.pdf","blocks":[{"block_type":23,"file":{"token":""}}]},
    {"project":"bonk-geo","kb":"Bonk GEO","title":"BD 時間線","node_token":"n2","obj_token":"d2","url":"https://fixture.larksuite.com/wiki/n2","text":"2026-08-24 已到帳 4,000 USDC","blocks":[]},
    {"project":"transtar","kb":"Transtar","title":"憑證與定版文件","node_token":"n3","obj_token":"d3","url":"https://fixture.larksuite.com/wiki/n3","text":"品牌授權 2027-07-31","blocks":[]}
  ]
}
EOF
cat > "$TMP/http-map.json" <<'EOF'
{
  "https://mvp.channellab.io/pm/bonk-geo.html":404,
  "https://github.com/channellab/projects/bonk":404,
  "https://mvp.channellab.io.evil/pm/bonk-geo.html":404
}
EOF

SNAPSHOT_HASH="$(sha256sum "$TMP/snapshot.json" | awk '{print $1}')"

"$GUARD" scan --config "$TMP/config.json" --snapshot "$TMP/snapshot.json" --http-map "$TMP/http-map.json" > "$TMP/scan.json"
jq -e '[.findings[] | select(.check=="K2" and .category=="health_dynamic")] | length == 1' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K2" and .category=="owner_due_dynamic")] | length == 1' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K2" and .category=="current_payment_dynamic")] | length == 0' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K3" and .category=="pm_hub_link_broken")] | length == 1' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K3" and .category=="pm_hub_link_broken")][0].evidence | startswith("https://mvp.channellab.io/pm/bonk-geo.html ")' "$TMP/scan.json" >/dev/null
! jq -e '[.findings[].evidence] | any(contains("github.com/channellab/projects") or contains("mvp.channellab.io.evil"))' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K3" and .category=="archive_path_missing")] | length == 1' "$TMP/scan.json" >/dev/null
jq -e '[.findings[] | select(.check=="K3" and .category=="file_token_empty")] | length == 1' "$TMP/scan.json" >/dev/null

"$GUARD" truth --config "$TMP/config.json" --snapshot "$TMP/snapshot.json" --repo "$TMP/truth" --before "$BEFORE" --after "$AFTER" > "$TMP/truth.json"
jq -e --arg sha "$AFTER" '[.findings[] | select(.check=="K1" and .source_sha==$sha and .page=="商務財務")] | length == 1' "$TMP/truth.json" >/dev/null

printf '%s\n' '2026-08-25 baseline' > "$TMP/archive/ARCHIVE-LOG.md"
BEFORE_LINES=1
printf '%s\n' '2026-08-26 Bonk GEO final report /archive/bonk-final.pdf' >> "$TMP/archive/ARCHIVE-LOG.md"
"$GUARD" archive --config "$TMP/config.json" --snapshot "$TMP/snapshot.json" --log "$TMP/archive/ARCHIVE-LOG.md" --before-lines "$BEFORE_LINES" > "$TMP/archive.json"
jq -e '[.findings[] | select(.check=="K4" and .project=="bonk-geo" and .page=="商務財務")] | length == 1' "$TMP/archive.json" >/dev/null

test "$SNAPSHOT_HASH" = "$(sha256sum "$TMP/snapshot.json" | awk '{print $1}')"
grep -q 'method: "GET"' "$ROOT/shared/bin/kb-guard.ts"
! grep -Eq '(larkPost|larkPut|larkPatch|larkDelete|wiki/v2/.+(POST|PUT|PATCH|DELETE)|docx/v1/.+(POST|PUT|PATCH|DELETE))' "$ROOT/shared/bin/kb-guard.ts"
test "$(grep -Fc 'fetch(`${API_ROOT}${path}`' "$ROOT/shared/bin/kb-guard.ts")" -eq 1
grep -q '# kb-guard daily K2-K3' "$ROOT/shared/bin/install-kb-guard-cron.sh"
grep -q 'RUNTIME_PATH="/home/oldrabbit/.bun/bin:' "$ROOT/shared/bin/install-kb-guard-cron.sh"
grep -q 'LINE="35 18 \* \* \* PATH=\$RUNTIME_PATH ' "$ROOT/shared/bin/install-kb-guard-cron.sh"
grep -q '^Environment=PATH=/home/oldrabbit/.bun/bin:' "$ROOT/infra/systemd/kb-guard-watch.service"
grep -q 'KB_GUARD_BUN_BIN:-/home/oldrabbit/.bun/bin/bun' "$ROOT/shared/bin/kb-guard.sh"
set +e
MINIMAL_OUTPUT="$(env -i PATH=/usr/bin:/bin "$GUARD" --help 2>&1)"
MINIMAL_RC=$?
set -e
test "$MINIMAL_RC" -ne 127
test "$MINIMAL_OUTPUT" = 'usage: kb-guard.sh daily|watch|fetch|scan|truth|archive [options]'

echo 'ACTUAL K1:'
jq -c '.findings[] | select(.check=="K1")' "$TMP/truth.json"
echo 'ACTUAL K2/K3:'
jq -c '.findings[] | select(.check=="K2" or .check=="K3")' "$TMP/scan.json"
echo 'ACTUAL K4:'
jq -c '.findings[] | select(.check=="K4")' "$TMP/archive.json"
echo "PASS zero-change snapshot sha256=$SNAPSHOT_HASH"
echo "PASS minimal env: rc=$MINIMAL_RC output=$MINIMAL_OUTPUT"
echo "PASS PM prefix positive=https://mvp.channellab.io/pm/bonk-geo.html ignored=https://github.com/channellab/projects/bonk,https://mvp.channellab.io.evil/pm/bonk-geo.html"
echo "PASS kb-guard K1-K4 fixture: K1 sha, K2 redlines/exemption, K3 exact PM prefix/404/path/empty-token, K4 mount, read-only"

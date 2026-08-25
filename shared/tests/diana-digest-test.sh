#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/shared/bin/diana-digest.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
PM="$FIXTURE/pm-hub"
STATE="$FIXTURE/state.json"
OUTBOX="$FIXTURE/outbox.txt"
mkdir -p "$PM/projects"
git -C "$PM" init -q
git -C "$PM" config user.name fixture
git -C "$PM" config user.email fixture@example.test

write_project() {
  local path="$1" name="$2" health="$3" fee="$4" task="$5" log_line="$6"
  {
    echo '---'; echo "id: ${path%.md}"; echo "name: $name"; echo "health: $health"
    echo 'contract:'; echo "  fee: $fee"; echo '---'; echo; echo '## 任務'; echo "- [ ] $task"
    echo; echo '## 日誌'; if [[ -n "$log_line" ]]; then echo "$log_line"; fi
  } > "$PM/projects/$path"
}

write_project alpha.md Alpha green 'aggregate-a' baseline ''
write_project beta.md Beta green 'aggregate-b' baseline ''
write_project laorabbit-equity-grant.md Gamma green 'aggregate-c' baseline ''
write_project delta.md Delta green 'aggregate-d' baseline ''
git -C "$PM" add projects
git -C "$PM" commit -qm 'fixture baseline'
commit_as_diana() {
  git -C "$PM" add projects
  GIT_AUTHOR_NAME=Diana GIT_AUTHOR_EMAIL=diana@pm-hub.local GIT_COMMITTER_NAME=Diana GIT_COMMITTER_EMAIL=diana@pm-hub.local git -C "$PM" commit -qm "$1"
  git -C "$PM" rev-parse HEAD
}

write_project alpha.md Alpha amber 'aggregate-a' baseline $'- 2026-08-25 [整理] health 更新；依據：relay:101 完成 25%\n- 2026-08-25 [整理] progress 更新；依據：本期完成25%達標無空格'
sed -i '/^## 日誌/i ## 進度25%達標\n- aggregated\n' "$PM/projects/alpha.md"
write_project delta.md Delta green 'aggregate-d' baseline '- 2026-08-26 [整理] 帳務更新；依據：帳戶0xabcdef1234567890餘額變動'
sed -i '/^## 日誌/i ## 帳戶0xabcdef1234567890餘額\n- aggregated\n' "$PM/projects/delta.md"
sha1="$(commit_as_diana 'groom: alpha health')"
write_project beta.md Beta green 'aggregate-b' '完成资料归位' $'- 2026-08-25 [整理] 调薪更新；依据：laorabbit 调薪 3 级\n- 2026-08-25 [整理] equity 更新；依據：laorabbit 解禁 25%'
sed -i '/^contract:/i 钱包:\n  laorabbit:\n    地址: aggregate-only' "$PM/projects/beta.md"
sed -i '/^## 日誌/i ## laorabbit 调薪方案\n- aggregated\n' "$PM/projects/beta.md"
sha2="$(commit_as_diana 'groom: beta laorabbit 调薪与钱包 3级')"
write_project laorabbit-equity-grant.md Gamma green 'personal equity 15%, wallet 0x1234567890abcdef' baseline $'- 2026-08-25 [整理] contract 更新；依據：laorabbit 助記詞 seed phrase\n- 2026-08-25 [整理] compensation 更新；依據：laorabbit 起薪點 55000'
sed -i '/^contract:/i compensation:\n  laorabbit:\n    base: aggregate-only\n私鑰:\n  laorabbit:\n    助記詞: aggregate-only' "$PM/projects/laorabbit-equity-grant.md"
sed -i '/^## 日誌/i ## 薪水與調薪明細 laorabbit\n- aggregated\n\n## laorabbit 起薪方案\n- aggregated\n\n## laorabbit private key\n- recovery phrase aggregated\n' "$PM/projects/laorabbit-equity-grant.md"
sha3="$(commit_as_diana 'groom: gamma 年終獎金與調薪 private key seed phrase')"

common_env=(DIANA_DIGEST_PM_REPO="$PM" DIANA_DIGEST_STATE="$STATE" DIANA_DIGEST_SINCE='30 days ago')
digest="$(env "${common_env[@]}" "$SCRIPT" --daily --dry-run)"
for sha in "$sha1" "$sha2" "$sha3"; do grep -q "${sha:0:12}" <<<"$digest"; grep -q "commit $sha" <<<"$digest"; done
grep -q '專案：Alpha' <<<"$digest"; grep -q '欄位：health' <<<"$digest"; grep -q '依據：relay:101 完成 \[數值已聚合\]' <<<"$digest"
grep -q '進度\[數值已聚合\]達標' <<<"$digest"; grep -q '本期完成\[數值已聚合\]達標無空格' <<<"$digest"
! grep -q '進度25%達標' <<<"$digest"; ! grep -q '本期完成25%達標無空格' <<<"$digest"
[[ "$digest" == *$'專案：Delta\n  欄位：[L3 聚合欄位]\n  依據：[L3 聚合輸入]'* ]]
! grep -q '0xabcdef1234567890' <<<"$digest"
grep -q '專案：Beta' <<<"$digest"; grep -q '欄位：\[L3 聚合欄位\]' <<<"$digest"
grep -q 'projects/\[L3 專案路徑\]\.md#日誌' <<<"$digest"; grep -q '\[L3 聚合輸入\]' <<<"$digest"
! grep -q 'projects/laorabbit-equity-grant.md#日誌' <<<"$digest"
grep -q '欄位：\[L3 聚合欄位\]' <<<"$digest"
! grep -q 'compensation\.laorabbit\.base' <<<"$digest"
! grep -q '薪水與調薪明細' <<<"$digest"; ! grep -q '年終獎金' <<<"$digest"
for sensitive in '起薪' '解禁' '調薪' '调薪' '钱包' '钱包.laorabbit.地址' '股份' '股票' '認股' '乾股' '配股' '私鑰' '助記詞' 'private key' 'seed phrase' 'recovery phrase'; do
  ! grep -qi "$sensitive" <<<"$digest"
done
! grep -q 'laorabbit' <<<"$digest"; ! grep -q '0x1234567890abcdef' <<<"$digest"; ! grep -Eq '(^|[^0-9])(15|25)%' <<<"$digest"; ! grep -q '55000' <<<"$digest"
grep -q '\[L3 結構更新\]' <<<"$digest"
[[ "$(grep -c '^• ' <<<"$digest")" -eq 3 ]]

sender="$FIXTURE/sender.sh"
sed "s|__OUTBOX__|$OUTBOX|" > "$sender" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "$1" >> '__OUTBOX__'
EOF
chmod +x "$sender"
failed_sender="$FIXTURE/failed-sender.sh"
sed -n 'p' > "$failed_sender" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$failed_sender"
if env "${common_env[@]}" DIANA_DIGEST_SEND_CMD="$failed_sender" "$SCRIPT" --daily >/dev/null 2>&1; then
  echo 'expected sender failure' >&2
  exit 1
fi
[[ ! -e "$STATE" ]]
env "${common_env[@]}" DIANA_DIGEST_SEND_CMD="$sender" "$SCRIPT" --daily
before="$(sha256sum "$OUTBOX")"
env "${common_env[@]}" DIANA_DIGEST_SEND_CMD="$sender" "$SCRIPT" --daily
after="$(sha256sum "$OUTBOX")"
[[ "$before" == "$after" ]]
[[ "$(jq '.sent | length' "$STATE")" -eq 3 ]]

write_project alpha.md Alpha red 'aggregate-a' baseline '- 2026-08-25 [整理] health 更新；依據：relay:303 [重大]'
major_sha="$(commit_as_diana '[重大] groom: alpha health')"
major="$(env "${common_env[@]}" "$SCRIPT" --major-only --dry-run)"
grep -q '重大變更' <<<"$major"; grep -q "${major_sha:0:12}" <<<"$major"

fake_root="$FIXTURE/root"
fake_bin="$FIXTURE/bin"
cron_store="$FIXTURE/crontab.txt"
mkdir -p "$fake_root/shared/bin" "$fake_bin"
cp "$SCRIPT" "$fake_root/shared/bin/diana-digest.sh"
printf '%s\n' '12 1 * * * /usr/bin/existing-job' > "$cron_store"
sed -n 'p' > "$fake_bin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-l' ]]; then cat "$CRON_STORE"; else cat > "$CRON_STORE"; fi
EOF
chmod +x "$fake_bin/crontab"
install_env=(DIANA_DIGEST_ROOT="$fake_root" CRON_STORE="$cron_store" PATH="$fake_bin:/usr/bin:/bin")
env "${install_env[@]}" "$REPO_ROOT/shared/bin/install-diana-digest-cron.sh" >/dev/null
env "${install_env[@]}" "$REPO_ROOT/shared/bin/install-diana-digest-cron.sh" >/dev/null
[[ "$(grep -c 'diana-digest' "$cron_store")" -eq 2 ]]
grep -q 'diana-digest-major' "$cron_store"; grep -q 'diana-digest-daily' "$cron_store"
grep -q '/usr/bin/existing-job' "$cron_store"
[[ -x "$SCRIPT" ]]
echo 'diana-digest fixtures: PASS (3 commits, zero-send, L3 redaction, major fast lane)'

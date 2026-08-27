#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
archiver="$repo/shared/bin/relay-consumed-archiver.sh"
installer="$repo/shared/bin/install-relay-consumed-archiver-cron.sh"
fixture="$(mktemp -d /tmp/relay-consumed-archiver.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT

new_root() {
  local name="$1" root
  root="$fixture/$name"
  mkdir -p "$root/relay/read" "$root/shared/config"
  cp "$repo/shared/config/relay-consumed-readers.json" "$root/shared/config/"
  printf '%s\n' "$root"
}

run_archiver() {
  local root="$1"; shift
  RELAY_ARCHIVER_ROOT="$root" RELAY_ARCHIVER_LOCK_FILE="$root/archiver.lock" "$archiver" "$@"
}

# AC1: one of two expected readers is insufficient; adding the second flips it.
root="$(new_root ac1)"
printf '%s\n' '{"recipient":"anya","text":"handoff @DianaAI_v2_bot"}' > "$root/relay/multi.json"
: > "$root/relay/multi.json.read-by-Anyachl_bot"
run_archiver "$root" > "$root/partial.out"
[[ -f "$root/relay/multi.json" ]]
[[ ! -e "$root/relay/read/multi.json" ]]
grep -F 'reason=reader-pending reader=DianaAI_v2_bot' "$root/partial.out" >/dev/null
: > "$root/relay/multi.json.read-by-DianaAI_v2_bot"
run_archiver "$root" > "$root/complete.out"
[[ ! -e "$root/relay/multi.json" ]]
[[ -f "$root/relay/read/multi.json" ]]
echo 'PASS AC1 multi-reader reject then accept'

# AC2: no read marker means no archive.
root="$(new_root ac2)"
printf '%s\n' '{"recipient":"anya","text":"zero marker"}' > "$root/relay/zero.json"
run_archiver "$root" > "$root/out"
[[ -f "$root/relay/zero.json" ]]
[[ ! -e "$root/relay/read/zero.json" ]]
grep -F 'reason=no-read-markers' "$root/out" >/dev/null
echo 'PASS AC2 zero-marker reject'

# AC3: archive the envelope and every marker, leaving no top-level debris.
root="$(new_root ac3)"
printf '%s\n' '{"recipient":"keeper","text":"fully consumed"}' > "$root/relay/full.json"
: > "$root/relay/full.json.read-by-DianaAI_v2_bot"
: > "$root/relay/full.json.read-by-Audit_bot"
run_archiver "$root" > "$root/out"
[[ ! -e "$root/relay/full.json" ]]
[[ -z "$(find "$root/relay" -maxdepth 1 -type f -name 'full.json*' -print -quit)" ]]
[[ -f "$root/relay/read/full.json" ]]
[[ -f "$root/relay/read/full.json.read-by-DianaAI_v2_bot" ]]
[[ -f "$root/relay/read/full.json.read-by-Audit_bot" ]]
echo 'PASS AC3 envelope and all markers moved'

# AC4: unknown reader set fails conservatively and emits a grep-able reason.
for recipient in empty null; do
  root="$(new_root ac4-$recipient)"
  if [[ "$recipient" == empty ]]; then
    printf '%s\n' '{"recipient":"","text":"no mention"}' > "$root/relay/unknown-$recipient.json"
  else
    printf '%s\n' '{"recipient":null,"text":"no mention"}' > "$root/relay/unknown-$recipient.json"
  fi
  : > "$root/relay/unknown-$recipient.json.read-by-Anyachl_bot"
  run_archiver "$root" > "$root/out"
  [[ -f "$root/relay/unknown-$recipient.json" ]]
  grep -F "SKIP file=unknown-$recipient.json reason=expected-readers-undetermined" "$root/out" >/dev/null
done
echo 'PASS AC4 undetermined reader set skips with reason'

# R2 regression: prose @words do not block, but a true bot-shaped unknown
# mention in the same sentence still fails closed.
root="$(new_root mention-prose)"
printf '%s\n' '{"recipient":"anya","text":"中文技術行文 @mention @username pod@assist-anya"}' > "$root/relay/prose.json"
: > "$root/relay/prose.json.read-by-Anyachl_bot"
run_archiver "$root" > "$root/out"
[[ ! -e "$root/relay/prose.json" ]]
[[ -f "$root/relay/read/prose.json" ]]
grep -F 'ARCHIVED file=prose.json' "$root/out" >/dev/null
echo 'PASS prose @words do not block a fully consumed envelope'

root="$(new_root mention-unmapped)"
printf '%s\n' '{"recipient":"anya","text":"中文技術行文 @mention @username pod@assist-anya；真 bot @Ron0001_bot"}' > "$root/relay/mixed-unmapped.json"
: > "$root/relay/mixed-unmapped.json.read-by-Anyachl_bot"
run_archiver "$root" > "$root/out"
[[ -f "$root/relay/mixed-unmapped.json" ]]
[[ -f "$root/relay/mixed-unmapped.json.read-by-Anyachl_bot" ]]
[[ ! -e "$root/relay/read/mixed-unmapped.json" ]]
grep -F 'SKIP file=mixed-unmapped.json reason=mention-unmapped mention=@Ron0001_bot' "$root/out" >/dev/null
echo 'PASS mixed prose and unknown bot mention still fails closed'

# AC5: preserve an existing destination and retain the incoming copy distinctly.
root="$(new_root ac5)"
printf '%s\n' 'old-content' > "$root/relay/read/collision.json"
printf '%s\n' '{"recipient":"anya","text":"new-content"}' > "$root/relay/collision.json"
: > "$root/relay/collision.json.read-by-Anyachl_bot"
run_archiver "$root" > "$root/out"
[[ "$(cat "$root/relay/read/collision.json")" == old-content ]]
conflict="$(find "$root/relay/read" -maxdepth 1 -type f -name 'collision.conflict-*.json' -print -quit)"
[[ -n "$conflict" ]]
grep -F 'new-content' "$conflict" >/dev/null
[[ -f "$conflict.read-by-Anyachl_bot" ]]
[[ ! -e "$root/relay/collision.json" ]]
echo 'PASS AC5 destination conflict preserves both copies'

# AC6: top-level count plus read/ count is conserved; dry-run changes no bytes.
root="$(new_root ac6)"
printf '%s\n' '{"recipient":"anya","text":"one"}' > "$root/relay/one.json"
: > "$root/relay/one.json.read-by-Anyachl_bot"
printf '%s\n' '{"recipient":"anya","text":"two"}' > "$root/relay/two.json"
: > "$root/relay/two.json.read-by-Anyachl_bot"
before="$(find "$root/relay" -type f | wc -l)"
snapshot_before="$(cd "$root/relay" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum)"
run_archiver "$root" --dry-run > "$root/dry.out"
snapshot_after="$(cd "$root/relay" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum)"
[[ "$snapshot_before" == "$snapshot_after" ]]
[[ "$(grep -Fc 'ARCHIVE-DRY-RUN' "$root/dry.out")" == 2 ]]
run_archiver "$root" > "$root/out"
after="$(find "$root/relay" -type f | wc -l)"
[[ "$before" == "$after" ]]
[[ "$(grep -Fc 'ARCHIVED file=' "$root/out")" == 2 ]]
echo 'PASS AC6 move-only conservation and dry-run immutability'

# Scheduling deliverable: installer is idempotent and installs one 10-minute job.
root="$(new_root cron)"
mkdir -p "$root/shared/bin"
cp "$archiver" "$root/shared/bin/"
chmod +x "$root/shared/bin/relay-consumed-archiver.sh"
fake_crontab="$root/crontab.txt"
fake_bin="$root/crontab"
printf '%s\n' '0 1 * * * true # unrelated' > "$fake_crontab"
cat > "$fake_bin" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -l ]]; then
  cat "$FAKE_CRONTAB"
else
  cp "$1" "$FAKE_CRONTAB"
fi
FAKE
chmod +x "$fake_bin"
for _ in 1 2; do
  RELAY_ARCHIVER_ROOT="$root" CRONTAB_BIN="$fake_bin" FAKE_CRONTAB="$fake_crontab" "$installer" >/dev/null
done
[[ "$(grep -Fc '# relay-consumed-archiver' "$fake_crontab")" == 1 ]]
grep -F '*/10 * * * *' "$fake_crontab" >/dev/null
grep -F '0 1 * * * true # unrelated' "$fake_crontab" >/dev/null
echo 'PASS schedule idempotent 10-minute cron'

echo 'PASS relay-consumed-archiver suite'

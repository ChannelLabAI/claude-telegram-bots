#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

relay_dir="$fixture/relay"
RELAY_DIR="$relay_dir" "$repo/shared/bin/evening-journal-all.sh" >/dev/null
relay_file="$(find "$relay_dir" -maxdepth 1 -type f -name '*-evening-Anyachl_bot.json' -print -quit)"
[[ -n "$relay_file" ]]
[[ "$(find "$relay_dir" -maxdepth 1 -type f -name '*.tmp' | wc -l)" == "0" ]]
jq -e '
  .from_bot == "system"
  and .chat_id == "self"
  and (.text | contains("@Anyachl_bot"))
  and (.text | contains("WorkJournal.md"))
' "$relay_file" >/dev/null

fake_crontab="$fixture/crontab.txt"
fake_bin="$fixture/crontab"
printf '%s\n' '0 1 * * * true # unrelated' > "$fake_crontab"
sed -n 'p' > "$fake_bin" <<'FAKE_CRONTAB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-l" ]]; then
  if [[ -f "$FAKE_CRONTAB" ]]; then
    cat "$FAKE_CRONTAB"
  else
    echo "no crontab for test" >&2
    exit 1
  fi
else
  cp "$1" "$FAKE_CRONTAB"
fi
FAKE_CRONTAB
chmod +x "$fake_bin"

echo "reverse_count=$(grep -c evening-journal-all "$fake_crontab" || true)"
for run in 1 2; do
  EVENING_JOURNAL_ROOT="$repo" CRONTAB_BIN="$fake_bin" FAKE_CRONTAB="$fake_crontab" \
    "$repo/shared/bin/install-evening-journal-cron.sh" >/dev/null
  echo "install_${run}_count=$(grep -c evening-journal-all "$fake_crontab" || true)"
done

[[ "$(grep -c evening-journal-all "$fake_crontab" || true)" == "1" ]]
grep -F '0 1 * * * true # unrelated' "$fake_crontab" >/dev/null
grep -F '3 18 * * *' "$fake_crontab" >/dev/null

echo 'relay_json:'
jq . "$relay_file"

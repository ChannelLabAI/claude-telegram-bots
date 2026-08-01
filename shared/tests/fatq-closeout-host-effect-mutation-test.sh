#!/usr/bin/env bash
# Prove the negative fixture owns the guard: remove the marked call in an
# isolated candidate, observe the fixture turn red, restore, then cmp exactly.
set -uo pipefail

CLI_SH="${1:?usage: $0 <fatq-cli.sh> <fatq-verify.sh>}"
VERIFY_SH="${2:?usage: $0 <fatq-cli.sh> <fatq-verify.sh>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shared/bin" "$tmp/shared/lib"
cp -a "$(dirname "$CLI_SH")/../lib/." "$tmp/shared/lib/"
candidate="$tmp/shared/bin/fatq-cli.sh"
backup="$tmp/shared/bin/fatq-cli.sh.orig"
cp "$CLI_SH" "$candidate"
cp "$candidate" "$backup"

# Green baseline: the unmodified candidate blocks the missing registration.
bash "$(dirname "$0")/fatq-closeout-host-effect-fixture.sh" \
  "$candidate" "$VERIFY_SH" "$tmp/original-fixture" >/dev/null 2>&1 || exit 1

sed -i '/verify_host_effect_or_die .*# HOST_EFFECT_GUARD$/d' "$candidate"
cmp -s "$candidate" "$backup" && exit 1

fixture_rc=0
bash "$(dirname "$0")/fatq-closeout-host-effect-fixture.sh" \
  "$candidate" "$VERIFY_SH" "$tmp/mutant-fixture" >/dev/null 2>&1 || fixture_rc=$?
[[ "$fixture_rc" -ne 0 ]] || exit 1

cp "$backup" "$candidate"
cmp -s "$candidate" "$backup" || exit 1
exit 0

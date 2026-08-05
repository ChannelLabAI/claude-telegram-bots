#!/usr/bin/env bash
# Host-only PATH proof. Starts an isolated transient user unit and prints the
# effective PATH from /proc plus the resolved Bun binary. It does not alter
# keeper-diana.service or any production file.
set -euo pipefail

unit="keeper-diana-path-selftest-${$}.service"
path="/home/oldrabbit/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cleanup() {
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user reset-failed "$unit" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

systemd-run --user --unit="$unit" --property=Type=exec --collect \
  --setenv="PATH=$path" \
  /bin/bash -c 'tr "\0" "\n" < /proc/self/environ | grep "^PATH="; command -v bun; sleep 20'

for _ in 1 2 3 4 5; do
  pid=$(systemctl --user show "$unit" -p MainPID --value)
  [[ "$pid" != 0 && -n "$pid" ]] && break
  sleep 1
done
[[ "$pid" != 0 && -n "$pid" ]]
path_line=$(tr '\0' '\n' < "/proc/$pid/environ" | grep '^PATH=')
echo "$path_line"
PATH="${path_line#PATH=}" command -v bun
echo "PASS: isolated PATH proof unit $unit"

#!/usr/bin/env bash
# systemd active alone is not proof of a working Diana listener.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1002}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1002/bus}"
unit=${DIANA_UNIT:-keeper-diana.service}
state=${DIANA_BATCH_STATE:-/home/oldrabbit/.claude-bots/bots/keeper/batch-state.json}
systemctl_bin=${DIANA_SYSTEMCTL_BIN:-systemctl}
cgroup_root=${DIANA_CGROUP_ROOT:-/sys/fs/cgroup}
proc_root=${DIANA_PROC_ROOT:-/proc}
test -r "$state" || { echo "DENY health: missing batch-state.json" >&2; exit 2; }
last_run=$(jq -r '.last_run // empty' "$state")
test -n "$last_run" || { echo "DENY health: missing last_run" >&2; exit 2; }
cg=$($systemctl_bin --user show --property=ControlGroup --value "$unit")
test -n "$cg" && test -r "$cgroup_root${cg}/cgroup.procs" || { echo "DENY health: no unit cgroup" >&2; exit 2; }
found=0
while read -r pid; do
  tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null | grep -q '[r]elay-listener.ts' && found=1
done < "$cgroup_root${cg}/cgroup.procs"
test "$found" = 1 || { echo "DENY health: listener absent from unit cgroup" >&2; exit 2; }
echo "OK batch_last_run=$last_run listener_in_cgroup=1"

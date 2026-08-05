#!/usr/bin/env bash
# Sole execution point for six prewritten recovery actions. No shell fragments.
set -euo pipefail
root=${DIANA_ROOT:-/home/oldrabbit/.claude-bots}
action=${1:?action id required}; shift
audit_dir=${DIANA_OPS_AUDIT_DIR:-$root/logs/diana-ops}; mkdir -p "$audit_dir"
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
execute=${DIANA_OPS_EXECUTE:-1}
audit() { printf '%s action=%s result=%s reason=%s mode=%s\n' "$stamp" "$action" "$1" "$2" "$([[ "$execute" = 1 ]] && printf execute || printf dry_run)" >> "$audit_dir/actions.log"; }
# Keep the executable boundary in lockstep with resident-supervisor.sh.  Tests
# inject DIANA_BUN_BIN; production resolves it from the service user's HOME.
bun_bin=${DIANA_BUN_BIN:-"$HOME/.bun/bin/bun"}
if ! "$bun_bin" run "$root/shared/diana-resident/authorize-action.ts" "$action"; then audit DENY authorization_rejected; exit 2; fi
# Persistently limit every recovery-action attempt, including failures, so a
# retry loop cannot bypass the keeper-batch circuit breaker.
circuit_db=${DIANA_OPS_CIRCUIT_DB:-$root/memory.db}
circuit_window_secs=${DIANA_OPS_CIRCUIT_WINDOW_SECS:-300}
circuit_threshold=${DIANA_OPS_CIRCUIT_THRESHOLD:-3}
[[ "$circuit_window_secs" =~ ^[1-9][0-9]*$ && "$circuit_threshold" =~ ^[1-9][0-9]*$ ]] || { audit DENY bad_circuit_config; exit 2; }
sqlite3 "$circuit_db" 'CREATE TABLE IF NOT EXISTS diana_action_circuit (action TEXT NOT NULL, ts INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS diana_action_circuit_action_ts ON diana_action_circuit(action, ts);'
now_epoch=${DIANA_NOW_EPOCH:-$(date +%s)}
[[ "$now_epoch" =~ ^[0-9]+$ ]] || { audit DENY bad_clock; exit 2; }
recent_attempts=$(sqlite3 "$circuit_db" "SELECT COUNT(*) FROM diana_action_circuit WHERE action = '$(printf %s "$action" | sed "s/'/''/g")' AND ts >= $((now_epoch - circuit_window_secs));")
if (( recent_attempts >= circuit_threshold )); then audit DENY circuit_open; exit 2; fi
sqlite3 "$circuit_db" "INSERT INTO diana_action_circuit(action, ts) VALUES ('$(printf %s "$action" | sed "s/'/''/g")', $now_epoch);"
case "$action" in
 restart_approved_pod) pod=${1:-}; [[ "$pod" =~ ^[a-z0-9][a-z0-9-]{0,62}$ && -f "$root/pod-system/pods/$pod.json" ]] || { audit DENY bad_pod; exit 2; }; [[ "$execute" = 1 ]] || { audit DRY_RUN explicit_execute_required; exit 0; }; systemctl --user restart "pod@$pod.service"; audit OK "pod@$pod" ;;
 clean_expired_clone|clean_disk) [[ "$execute" = 1 ]] || { audit DRY_RUN explicit_execute_required; exit 0; }; "$root/shared/bin/clone-ttl-cleaner.sh" --apply; audit OK 2438_cleaner ;;
 terminate_verified_orphan)
   pid=${1:-}; proc_root=${DIANA_PROC_ROOT:-/proc}; cgroup_root=${DIANA_CGROUP_ROOT:-/sys/fs/cgroup}; activity_root=${DIANA_ORPHAN_ACTIVITY_ROOT:-/run/user/1002/diana-orphan-activity}; now=${DIANA_NOW_EPOCH:-$(date +%s)}; idle_secs=${DIANA_ORPHAN_IDLE_SECS:-900}; sampler_max_stale_secs=${DIANA_ORPHAN_SAMPLER_MAX_STALE_SECS:-900}
   [[ "$pid" =~ ^[1-9][0-9]*$ && "$idle_secs" =~ ^[0-9]+$ && "$sampler_max_stale_secs" =~ ^[1-9][0-9]*$ && -r "$proc_root/$pid/status" && -r "$proc_root/$pid/cgroup" ]] || { audit DENY role_not_verified; exit 2; }
   ppid=$(awk '/^PPid:/ {print $2; exit}' "$proc_root/$pid/status")
   [[ "$ppid" =~ ^[0-9]+$ && ! -e "$proc_root/$ppid" ]] || { audit DENY parent_still_alive; exit 2; }
   ! grep -Eq '(^|/)pod@[^/]+\.service($|/)' "$proc_root/$pid/cgroup" || { audit DENY belongs_to_pod_cgroup; exit 2; }
   activity_file="$activity_root/$pid.last_activity"
   [[ -f "$activity_file" ]] || { audit DENY no_idle_evidence; exit 2; }
   sampled_file="$activity_root/$pid.last_sampled"
   [[ -f "$sampled_file" ]] || { audit DENY sampler_stale; exit 2; }
   last_sampled=$(stat -c %Y "$sampled_file")
   [[ "$last_sampled" =~ ^[0-9]+$ && $((now - last_sampled)) -le sampler_max_stale_secs ]] || { audit DENY sampler_stale; exit 2; }
   last_activity=$(stat -c %Y "$activity_file")
   [[ "$last_activity" =~ ^[0-9]+$ && $((now - last_activity)) -ge idle_secs ]] || { audit DENY not_idle_long_enough; exit 2; }
   [[ "$execute" = 1 ]] || { audit DRY_RUN verified_orphan; exit 0; }; kill -TERM "$pid"; audit OK "verified_orphan_pid=$pid" ;;
 # No execution interface exists for either operation.  They are deliberately
 # out of B1 scope rather than pretending that the scanner/CLI accepts a task.
 clear_stale_fatq_lock|redispatch_stuck_task) audit DENY unavailable_interface; exit 2 ;;
 *) audit DENY unknown_action; exit 2 ;;
esac

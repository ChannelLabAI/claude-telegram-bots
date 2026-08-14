#!/usr/bin/env bash
set -euo pipefail
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; BASE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT"/{shared/{bin,config,lib},tasks/{pending,in_progress,review,archived},relay,logs,pod-system/pods}
cp "$BASE/bin/patrol-scan.sh" "$ROOT/shared/bin/"; cp "$BASE/lib/fatq-blocking.sh" "$ROOT/shared/lib/"; cp "$BASE/config/patrol-scan.json" "$ROOT/shared/config/"; chmod +x "$ROOT/shared/bin/patrol-scan.sh"
NOW=1785000000; old=$((NOW-20000))
printf '%s\n' '{"task_id":"overdue-pending","assigned":"sancai","history":[]}' > "$ROOT/tasks/pending/overdue.json"
printf '%s\n' '{"task_id":"20260724-1636-2f71-evidence","history":[]}' > "$ROOT/tasks/pending/whitelisted.json"
printf '%s\n' '{"recipient":"Twinkle"}' > "$ROOT/relay/stale.json"
printf '%s\n' '{"recipient":"symlink-health-loop"}' > "$ROOT/relay/whitelisted.json"
printf '%s\n' '{"bots":[{"name":"twinkle","username":"TwinkleCHL_bot"}]}' > "$ROOT/pod-system/pods/builder.json"
printf '%s\n' '{"task_id":"8505","history":[]}' > "$ROOT/tasks/review/8505.json"
touch -d "@$NOW" "$ROOT/tasks/review/8505.json"
touch -d "@$old" "$ROOT/tasks/pending/"*.json "$ROOT/relay/"*.json
printf '[%s] EVENT: detected %s\n' "$(date -d "@$old" '+%F %T')" "$ROOT/tasks/review/8505.json" > "$ROOT/logs/inotify-watch.log"
touch -d "@$old" "$ROOT/logs/inotify-watch.log"
# Only daemon command lines count. These three non-daemon lines model the
# high-activity false positives that used to inflate the broad pgrep count.
for _ in $(seq 1 15); do printf '%s\n' 'bun run gateway.ts'; done > "$ROOT/ps"
printf '%s\n' \
  'codex exec --cwd /home/oldrabbit/.claude-bots/gateway-builder implement patrol' \
  'claude -p headless worker: delivery instructions mention gateway' \
  'bash /tmp/test-gateway.sh' >> "$ROOT/ps"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/first.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("overdue.json") and contains("stale.json") and contains("8505"))' "$ROOT/first.json" >/dev/null
jq -e 'any(.checks[]; .check=="gateway_processes" and .status=="pass" and (.evidence|contains("count=15")))' "$ROOT/first.json" >/dev/null
test "$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)" -eq 1
# The same persistent failures have different age/mtime_age values next round,
# but their normalized signature must still suppress a duplicate alert.
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$((NOW+60))" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/second.json"
jq -e --slurpfile first "$ROOT/first.json" '
  .status=="fail"
  and ([.failures[]]|join("\n")|contains("mtime_age=20060s") and contains("age=20060s"))
  and (($first[0].failures|join("\n"))|contains("mtime_age=20000s") and contains("age=20000s"))
' "$ROOT/second.json" >/dev/null
test "$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)" -eq 1
test "$(wc -l < "$ROOT/logs/patrol-scan-alert-state.jsonl")" -eq 1
rm "$ROOT/tasks/pending/overdue.json" "$ROOT/tasks/review/8505.json" "$ROOT/relay/stale.json"
printf '%s\n' '[x] EVENT: detected /x/tasks/review/ok.json' '[x] INFO: injected notification → bella/inbox/messages/x.json' > "$ROOT/logs/inotify-watch.log"
touch -d "@$old" "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/green.json"
jq -e '.status=="pass"' "$ROOT/green.json" >/dev/null
# Production-shaped counterexample: unrelated paired traffic refreshes the log
# mtime, but an old missing EVENT must still raise an alert from its own time.
lost=$((NOW-500)); recent=$((NOW-5))
printf '%s\n' '{"task_id":"LOSTNOTIFY","history":[]}' > "$ROOT/tasks/pending/LOSTNOTIFY.json"
touch -d "@$NOW" "$ROOT/tasks/pending/LOSTNOTIFY.json"
printf '[%s] EVENT: detected %s\n[%s] EVENT: detected %s\n[%s] INFO: injected notification → bella/inbox/messages/x.json\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/pending/LOSTNOTIFY.json" "$(date -d "@$recent" '+%F %T')" "$ROOT/tasks/review/unrelated.json" "$(date -d "@$recent" '+%F %T')" > "$ROOT/logs/inotify-watch.log"
touch -d "@$NOW" "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/busy-log.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("LOSTNOTIFY") and contains("age=500s"))' "$ROOT/busy-log.json" >/dev/null
rm "$ROOT/tasks/pending/LOSTNOTIFY.json"
# A state transition resolves an unpaired EVENT at its original path. The
# destination file is deliberately retained to model an atomic FATQ move,
# including the archived/ destination outside the active core states.
printf '%s\n' '{"task_id":"MOVED-AFTER-EVENT","history":[]}' > "$ROOT/tasks/in_progress/MOVED-AFTER-EVENT.json"
touch -d "@$NOW" "$ROOT/tasks/in_progress/MOVED-AFTER-EVENT.json"
printf '[%s] EVENT: detected %s\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/in_progress/MOVED-AFTER-EVENT.json" > "$ROOT/logs/inotify-watch.log"
mv "$ROOT/tasks/in_progress/MOVED-AFTER-EVENT.json" "$ROOT/tasks/archived/MOVED-AFTER-EVENT.json"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/resolved-transition.json"
jq -e '
  .status=="pass"
  and any(.checks[]; .check=="event_injected" and .status=="pass"
    and (.evidence|contains("resolved-by-transition"))
    and (.evidence|contains("/tasks/archived/"))
    and (.evidence|contains("MOVED-AFTER-EVENT")))
' "$ROOT/resolved-transition.json" >/dev/null
# A missing original path is not enough to prove a state transition. If no
# same-named task exists in any legal FATQ state, preserve the overdue alert.
printf '[%s] EVENT: detected %s\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/in_progress/VANISHED-TASK.json" > "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/vanished-task.json"
jq -e '
  .status=="fail"
  and any(.checks[]; .check=="event_injected" and .status=="fail"
    and (.evidence|contains("vanished task"))
    and (.evidence|contains("VANISHED-TASK"))
    and (.evidence|contains("age=500s")))
' "$ROOT/vanished-task.json" >/dev/null
# A whitelist entry matches only the missing EVENT task path/task id. It must
# suppress that task while active, leave another task unsuppressed, and stop
# suppressing the original task after expires_at.
whitelist_expiry=$((NOW+300))
jq --arg expires "$(date -u -d "@$whitelist_expiry" +%FT%TZ)" \
  '.whitelist += [{"match":"EVENT-WHITELIST","expires_at":$expires,"reason":"fixture"}]' \
  "$ROOT/shared/config/patrol-scan.json" > "$ROOT/shared/config/patrol-scan.json.tmp"
mv "$ROOT/shared/config/patrol-scan.json.tmp" "$ROOT/shared/config/patrol-scan.json"
printf '%s\n' '{"task_id":"EVENT-WHITELIST","history":[]}' > "$ROOT/tasks/review/EVENT-WHITELIST.json"
touch -d "@$NOW" "$ROOT/tasks/review/EVENT-WHITELIST.json"
printf '[%s] EVENT: detected %s\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/review/EVENT-WHITELIST.json" > "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/event-whitelisted.json"
jq -e '.status=="pass" and any(.checks[]; .check=="event_injected" and .status=="pass" and (.evidence|contains("EVENT-WHITELIST")))' "$ROOT/event-whitelisted.json" >/dev/null
printf '%s\n' '{"task_id":"EVENT-NOT-WHITELISTED","history":[]}' > "$ROOT/tasks/review/EVENT-NOT-WHITELISTED.json"
touch -d "@$NOW" "$ROOT/tasks/review/EVENT-NOT-WHITELISTED.json"
printf '[%s] EVENT: detected %s\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/review/EVENT-NOT-WHITELISTED.json" > "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/event-not-whitelisted.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("EVENT-NOT-WHITELISTED"))' "$ROOT/event-not-whitelisted.json" >/dev/null
printf '[%s] EVENT: detected %s\n' "$(date -d "@$lost" '+%F %T')" "$ROOT/tasks/review/EVENT-WHITELIST.json" > "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$((whitelist_expiry+1))" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/event-whitelist-expired.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("EVENT-WHITELIST"))' "$ROOT/event-whitelist-expired.json" >/dev/null
printf '%s\n' '[x] EVENT: detected /x/tasks/review/ok.json' '[x] INFO: injected notification → bella/inbox/messages/x.json' > "$ROOT/logs/inotify-watch.log"
relays_before_gateway="$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)"
# Increasing real daemon commands must still trigger the tolerance alert;
# non-daemon gateway-looking lines above remain excluded from the count.
for _ in $(seq 1 3); do printf '%s\n' '/usr/local/bin/bun run /srv/gateway-builder/gateway.ts'; done >> "$ROOT/ps"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$((NOW+700))" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/gateway-first.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("gateway_processes: count=18"))' "$ROOT/gateway-first.json" >/dev/null
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$((NOW+760))" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/gateway-second.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("gateway_processes: count=18"))' "$ROOT/gateway-second.json" >/dev/null
test "$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)" -eq "$((relays_before_gateway+1))"
echo 'PASS patrol-scan fixture: alerts, dynamic bot roster, task/event whitelist expiry, age/mtime_age/gateway-count dedup, own-timestamp EVENT pairing, busy-log counterexample, archived state transition, vanished-task and existing-path 8505 regressions, green trace'

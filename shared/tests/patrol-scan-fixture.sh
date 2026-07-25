#!/usr/bin/env bash
set -euo pipefail
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; BASE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT"/{shared/{bin,config},tasks/{pending,in_progress,review},relay,logs,pod-system/pods}
cp "$BASE/bin/patrol-scan.sh" "$ROOT/shared/bin/"; cp "$BASE/config/patrol-scan.json" "$ROOT/shared/config/"; chmod +x "$ROOT/shared/bin/patrol-scan.sh"
NOW=1785000000; old=$((NOW-20000))
printf '%s\n' '{"task_id":"overdue-pending","assigned":"sancai","history":[]}' > "$ROOT/tasks/pending/overdue.json"
printf '%s\n' '{"task_id":"2f71-evidence","history":[]}' > "$ROOT/tasks/pending/whitelisted.json"
printf '%s\n' '{"recipient":"Twinkle"}' > "$ROOT/relay/stale.json"
printf '%s\n' '{"recipient":"symlink-health-loop"}' > "$ROOT/relay/whitelisted.json"
printf '%s\n' '{"bots":[{"name":"twinkle","username":"TwinkleCHL_bot"}]}' > "$ROOT/pod-system/pods/builder.json"
touch -d "@$old" "$ROOT/tasks/pending/"*.json "$ROOT/relay/"*.json
printf '[%s] EVENT: detected /x/tasks/review/8505.json\n' "$(date -d "@$old" '+%F %T')" > "$ROOT/logs/inotify-watch.log"
touch -d "@$old" "$ROOT/logs/inotify-watch.log"; seq 1 15 > "$ROOT/ps"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/first.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("overdue.json") and contains("stale.json") and contains("8505"))' "$ROOT/first.json" >/dev/null
test "$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)" -eq 1
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" >/dev/null
test "$(find "$ROOT/relay" -name 'patrol-scan-*' | wc -l)" -eq 1
rm "$ROOT/tasks/pending/overdue.json" "$ROOT/relay/stale.json"
printf '%s\n' '[x] EVENT: detected /x/tasks/review/ok.json' '[x] INFO: injected notification → bella/inbox/messages/x.json' > "$ROOT/logs/inotify-watch.log"
touch -d "@$old" "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/green.json"
jq -e '.status=="pass"' "$ROOT/green.json" >/dev/null
# Production-shaped counterexample: unrelated paired traffic refreshes the log
# mtime, but an old missing EVENT must still raise an alert from its own time.
lost=$((NOW-500)); recent=$((NOW-5))
printf '[%s] EVENT: detected /x/tasks/pending/LOSTNOTIFY.json\n[%s] EVENT: detected /x/tasks/review/unrelated.json\n[%s] INFO: injected notification → bella/inbox/messages/x.json\n' "$(date -d "@$lost" '+%F %T')" "$(date -d "@$recent" '+%F %T')" "$(date -d "@$recent" '+%F %T')" > "$ROOT/logs/inotify-watch.log"
touch -d "@$NOW" "$ROOT/logs/inotify-watch.log"
PATROL_ROOT="$ROOT" PATROL_NOW_EPOCH="$NOW" PATROL_PS_FILE="$ROOT/ps" "$ROOT/shared/bin/patrol-scan.sh" > "$ROOT/busy-log.json"
jq -e '.status=="fail" and ([.failures[]]|join("\n")|contains("LOSTNOTIFY") and contains("age=500s"))' "$ROOT/busy-log.json" >/dev/null
echo 'PASS patrol-scan fixture: alerts, dynamic bot roster, whitelist, dedup, own-timestamp EVENT pairing, busy-log counterexample, green trace'

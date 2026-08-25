#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
listener_pid=""
cleanup() {
  if [ -n "$listener_pid" ]; then kill "$listener_pid" 2>/dev/null || true; wait "$listener_pid" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT
pm="$fixture/pm-hub"
state="$fixture/state"
relay="$fixture/relay-diana"
inbox="$fixture/inbox"
mkdir -p "$pm/projects" "$state" "$relay" "$inbox"

git -C "$pm" init -q
git -C "$pm" config user.name fixture
git -C "$pm" config user.email fixture@example.test
cat > "$pm/projects/demo.md" <<'EOF'
---
id: demo
name: Demo
brief: initial
---

## 摘要
Initial summary.

## 任務

## 事件

## 日誌
- 2026-08-24 [建表] baseline （fixture）
EOF
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm baseline

export DIANA_GROOM_PM_ROOT="$pm"
export DIANA_GROOM_STATE_DIR="$state"
export DIANA_GROOM_RELAY_DIR="$relay"
export DIANA_GROOM_NOW_EPOCH=2000000000
groom="$repo/shared/bin/diana-groom.sh"
"$groom" init >/dev/null

cat >> "$pm/projects/demo.md" <<'EOF'
- 2026-08-25 [任務] 啟動 fixture @anna due:2026-08-29 （fixture）
- 2026-08-25 [事件] 2026-08-30 發布 fixture （fixture）
- 2026-08-25 [摘要] 三筆資訊已整合 （fixture）
EOF
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm 'add three groom inputs'
source_commit="$(git -C "$pm" rev-parse HEAD)"

# AC1 event track: three inputs become relay signals and disk-inbox jobs.
out="$("$groom" event --commit "$source_commit")"
[ "$(jq -r .emitted <<<"$out")" = 3 ]
[ "$(find "$relay" -maxdepth 1 -name '*diana-groom.json' | wc -l)" = 3 ]
for relay_file in "$relay"/*diana-groom.json; do
  DIANA_RELAY_DIR="$relay" DIANA_CHAT_INBOX_DIR="$inbox" \
    bun run "$repo/bots/keeper/relay-listener.ts" --process-once "$relay_file" >/dev/null
done
[ "$(find "$inbox" -maxdepth 1 -name '*.json' | wc -l)" = 3 ]
find "$inbox" -maxdepth 1 -name '*.json' -print0 | xargs -0 -n1 jq -e '.params.content | startswith("diana:task")' >/dev/null

# AC3: safety net sees the same three inputs but emits no duplicate.
out="$("$groom" sweep --since '24 hours ago')"
[ "$(jq -r .emitted <<<"$out")" = 0 ]

make_candidate() {
  local key="$1" kind="$2" candidate="$3"
  python3 - "$pm/projects/demo.md" "$key" "$kind" "$candidate" <<'PY'
from pathlib import Path
import sys
p, key, kind, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
text = p.read_text()
if kind == "task":
    text = text.replace("## 任務\n", "## 任務\n- [ ] 啟動 fixture @anna due:2026-08-29\n", 1)
elif kind == "event":
    text = text.replace("## 事件\n", "## 事件\n- 2026-08-30 [release] 發布 fixture @anna\n", 1)
else:
    text = text.replace("Initial summary.", "Initial summary. 三筆資訊已整合。", 1)
text += f"- 2026-08-26 [整理] {kind} 歸位；依據 {key}\n"
out.write_text(text)
PY
}

task_key="$(jq -r '.entries[] | select(.status=="queued" and (.entry | contains("[任務]"))) | .source_key' "$state/state.json")"
event_key="$(jq -r '.entries[] | select(.status=="queued" and (.entry | contains("[事件]"))) | .source_key' "$state/state.json")"
summary_key="$(jq -r '.entries[] | select(.status=="queued" and (.entry | contains("[摘要]"))) | .source_key' "$state/state.json")"
keys=("$task_key" "$event_key" "$summary_key")
kinds=(task event summary)
[ "${#keys[@]}" = 3 ]

# AC4 malicious historical-log deletion is mechanically refused while queued.
bad="$fixture/bad.md"
sed '/baseline/d; s/Initial summary/Changed summary/' "$pm/projects/demo.md" > "$bad"
if "$groom" apply --project "$pm/projects/demo.md" --source-key "${keys[0]}" --candidate "$bad" >/dev/null 2>&1; then
  echo 'historical log deletion unexpectedly accepted' >&2
  exit 1
fi

for i in 0 1 2; do
  candidate="$fixture/candidate-$i.md"
  make_candidate "${keys[$i]}" "${kinds[$i]}" "$candidate"
  "$groom" apply --project "$pm/projects/demo.md" --source-key "${keys[$i]}" --candidate "$candidate" >/dev/null
done
grep -q -- '- \[ \] 啟動 fixture' "$pm/projects/demo.md"
grep -q -- '- 2026-08-30 \[release\] 發布 fixture' "$pm/projects/demo.md"
grep -q '三筆資訊已整合。' "$pm/projects/demo.md"
[ "$(grep -c '\[整理\]' "$pm/projects/demo.md")" = 3 ]
[ "$(git -C "$pm" log -3 --format=%an | sort -u)" = diana ]

# Event watcher: a projects/*.md change automatically reaches disk inbox.
watch_inbox="$fixture/watch-inbox"
mkdir -p "$watch_inbox"
DIANA_RELAY_DIR="$relay" DIANA_CHAT_INBOX_DIR="$watch_inbox" \
DIANA_GROOM_PROJECTS_DIR="$pm/projects" DIANA_GROOM_SCRIPT="$groom" \
  bun run "$repo/bots/keeper/relay-listener.ts" >"$fixture/watcher.log" 2>&1 &
listener_pid=$!
for _ in $(seq 1 50); do grep -q 'watching Diana groom projects' "$fixture/watcher.log" && break; sleep 0.1; done
grep -q 'watching Diana groom projects' "$fixture/watcher.log"
cat >> "$pm/projects/demo.md" <<'EOF'
- 2026-08-26 [任務] watcher fixture @anna （fixture）
EOF
for _ in $(seq 1 50); do find "$watch_inbox" -maxdepth 1 -name '*.json' -print -quit | grep -q . && break; sleep 0.1; done
watch_job="$(find "$watch_inbox" -maxdepth 1 -name '*.json' -print -quit)"
jq -e '.params.meta.source == "diana-groom" and (.params.meta.entry | contains("watcher fixture"))' "$watch_job" >/dev/null
kill "$listener_pid"
wait "$listener_pid" 2>/dev/null || true
listener_pid=""
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm 'add watcher input'

# AC2 independent missed-event fixture: sweep alone queues the input.
state2="$fixture/state2"
relay2="$fixture/relay2"
DIANA_GROOM_STATE_DIR="$state2" DIANA_GROOM_RELAY_DIR="$relay2" "$groom" init >/dev/null
cat >> "$pm/projects/demo.md" <<'EOF'
- 2026-08-26 [任務] safety-only fixture @anna （fixture）
EOF
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm 'add missed event input'
out="$(DIANA_GROOM_STATE_DIR="$state2" DIANA_GROOM_RELAY_DIR="$relay2" "$groom" sweep --since '24 hours ago')"
[ "$(jq -r .emitted <<<"$out")" = 1 ]
jq -e '.meta.track | startswith("safety-net")' "$relay2"/*diana-groom.json >/dev/null

# Regression: identical text at two append-only positions is two real inputs.
# The event track must emit the later occurrence, and a missed event must be
# recovered by the safety net instead of colliding with the first occurrence.
state3="$fixture/state3"
relay3="$fixture/relay3"
DIANA_GROOM_STATE_DIR="$state3" DIANA_GROOM_RELAY_DIR="$relay3" "$groom" init >/dev/null
duplicate='- 2026-08-26 [事件] 部署完成（duplicate fixture）'
printf '%s\n' "$duplicate" >> "$pm/projects/demo.md"
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm 'add first duplicate-text input'
first_duplicate_commit="$(git -C "$pm" rev-parse HEAD)"
out="$(DIANA_GROOM_STATE_DIR="$state3" DIANA_GROOM_RELAY_DIR="$relay3" "$groom" event --commit "$first_duplicate_commit")"
[ "$(jq -r .emitted <<<"$out")" = 1 ]

printf '%s\n' "$duplicate" >> "$pm/projects/demo.md"
git -C "$pm" add projects/demo.md
git -C "$pm" commit -qm 'add second duplicate-text input'
second_duplicate_commit="$(git -C "$pm" rev-parse HEAD)"
out="$(DIANA_GROOM_STATE_DIR="$state3" DIANA_GROOM_RELAY_DIR="$relay3" "$groom" event --commit "$second_duplicate_commit")"
[ "$(jq -r .emitted <<<"$out")" = 1 ]
[ "$(jq '[.entries[] | select(.entry | contains("duplicate fixture"))] | length' "$state3/state.json")" = 2 ]
[ "$(jq '[.entries[] | select(.entry | contains("duplicate fixture")) | .entry_occurrence] | sort | join(",")' -r "$state3/state.json")" = '1,2' ]
out="$(DIANA_GROOM_STATE_DIR="$state3" DIANA_GROOM_RELAY_DIR="$relay3" "$groom" sweep --since '24 hours ago')"
[ "$(jq -r .emitted <<<"$out")" = 0 ]

state4="$fixture/state4"
relay4="$fixture/relay4"
git -C "$pm" checkout -q "$first_duplicate_commit"
DIANA_GROOM_STATE_DIR="$state4" DIANA_GROOM_RELAY_DIR="$relay4" "$groom" init >/dev/null
git -C "$pm" checkout -q "$second_duplicate_commit"
out="$(DIANA_GROOM_STATE_DIR="$state4" DIANA_GROOM_RELAY_DIR="$relay4" "$groom" sweep --since '24 hours ago')"
[ "$(jq -r .emitted <<<"$out")" = 1 ]
jq -e '.meta.track == "safety-net" and .meta.entry_occurrence == 2' "$relay4"/*diana-groom.json >/dev/null

# Cron installer is idempotent and preserves unrelated entries.
fake_crontab="$fixture/fake-crontab"
fake_bin="$fixture/crontab"
printf '%s\n' '0 1 * * * true # unrelated' > "$fake_crontab"
cat > "$fake_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB"; else cp "$1" "$FAKE_CRONTAB"; fi
EOF
chmod +x "$fake_bin"
FAKE_CRONTAB="$fake_crontab" CRONTAB_BIN="$fake_bin" "$repo/shared/bin/install-diana-groom-cron.sh"
FAKE_CRONTAB="$fake_crontab" CRONTAB_BIN="$fake_bin" "$repo/shared/bin/install-diana-groom-cron.sh"
[ "$(grep -c '# diana-groom$' "$fake_crontab")" = 1 ]
grep -q '^20 9 ' "$fake_crontab"
grep -q '# unrelated' "$fake_crontab"

echo 'diana-groom fixtures: PASS (AC1-AC4)'

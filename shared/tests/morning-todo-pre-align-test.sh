#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
TEST_HOME="$FIX/home"
mkdir -p "$FIX/tasks/done" "$FIX/tasks/in_progress" "$TEST_HOME/.claude-bots/relay" "$TEST_HOME/Documents/Obsidian Vault - OldRabbit/00Daily" "$TEST_HOME/Documents/Obsidian Vault - Ron/00Daily"
cat > "$FIX/tasks/done/legacy.json" <<'JSON'
{"task_id":"bq7c","status":"done"}
JSON
cat > "$FIX/tasks/done/terminal.json" <<'JSON'
{"task_id":"20260725-1000-dead-fake-completed-item","status":"done"}
JSON
cat > "$FIX/tasks/done/short-terminal.json" <<'JSON'
{"task_id":"20260725-1001-c3c8-short-terminal-item","status":"done"}
JSON
cat > "$FIX/tasks/in_progress/active.json" <<'JSON'
{"task_id":"20260725-1002-9a48-active-item","status":"in_progress"}
JSON
cat > "$TEST_HOME/Documents/Obsidian Vault - OldRabbit/00Daily/日誌總結.md" <<'EOF'
# summary
### 進行中
- 🟡 stale fixture 20260725-1000-dead-fake-completed-item
- 🟡 daily shorthand c3c8 should close through the unique short ID
- 🟡 active shorthand 9a48 should stay tracked
- 🟡 prose says face value, but has no FATQ task ID
- 🟡 cafe is prose, not a FATQ task reference
### 長期關注
keep these bytes exactly\n
EOF
cat > "$TEST_HOME/Documents/Obsidian Vault - Ron/00Daily/日誌總結.md" <<'EOF'
### 進行中
- 🟡 Ron output must remain unchanged
EOF
awk '/^### 長期關注/{on=1} on{print}' "$TEST_HOME/Documents/Obsidian Vault - OldRabbit/00Daily/日誌總結.md" > "$FIX/long-before"
sqlite3 "$FIX/anya.db" 'create table tasks (user_id text, created_at text, prompt text);'
sqlite3 "$FIX/anya.db" "insert into tasks values ('1050312492', datetime('now'), 'stale fixture 請結案');"
HOME="$TEST_HOME" MORNING_TODO_TASK_ROOT="$FIX/tasks" MORNING_TODO_ANYA_DB="$FIX/anya.db" "$ROOT/shared/bin/morning-todo-all.sh" > "$FIX/run.log"
VAULT="$TEST_HOME/Documents/Obsidian Vault - OldRabbit/00Daily/日誌總結.md"
awk '/^### 長期關注/{on=1} on{print}' "$VAULT" > "$FIX/long-after"
cmp "$FIX/long-before" "$FIX/long-after"
grep -Eq '✅ stale fixture.*已結案.*done' "$VAULT"
grep -Eq '✅ daily shorthand c3c8.*已結案.*done' "$VAULT"
grep -Eq '🟡 active shorthand 9a48.*FATQ 顯示仍在 in_progress，不需處置' "$VAULT"
grep -Eq '🟡 prose says face value.*FATQ 未找到對應單' "$VAULT"
grep -Eq '🟡 cafe is prose.*FATQ 未找到對應單' "$VAULT"
RELAY=$(find "$TEST_HOME/.claude-bots/relay" -name '*morning-Anyachl_bot.json' -print -quit)
! jq -r '.text' "$RELAY" | grep -Eq 'stale fixture'
! jq -r '.text' "$RELAY" | grep -Eq 'daily shorthand'
jq -r '.text' "$RELAY" | grep -Eq 'active shorthand 9a48.*FATQ 顯示仍在 in_progress，不需處置'
jq -r '.text' "$RELAY" | grep -Eq 'prose says face value.*FATQ 未找到對應單'
jq -r '.text' "$RELAY" | grep -Eq 'cafe is prose.*FATQ 未找到對應單'
jq -r '.text' "$RELAY" | grep -Eq '清單對齊：核對 5 項、自動結案 2 項、待核 3 項。'

# A second full run must keep pending/unknown entries in both the vault and
# the actual relay, without stacking the alignment annotation.
HOME="$TEST_HOME" MORNING_TODO_TASK_ROOT="$FIX/tasks" MORNING_TODO_ANYA_DB="$FIX/anya.db" "$ROOT/shared/bin/morning-todo-all.sh" >> "$FIX/run.log"
RELAY_DAY2=$(find "$TEST_HOME/.claude-bots/relay" -name '*morning-Anyachl_bot.json' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
grep -Eq '🟡 active shorthand 9a48.*FATQ 顯示仍在 in_progress，不需處置' "$VAULT"
jq -r '.text' "$RELAY_DAY2" | grep -Eq 'active shorthand 9a48.*FATQ 顯示仍在 in_progress，不需處置'
jq -r '.text' "$RELAY_DAY2" | grep -Eq 'prose says face value.*FATQ 未找到對應單'
test "$(grep -o 'FATQ 顯示仍在 in_progress，不需處置' "$VAULT" | wc -l | tr -d ' ')" = 1
test "$(grep -o 'FATQ 未找到對應單，待 Anya 核對' "$VAULT" | wc -l | tr -d ' ')" = 2
RON_RELAY=$(find "$TEST_HOME/.claude-bots/relay" -name '*morning-Ron0001_bot.json' -print -quit)
EXPECTED_RON=$'owner_dm\nchat_id: 5288537361\n@Ron0001_bot 早安提醒：請整理以下進行中焦點任務，挑出今天最需要關注的（3-5 項），用 TG 私訊 Ron。格式簡潔，不要貼原文。\n\n- 🟡 Ron output must remain unchanged'
test "$(jq -r '.text' "$RON_RELAY")" = "$EXPECTED_RON"

# Fault injection: an Anyachl-only aligner failure must fall back to the
# unaligned brief and must not suppress the independent relays for other bots.
FAIL_HOME="$FIX/fail-home"
mkdir -p "$FAIL_HOME/Documents/Obsidian Vault - OldRabbit/00Daily" "$FAIL_HOME/Documents/Obsidian Vault - Ron/00Daily" "$FAIL_HOME/.claude-bots/relay" "$FIX/fake-bin"
cp "$VAULT" "$FAIL_HOME/Documents/Obsidian Vault - OldRabbit/00Daily/日誌總結.md"
cp "$TEST_HOME/Documents/Obsidian Vault - Ron/00Daily/日誌總結.md" "$FAIL_HOME/Documents/Obsidian Vault - Ron/00Daily/日誌總結.md"
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
cat > "$FIX/fake-bin/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == *"morning-todo-align.py" ]]; then
  echo 'injected align failure' >&2
  exit 73
fi
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$FIX/fake-bin/python3"
HOME="$FAIL_HOME" PATH="$FIX/fake-bin:$PATH" MORNING_TODO_TASK_ROOT="$FIX/tasks" MORNING_TODO_ANYA_DB="$FIX/anya.db" "$ROOT/shared/bin/morning-todo-all.sh" >> "$FIX/run.log"
test "$(find "$FAIL_HOME/.claude-bots/relay" -name '*morning-*.json' | wc -l | tr -d ' ')" = 8
FAIL_RON=$(find "$FAIL_HOME/.claude-bots/relay" -name '*morning-Ron0001_bot.json' -print -quit)
test "$(jq -r '.text' "$FAIL_RON")" = "$EXPECTED_RON"
FAIL_ANYA=$(find "$FAIL_HOME/.claude-bots/relay" -name '*morning-Anyachl_bot.json' -print -quit)
jq -r '.text' "$FAIL_ANYA" | grep -Eq 'active shorthand 9a48'
! jq -r '.text' "$FAIL_ANYA" | grep -Eq '清單對齊：'
echo 'PASS live morning-todo-all pre-align fixture'

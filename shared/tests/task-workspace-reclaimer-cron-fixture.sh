#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
installer="$repo/shared/bin/install-task-workspace-reclaimer-cron.sh"
fixture="$(mktemp -d /tmp/task-workspace-reclaimer-cron.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
root="$fixture/root"
fake_crontab="$fixture/crontab.txt"
fake_bin="$fixture/crontab"
failing_bin="$fixture/crontab-failing"

mkdir -p "$root/shared/bin" "$root/tasks/done" "$root/tasks/work" "$root/tasks/worktrees"
cp "$repo/shared/bin/task-workspace-reclaimer.py" "$root/shared/bin/"
cp "$repo/shared/bin/clone-reclaim-safety.py" "$root/shared/bin/"
printf '%s\n' '0 1 * * * true # unrelated' > "$fake_crontab"
printf '%s\n' '5 1 * * * false # task-workspace-reclaimer' >> "$fake_crontab"
printf '%s\n' '6 1 * * * false # task-workspace-reclaimer' >> "$fake_crontab"

printf '%s\n' '#!/usr/bin/env bash' > "$fake_bin"
printf '%s\n' 'set -euo pipefail' >> "$fake_bin"
printf '%s\n' 'if [[ "${1:-}" == "-l" ]]; then' >> "$fake_bin"
printf '%s\n' '  [[ -f "$FAKE_CRONTAB" ]] && cat "$FAKE_CRONTAB"' >> "$fake_bin"
printf '%s\n' 'else' >> "$fake_bin"
printf '%s\n' '  cp "$1" "$FAKE_CRONTAB"' >> "$fake_bin"
printf '%s\n' 'fi' >> "$fake_bin"
chmod +x "$fake_bin"

printf '%s\n' '#!/usr/bin/env bash' > "$failing_bin"
printf '%s\n' 'echo "crontabs/fixture: Permission denied" >&2' >> "$failing_bin"
printf '%s\n' 'exit 1' >> "$failing_bin"
chmod +x "$failing_bin"

# Error path: refuse to install when the target reclaimer does not exist.
if TASK_WORKSPACE_RECLAIMER_ROOT="$fixture/missing" CRONTAB_BIN="$fake_bin" FAKE_CRONTAB="$fake_crontab" "$installer" > "$fixture/missing.out" 2>&1; then
  echo "expected missing-reclaimer install to fail" >&2
  exit 1
fi
grep -F 'missing executable:' "$fixture/missing.out" >/dev/null

# Error path: a read failure must not be mistaken for an empty crontab.
if TASK_WORKSPACE_RECLAIMER_ROOT="$root" CRONTAB_BIN="$failing_bin" "$installer" > "$fixture/read-error.out" 2>&1; then
  echo "expected crontab read error to fail closed" >&2
  exit 1
fi
grep -F 'unable to read existing crontab; refusing to replace it' "$fixture/read-error.out" >/dev/null

# Happy path: preserve unrelated jobs and collapse duplicates on repeated installs.
for _ in 1 2; do
  TASK_WORKSPACE_RECLAIMER_ROOT="$root" CRONTAB_BIN="$fake_bin" FAKE_CRONTAB="$fake_crontab" "$installer" > "$fixture/install.out"
done
[[ "$(grep -Fc '# task-workspace-reclaimer' "$fake_crontab")" == "1" ]]
grep -F '0 1 * * * true # unrelated' "$fake_crontab" >/dev/null
grep -F '55 4 * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ' "$fake_crontab" >/dev/null
grep -F '/usr/bin/python3' "$fake_crontab" >/dev/null
grep -F -- '--apply' "$fake_crontab" >/dev/null

# Build one safe terminal workspace and one terminal workspace with an unpushed commit.
git init -q "$root"
git -C "$root" config user.name fixture
git -C "$root" config user.email fixture@example.test
printf 'base\n' > "$root/source.txt"
git -C "$root" add source.txt
git -C "$root" commit -qm base
safe=20260827-0000-aa01-safe-workspace
unique=20260827-0000-bb02-unique-workspace
printf '{"task_id":"%s","status":"done"}\n' "$safe" > "$root/tasks/done/$safe.json"
printf '{"task_id":"%s","status":"done"}\n' "$unique" > "$root/tasks/done/$unique.json"
git clone -q "$root" "$root/tasks/work/$safe"
git clone -q "$root" "$root/tasks/worktrees/$unique"
git -C "$root/tasks/worktrees/$unique" config user.name fixture
git -C "$root/tasks/worktrees/$unique" config user.email fixture@example.test
printf 'unique\n' > "$root/tasks/worktrees/$unique/unique.txt"
git -C "$root/tasks/worktrees/$unique" add unique.txt
git -C "$root/tasks/worktrees/$unique" commit -qm unique

# Execute the installed command with an empty environment, matching cron's sparse runtime.
command="$(sed -n 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //p' "$fake_crontab" | grep -F '# task-workspace-reclaimer')"
env -i HOME="$HOME" /bin/bash -c "$command"
[[ ! -e "$root/tasks/work/$safe" ]]
[[ -d "$root/tasks/worktrees/$unique" ]]
grep -F '"reason": "unconfirmed_unpushed_commit"' "$root/logs/task-workspace-reclaimer-cron.log" >/dev/null
grep -F '"removed": 1' "$root/logs/task-workspace-reclaimer-cron.log" >/dev/null

grep -F '# task-workspace-reclaimer' "$fake_crontab"
grep -F '"task_id": "20260827-0000-aa01-safe-workspace"' "$root/logs/task-workspace-reclaimer-cron.log"
grep -F '"task_id": "20260827-0000-bb02-unique-workspace"' "$root/logs/task-workspace-reclaimer-cron.log"
tail -n 1 "$root/logs/task-workspace-reclaimer-cron.log"
echo 'CRON_ENV_EXIT=0'
echo 'PASS task-workspace-reclaimer cron fixture'

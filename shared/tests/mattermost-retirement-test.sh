#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
PASS=0

ok() {
  PASS=$((PASS + 1))
  printf 'PASS %s\n' "$1"
}

set +e
mm_error="$(bash "$ROOT/shared/bin/mm_post" test 2>&1)"
mm_rc=$?
set -e
[[ "$mm_rc" -eq 69 ]]
grep -Fq 'Mattermost was retired on 2026-08-26' <<< "$mm_error"
ok 'legacy mm_post fails loudly with retirement guidance'

relay_path="$(RELAY_NOTIFY_DIR="$FIXTURE/relay" \
  bash "$ROOT/shared/bin/relay-notify" dream-cycle anya 'fixture alert')"
jq -e '.from_bot == "dream-cycle" and .recipient == "anya" and (.text | endswith("fixture alert"))' \
  "$relay_path" >/dev/null
[[ ! -e "$FIXTURE/relay/.tmp/$(basename "$relay_path")" ]]
ok 'relay helper atomically queues an explicit Anya notification'

ALERT_RELAY_NOTIFY_BIN="$ROOT/shared/bin/relay-notify" \
RELAY_NOTIFY_DIR="$FIXTURE/python-relay" \
PYTHONPATH="$ROOT/shared/scripts" python3 - <<'PY'
from alert_notify import relay_notify

raise SystemExit(0 if relay_notify("python fixture", "backup-age-audit") else 1)
PY
python_relay="$(find "$FIXTURE/python-relay" -maxdepth 1 -name '*.json' -print -quit)"
jq -e '.from_bot == "backup-age-audit" and .recipient == "anya" and (.text | endswith("python fixture"))' \
  "$python_relay" >/dev/null
ok 'Python cron notifier routes through relay without Mattermost credentials'

POD_SYSTEM_ROOT="${MATTERMOST_POD_SYSTEM_ROOT:-$ROOT/pod-system}"
[[ -f "$POD_SYSTEM_ROOT/relay-quarantine-alert.ts" ]] || {
  printf 'pod-system runtime source unavailable: %s\n' "$POD_SYSTEM_ROOT/relay-quarantine-alert.ts" >&2
  exit 1
}

# Scan tracked plus untracked-but-not-ignored runtime-shaped source files in
# both independently versioned repositories. Using each repo's index and
# standard excludes avoids treating ignored worktrees, task clones, logs, and
# future scratch directories as live runtime code without hiding a newly
# created caller that has not been staged yet. The superproject's untracked
# infra/ disaster-recovery snapshot is also excluded because no service or
# cron executes from that mirror; the live shared/ and nested pod-system paths
# are scanned separately.
tracked_runtime_files() {
  local repo="$1"
  local prefix="$2"
  local relative

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null
  while IFS= read -r -d '' relative; do
    printf '%s\0' "$prefix/$relative"
  done < <(git -C "$repo" ls-files -z --cached --others --exclude-standard -- \
    '*.sh' '*.py' '*.ts' '*.tsx' '*.js' '*.mjs' '*.cjs' \
    ':(exclude)infra/**')
}

runtime_hits_from_stream() {
  while IFS= read -r -d '' runtime_file; do
    case "$runtime_file" in
      */tests/*|*/test/*|*/test-*|*/mm_post|*/fatq-cli.sh|*/fatq|*/alert_notify.py)
        continue
        ;;
    esac
    if grep -IlEq '(^|[^A-Za-z0-9_])(mm_post|alert_mattermost)([^A-Za-z0-9_]|$)|\.env\.mattermost' \
      "$runtime_file" 2>/dev/null; then
      printf '%s\n' "$runtime_file"
    fi
  done
}

runtime_hits="$(
  {
    tracked_runtime_files "$ROOT" "$ROOT"
    tracked_runtime_files "$POD_SYSTEM_ROOT" "$POD_SYSTEM_ROOT"
  } | runtime_hits_from_stream
)"
[[ -z "$runtime_hits" ]] || {
  printf 'unexpected Mattermost runtime caller(s):\n%s\n' "$runtime_hits" >&2
  exit 1
}
ok 'global runtime inventory has no remaining Mattermost sender'

REVERSE_REPO="$FIXTURE/reverse-repo"
mkdir -p "$REVERSE_REPO/shared/bin" "$REVERSE_REPO/bots/scratch" \
  "$REVERSE_REPO/infra/shared/bin"
git -C "$REVERSE_REPO" init -q
printf 'bots/\n' > "$REVERSE_REPO/.gitignore"
printf '#!/usr/bin/env bash\nmm_post "new untracked caller"\n' \
  > "$REVERSE_REPO/shared/bin/new-caller.sh"
printf '#!/usr/bin/env bash\nmm_post "ignored scratch caller"\n' \
  > "$REVERSE_REPO/bots/scratch/ignored-caller.sh"
printf '#!/usr/bin/env bash\nmm_post "recovery snapshot caller"\n' \
  > "$REVERSE_REPO/infra/shared/bin/recovery-copy.sh"
git -C "$REVERSE_REPO" status --porcelain -uall | \
  grep -Fq '?? shared/bin/new-caller.sh'
reverse_hits="$(
  tracked_runtime_files "$REVERSE_REPO" "$REVERSE_REPO" | \
    runtime_hits_from_stream
)"
[[ "$reverse_hits" == "$REVERSE_REPO/shared/bin/new-caller.sh" ]]
ok 'inventory catches a fresh untracked caller and excludes non-runtime copies'

printf 'RESULT PASS=%d\n' "$PASS"

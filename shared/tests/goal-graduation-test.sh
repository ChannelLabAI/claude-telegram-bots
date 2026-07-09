#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="$ROOT_DIR/shared/loops/goal-graduation/invariant-scan.sh"
VERIFY="$ROOT_DIR/shared/bin/fatq-verify.sh"
PROD_ROOT="$ROOT_DIR/tasks"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export GRAD_FATQ_ROOT="$TMPROOT/tasks"
export GRAD_LOOP_DIR="$TMPROOT/goal"
export GRAD_RELAY_DIR="$TMPROOT/relay"
export FATQ_VERIFY_SH="$VERIFY"
export FATQ_NOW_EPOCH="$(date -d '2026-07-09T12:00:00+08:00' +%s)"
mkdir -p "$GRAD_FATQ_ROOT"/{done,pending,in_progress,review,rejected} "$GRAD_LOOP_DIR" "$GRAD_RELAY_DIR"

if [[ "$(realpath -m "$GRAD_FATQ_ROOT")" == "$(realpath -m "$PROD_ROOT")" ]]; then
  echo "FATAL: fixture root points at production tasks" >&2
  exit 2
fi

jq -n '{
  task_id:"green", assigned:"anna", status:"done",
  graduated_invariant:[{cmd:["bash","-lc","exit 0"], expect_exit:0, desc:"green"}],
  history:[{action:"verdict_approve", ts:"2026-07-09T10:00:00+08:00"}]
}' > "$GRAD_FATQ_ROOT/done/green.json"

jq -n '{
  task_id:"red", assigned:"anna", status:"done",
  graduated_invariant:[{cmd:["bash","-lc","exit 1"], expect_exit:0, desc:"red"}],
  history:[{action:"verdict_approve", ts:"2026-07-09T10:00:00+08:00"}]
}' > "$GRAD_FATQ_ROOT/done/red.json"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name" >&2
    fail=$((fail+1))
  fi
}

export GRAD_AUTO_OPEN=0
bash "$SCAN" >/dev/null
check "G1 green audited" bash -c 'jq -s -e '"'"'any(.[]; .event=="green" and .task_id=="green")'"'"' "$0" >/dev/null' "$GRAD_LOOP_DIR/invariant-scan.audit.jsonl"
check "G2 auto-open off creates no pending" bash -c '[[ "$(find "$0" -maxdepth 1 -name '"'"'*.json'"'"' | wc -l)" == "0" ]]' "$GRAD_FATQ_ROOT/pending"

export GRAD_AUTO_OPEN=1
export FATQ_NOW_EPOCH="$(date -d '2026-07-09T13:00:00+08:00' +%s)"
bash "$SCAN" >/dev/null
check "G2 auto-open on creates regression" bash -c '[[ "$(find "$0" -maxdepth 1 -name '"'"'*.json'"'"' | wc -l)" == "1" ]]' "$GRAD_FATQ_ROOT/pending"
pending_before="$(find "$GRAD_FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
bash "$SCAN" >/dev/null
pending_after="$(find "$GRAD_FATQ_ROOT/pending" -maxdepth 1 -name '*.json' | wc -l)"
check "G3 cooldown/open regression dedup" bash -c '[[ "$0" == "$1" ]]' "$pending_before" "$pending_after"

exit "$fail"

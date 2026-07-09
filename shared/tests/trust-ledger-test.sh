#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECOMPUTE="$ROOT_DIR/shared/loops/trust-ledger/recompute.sh"
PROD_ROOT="$ROOT_DIR/tasks"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

export TRUST_FATQ_ROOT="$TMPROOT/tasks"
export TRUST_LEDGER_DIR="$TMPROOT/ledger"
export TRUST_AFFINITY_JSON="$TMPROOT/dispatch-affinity.json"
export TRUST_RELAY_DIR="$TMPROOT/relay"
export TRUST_MIN_RUNS=2
export TRUST_WINDOW_DAYS=90
export FATQ_NOW_EPOCH="$(date -d '2026-07-09T12:00:00+08:00' +%s)"
mkdir -p "$TRUST_FATQ_ROOT"/{done,rejected,review,pending,in_progress} "$TRUST_LEDGER_DIR" "$TRUST_RELAY_DIR"

if [[ "$(realpath -m "$TRUST_FATQ_ROOT")" == "$(realpath -m "$PROD_ROOT")" ]]; then
  echo "FATAL: fixture root points at production tasks" >&2
  exit 2
fi

cat > "$TRUST_AFFINITY_JSON" <<'JSON'
{"infra_patterns":["shared/","systemd","gateway"]}
JSON

make_task() {
  local dir="$1" id="$2" assigned="$3" goal="$4" skills="$5" history="$6"
  jq -n --arg id "$id" --arg assigned "$assigned" --arg goal "$goal" --argjson skills "$skills" --argjson history "$history" \
    '{task_id:$id, assigned:$assigned, goal:$goal, context:"", deliverables:[], skills:$skills, history:$history}' \
    > "$TRUST_FATQ_ROOT/$dir/$id.json"
}

hist='[
 {"ts":"2026-07-09T10:00:00+08:00","by":"bella","action":"verdict_reject","issue_type":"execution_error"},
 {"ts":"2026-07-09T10:10:00+08:00","by":"bella","action":"verdict_reject","issue_type":"spec_conflict"}
]'
make_task done t10 anna "normal task" '["fatq-ops"]' "$hist"

jq -n --argjson history "$hist" '{
  task_id:"legacy-context-object",
  assigned:"anna",
  goal:"legacy dirty task",
  context:{legacy:true, note:"object context used to crash jq join"},
  deliverables:[],
  skills:["legacy-dirty"],
  history:$history
}' > "$TRUST_FATQ_ROOT/done/legacy-context-object.json"

hist2='[
 {"ts":"2026-07-09T09:20:00+08:00","by":"anna","action":"claim"},
 {"ts":"2026-07-09T10:20:00+08:00","by":"bella","action":"verdict_approve"},
 {"ts":"2026-07-09T10:30:00+08:00","by":"bella","action":"verdict_approve"}
]'
make_task done t-l3 anna "touch shared/bin/fatq-cli.sh" '["bash-scripting"]' "$hist2"

hist3='[
 {"ts":"2026-07-09T08:00:00+08:00","by":"anna","action":"claim"},
 {"ts":"2026-07-09T09:00:00+08:00","by":"bella","action":"verdict_reject","issue_type":"execution_error"},
 {"ts":"2026-07-09T11:00:00+08:00","by":"bella","action":"verdict_approve"}
]'
make_task done t-rework bob "normal followup" '["delivery-kpi"]' "$hist3"

before_hash="$(find "$TRUST_FATQ_ROOT" -type f -name '*.json' -print0 | sort -z | xargs -0 sha256sum)"
bash "$RECOMPUTE" >/dev/null
after_hash="$(find "$TRUST_FATQ_ROOT" -type f -name '*.json' -print0 | sort -z | xargs -0 sha256sum)"

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

row_normal="$(awk -F'\t' '$1=="anna" && $2=="normal" && $3=="" {print}' "$TRUST_LEDGER_DIR/trust.tsv")"
row_infra="$(awk -F'\t' '$1=="anna" && $2=="infra" && $3=="" {print}' "$TRUST_LEDGER_DIR/trust.tsv")"
row_skill="$(awk -F'\t' '$1=="anna" && $2=="skill" && $3=="fatq-ops" {print}' "$TRUST_LEDGER_DIR/trust.tsv")"
row_kpi="$(awk -F'\t' '$1=="bob" && $2=="skill" && $3=="delivery-kpi" {print}' "$TRUST_LEDGER_DIR/trust.tsv")"

check "T10 spec_conflict excluded from runs" bash -c '[[ "$(cut -f5 <<< "$0")" == "1" && "$(cut -f7 <<< "$0")" == "1" ]]' "$row_normal"
check "T6 infra classification" bash -c '[[ "$(cut -f5 <<< "$0")" == "2" && "$(cut -f9 <<< "$0")" == "L3" ]]' "$row_infra"
check "skills explicit field collected" bash -c '[[ "$(cut -f5 <<< "$0")" == "1" ]]' "$row_skill"
check "T8 task files unchanged" bash -c '[[ "$0" == "$1" ]]' "$before_hash" "$after_hash"
check "legacy object context skipped with audit warn" bash -c 'jq -s -e '"'"'any(.[]; .event=="recompute" and .skipped_bad_files==1)'"'"' "$0" >/dev/null' "$TRUST_LEDGER_DIR/trust-ledger.audit.jsonl"
check "legacy skipped task not counted as skill" bash -c '! awk -F"\t" '"'"'$1=="anna" && $2=="skill" && $3=="legacy-dirty" {found=1} END{exit found ? 0 : 1}'"'"' "$0"' "$TRUST_LEDGER_DIR/trust.tsv"
check "first-pass rate counts execution_error rework" bash -c '[[ "$(cut -f12 <<< "$0")" == "1" && "$(cut -f13 <<< "$0")" == "0" && "$(cut -f14 <<< "$0")" == "0.000" ]]' "$row_kpi"
check "completion duration median and avg emitted" bash -c '[[ "$(cut -f15 <<< "$0")" == "3.00" && "$(cut -f16 <<< "$0")" == "3.00" ]]' "$row_kpi"
check "trust.tsv header has KPI columns" bash -c 'head -n1 "$0" | grep -q "first_pass_rate.*median_completion_hours.*avg_completion_hours"' "$TRUST_LEDGER_DIR/trust.tsv"

# Demotion alert dedup: first low run alerts, second recompute with same L1 does not create another relay.
relay_count_1="$(find "$TRUST_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l)"
bash "$RECOMPUTE" >/dev/null
relay_count_2="$(find "$TRUST_RELAY_DIR" -maxdepth 1 -name '*.json' | wc -l)"
check "T11 L1 alert dedup" bash -c '[[ "$0" == "$1" ]]' "$relay_count_1" "$relay_count_2"

exit "$fail"

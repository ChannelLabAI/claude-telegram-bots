#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TRUST_FATQ_ROOT="${TRUST_FATQ_ROOT:-$ROOT_DIR/tasks}"
TRUST_LEDGER_DIR="${TRUST_LEDGER_DIR:-$ROOT_DIR/shared/loops/trust-ledger}"
TRUST_AFFINITY_JSON="${TRUST_AFFINITY_JSON:-$ROOT_DIR/shared/lib/dispatch-affinity.json}"
TRUST_RELAY_DIR="${TRUST_RELAY_DIR:-$ROOT_DIR/relay}"
TRUST_MIN_RUNS="${TRUST_MIN_RUNS:-20}"
TRUST_WINDOW_DAYS="${TRUST_WINDOW_DAYS:-90}"
TRUST_L3_RATE="${TRUST_L3_RATE:-0.95}"
TRUST_L1_RATE="${TRUST_L1_RATE:-0.90}"
TRUST_L3_FALLBACK_RATE="${TRUST_L3_FALLBACK_RATE:-0.93}"
FATQ_NOW_EPOCH="${FATQ_NOW_EPOCH:-}"

CONFIG_FILE="$TRUST_LEDGER_DIR/config"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
[[ "${ledger_enabled:-1}" == "1" ]] || exit 0

mkdir -p "$TRUST_LEDGER_DIR"
NOW_EPOCH="${FATQ_NOW_EPOCH:-$(date +%s)}"
COMPUTED_AT="$(TZ=Asia/Taipei date -d "@$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')"
WINDOW_START=$((NOW_EPOCH - TRUST_WINDOW_DAYS * 86400))

declare -A PASS FAIL LAST_TS WARN_MISSING WARN_SKIPPED
declare -A FIRST_PASS FIRST_PASS_TOTAL DURATION_HOURS
declare -A PREV_LEVEL ALERTED
declare -A SEEN_KEYS

if [[ -f "$TRUST_LEDGER_DIR/trust-ledger.audit.jsonl" ]]; then
  while IFS=$'\t' read -r key level; do
    [[ -n "$key" ]] && PREV_LEVEL["$key"]="$level"
  done < <(jq -s -r '
    [ .[] | select(.subject_id? and .category? and .level?) ]
    | sort_by([.subject_id, .category, (.skill // "")])
    | group_by([.subject_id, .category, (.skill // "")])
    | .[]
    | last
    | [(.subject_id + "\u001c" + .category + "\u001c" + (.skill // "")), .level]
    | @tsv
  ' "$TRUST_LEDGER_DIR/trust-ledger.audit.jsonl" 2>/dev/null)
fi

is_infra_text() {
  local text="$1" pattern
  [[ -f "$TRUST_AFFINITY_JSON" ]] || return 1
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    [[ "$text" == *"$pattern"* ]] && return 0
  done < <(jq -r '.infra_patterns[]?' "$TRUST_AFFINITY_JSON" 2>/dev/null)
  return 1
}

add_count() {
  local subject="$1" category="$2" skill="$3" verdict="$4" ts="$5"
  local key="${subject}"$'\034'"${category}"$'\034'"${skill}"
  if [[ "$verdict" == "pass" ]]; then
    PASS["$key"]=$(( ${PASS["$key"]:-0} + 1 ))
  else
    FAIL["$key"]=$(( ${FAIL["$key"]:-0} + 1 ))
  fi
  if [[ -z "${LAST_TS["$key"]:-}" || "$ts" > "${LAST_TS["$key"]}" ]]; then
    LAST_TS["$key"]="$ts"
  fi
}

add_completion_metrics() {
  local subject="$1" category="$2" skill="$3" first_pass="$4" hours="$5"
  local key="${subject}"$'\034'"${category}"$'\034'"${skill}"
  FIRST_PASS_TOTAL["$key"]=$(( ${FIRST_PASS_TOTAL["$key"]:-0} + 1 ))
  if [[ "$first_pass" == "1" ]]; then
    FIRST_PASS["$key"]=$(( ${FIRST_PASS["$key"]:-0} + 1 ))
  fi
  if [[ -n "$hours" ]]; then
    DURATION_HOURS["$key"]="${DURATION_HOURS["$key"]:-}"$'\n'"$hours"
  fi
}

median_and_avg() {
  local values="$1"
  awk '
    NF {
      a[++n]=$1
      sum+=$1
    }
    END {
      if (n == 0) { print "null\tnull"; exit }
      for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (a[j] < a[i]) { t=a[i]; a[i]=a[j]; a[j]=t }
      if (n % 2) med=a[(n+1)/2]; else med=(a[n/2]+a[n/2+1])/2
      printf "%.2f\t%.2f\n", med, sum/n
    }
  ' <<< "$values"
}

scan_file() {
  local f="$1"
  jq empty "$f" >/dev/null 2>&1 || return 0
  local subject text category review_issue text_shape
  subject="$(jq -r '(.assigned // .assigned_to // empty) | tostring' "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')" || {
    WARN_SKIPPED["$f:assigned"]=1
    return 0
  }
  [[ -z "$subject" ]] && return 0
  text_shape="$(jq -r '
    [
      (.goal // "" | type),
      (.context // "" | type),
      (.deliverables // [] | type)
    ] | @tsv
  ' "$f" 2>/dev/null)" || {
    WARN_SKIPPED["$f:text_shape"]=1
    return 0
  }
  if [[ "$text_shape" == *$'object'* ]]; then
    WARN_SKIPPED["$f:legacy_object_text_field"]=1
    return 0
  fi
  text="$(jq -r '[(.goal // "" | tostring), (.context // "" | tostring), ((.deliverables // [])[]? | tostring)] | join(" ")' "$f" 2>/dev/null)" || {
    WARN_SKIPPED["$f:text_extract"]=1
    return 0
  }
  category="normal"
  is_infra_text "$text" && category="infra"
  review_issue="$(jq -r '(.review.issue_type // empty) | tostring' "$f" 2>/dev/null)" || review_issue=""

  while IFS=$'\t' read -r action ts issue_type; do
    [[ -z "$action" || -z "$ts" ]] && continue
    local epoch
    epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
    [[ -z "$epoch" || "$epoch" -lt "$WINDOW_START" || "$epoch" -gt "$NOW_EPOCH" ]] && continue

    if [[ "$action" == "verdict_approve" ]]; then
      add_count "$subject" "*" "" pass "$ts"
      add_count "$subject" "$category" "" pass "$ts"
      while IFS= read -r skill; do
        [[ -n "$skill" ]] && add_count "$subject" "skill" "$skill" pass "$ts"
      done < <(jq -r '(.skills // [])[]? | tostring' "$f" 2>/dev/null || true)
      continue
    fi

    [[ "$action" == "verdict_reject" ]] || continue
    if [[ -z "$issue_type" || "$issue_type" == "null" ]]; then
      issue_type="$review_issue"
    fi
    if [[ -z "$issue_type" || "$issue_type" == "null" ]]; then
      WARN_MISSING["$f"]=1
      issue_type="execution_error"
    fi
    case "$issue_type" in
      execution_error)
        add_count "$subject" "*" "" fail "$ts"
        add_count "$subject" "$category" "" fail "$ts"
        while IFS= read -r skill; do
          [[ -n "$skill" ]] && add_count "$subject" "skill" "$skill" fail "$ts"
        done < <(jq -r '(.skills // [])[]? | tostring' "$f" 2>/dev/null || true)
        ;;
      spec_conflict|escalate_strategist|reviewer_error|duplicate|not_reproducible)
        ;;
      *)
        WARN_MISSING["$f"]=1
        add_count "$subject" "*" "" fail "$ts"
        add_count "$subject" "$category" "" fail "$ts"
        ;;
    esac
  done < <(jq -r '(.history // [])[] | select(.action=="verdict_approve" or .action=="verdict_reject") | [.action, (.ts // ""), (.issue_type // "" | tostring)] | @tsv' "$f" 2>/dev/null || {
    WARN_SKIPPED["$f:history_extract"]=1
    true
  })

  local claim_ts approve_ts first_pass_ok hours
  claim_ts="$(jq -r '[(.history // [])[] | select(.action=="claim") | .ts][0] // ""' "$f" 2>/dev/null || true)"
  approve_ts="$(jq -r '[(.history // [])[] | select(.action=="verdict_approve") | .ts][0] // ""' "$f" 2>/dev/null || true)"
  if [[ -n "$claim_ts" && -n "$approve_ts" ]]; then
    local claim_epoch approve_epoch
    claim_epoch="$(date -d "$claim_ts" +%s 2>/dev/null || true)"
    approve_epoch="$(date -d "$approve_ts" +%s 2>/dev/null || true)"
    if [[ -n "$claim_epoch" && -n "$approve_epoch" && "$approve_epoch" -ge "$WINDOW_START" && "$approve_epoch" -le "$NOW_EPOCH" && "$approve_epoch" -ge "$claim_epoch" ]]; then
      first_pass_ok="1"
      while IFS=$'\t' read -r rts rissue; do
        [[ -z "$rts" ]] && continue
        local r_epoch
        r_epoch="$(date -d "$rts" +%s 2>/dev/null || true)"
        [[ -z "$r_epoch" || "$r_epoch" -ge "$approve_epoch" ]] && continue
        [[ -z "$rissue" || "$rissue" == "null" ]] && rissue="$review_issue"
        [[ -z "$rissue" || "$rissue" == "null" ]] && rissue="execution_error"
        if [[ "$rissue" == "execution_error" ]]; then first_pass_ok="0"; break; fi
      done < <(jq -r '(.history // [])[] | select(.action=="verdict_reject") | [(.ts // ""), (.issue_type // "" | tostring)] | @tsv' "$f" 2>/dev/null || true)
      hours="$(awk -v s="$claim_epoch" -v e="$approve_epoch" 'BEGIN { printf "%.2f", (e-s)/3600 }')"
      add_completion_metrics "$subject" "*" "" "$first_pass_ok" "$hours"
      add_completion_metrics "$subject" "$category" "" "$first_pass_ok" "$hours"
      while IFS= read -r skill; do
        [[ -n "$skill" ]] && add_completion_metrics "$subject" "skill" "$skill" "$first_pass_ok" "$hours"
      done < <(jq -r '(.skills // [])[]? | tostring' "$f" 2>/dev/null || true)
    fi
  fi
}

for dir in done rejected review; do
  [[ -d "$TRUST_FATQ_ROOT/$dir" ]] || continue
  while IFS= read -r -d '' f; do
    scan_file "$f"
  done < <(find "$TRUST_FATQ_ROOT/$dir" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
done

tmp="$(mktemp "$TRUST_LEDGER_DIR/.trust.XXXXXX")"
printf 'subject_id\tcategory\tskill\twindow_days\truns\tpass\tfail\tpass_rate\tlevel\tlast_verdict_ts\tcomputed_at\tfirst_pass_runs\tfirst_pass\tfirst_pass_rate\tmedian_completion_hours\tavg_completion_hours\n' > "$tmp"

for key in "${!PASS[@]}" "${!FAIL[@]}" "${!FIRST_PASS_TOTAL[@]}"; do
  [[ -n "${SEEN_KEYS["$key"]:-}" ]] && continue
  SEEN_KEYS["$key"]=1
  IFS=$'\034' read -r subject category skill <<< "$key"
  pass="${PASS["$key"]:-0}"
  fail="${FAIL["$key"]:-0}"
  runs=$((pass + fail))
  rate="null"
  level="L2*"
  if [[ "$runs" -gt 0 ]]; then
    rate="$(awk -v p="$pass" -v r="$runs" 'BEGIN { printf "%.3f", p/r }')"
  fi
  if [[ "$runs" -ge "$TRUST_MIN_RUNS" ]]; then
    if awk -v x="$rate" -v t="$TRUST_L3_RATE" 'BEGIN{exit !(x>=t)}'; then
      level="L3"
    elif awk -v x="$rate" -v t="$TRUST_L1_RATE" 'BEGIN{exit !(x<t)}'; then
      level="L1"
    else
      level="L2"
    fi
  fi
  fp_total="${FIRST_PASS_TOTAL["$key"]:-0}"
  fp_pass="${FIRST_PASS["$key"]:-0}"
  fp_rate="null"
  if [[ "$fp_total" -gt 0 ]]; then
    fp_rate="$(awk -v p="$fp_pass" -v r="$fp_total" 'BEGIN { printf "%.3f", p/r }')"
  fi
  IFS=$'\t' read -r med_hours avg_hours <<< "$(median_and_avg "${DURATION_HOURS["$key"]:-}")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$subject" "$category" "$skill" "$TRUST_WINDOW_DAYS" "$runs" "$pass" "$fail" "$rate" "$level" "${LAST_TS["$key"]:-}" "$COMPUTED_AT" "$fp_total" "$fp_pass" "$fp_rate" "$med_hours" "$avg_hours" >> "$tmp"

  if [[ "$level" == "L1" && "${auto_demote_alert:-1}" == "1" ]]; then
    prev="${PREV_LEVEL["$key"]:-}"
    if [[ "$prev" != "L1" ]]; then
      ALERTED["$key"]="$subject/$category/${skill:-*} rate=$rate runs=$runs"
    fi
  fi
done
mv -f "$tmp" "$TRUST_LEDGER_DIR/trust.tsv"

warn_count=0
for _ in "${!WARN_MISSING[@]}"; do warn_count=$((warn_count+1)); done
skipped_count=0
for _ in "${!WARN_SKIPPED[@]}"; do skipped_count=$((skipped_count+1)); done
alert_count=0
for _ in "${!ALERTED[@]}"; do alert_count=$((alert_count+1)); done
jq -n --arg ts "$COMPUTED_AT" --argjson warn "$warn_count" --argjson skipped "$skipped_count" --argjson alerts "$alert_count" \
  '{computed_at:$ts, event:"recompute", warn_missing_issue_type:$warn, skipped_bad_files:$skipped, demotion_alerts:$alerts}' >> "$TRUST_LEDGER_DIR/trust-ledger.audit.jsonl"

for key in "${!PASS[@]}" "${!FAIL[@]}"; do
  IFS=$'\034' read -r subject category skill <<< "$key"
  row="$(awk -F'\t' -v s="$subject" -v c="$category" -v sk="$skill" 'NR>1 && $1==s && $2==c && $3==sk {print; exit}' "$TRUST_LEDGER_DIR/trust.tsv")"
  [[ -z "$row" ]] && continue
  _runs="$(awk -F'\t' '{print $5}' <<< "$row")"
  _rate="$(awk -F'\t' '{print $8}' <<< "$row")"
  _level="$(awk -F'\t' '{print $9}' <<< "$row")"
  jq -n --arg ts "$COMPUTED_AT" --arg subject "$subject" --arg category "$category" --arg skill "$skill" \
    --arg level "$_level" --arg rate "$_rate" --argjson runs "$_runs" \
    '{computed_at:$ts, subject_id:$subject, category:$category, skill:$skill, level:$level, pass_rate:$rate, runs:$runs}' >> "$TRUST_LEDGER_DIR/trust-ledger.audit.jsonl"
done

if [[ "$alert_count" -gt 0 ]]; then
  mkdir -p "$TRUST_RELAY_DIR/.tmp" "$TRUST_RELAY_DIR" 2>/dev/null || true
  for key in "${!ALERTED[@]}"; do
    safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '-')"
    relay="trust-ledger-demotion-${safe}-$(date +%s).json"
    text="[Trust Ledger 降級告警] ${ALERTED[$key]} 已降為 L1。此為 advisory-only：不自動 mv、不自動 reject、不改狀態機。"
    tmp_relay="$(mktemp "$TRUST_RELAY_DIR/.tmp/relay.XXXXXX" 2>/dev/null || true)"
    [[ -z "$tmp_relay" ]] && continue
    jq -n --arg from "trust-ledger" --arg text "$text" --arg ts "$COMPUTED_AT" \
      '{from_bot:$from, recipient:"", text:$text, ts:$ts}' > "$tmp_relay"
    ln "$tmp_relay" "$TRUST_RELAY_DIR/$relay" 2>/dev/null || true
    rm -f "$tmp_relay"
  done
fi

#!/usr/bin/env bash
# Audit the most recent durable patrol round for the two-part task-stall format.
set -euo pipefail

for cmd in jq tail grep; do
  command -v "$cmd" >/dev/null || { echo "[patrol-alert-format-audit] missing $cmd" >&2; exit 2; }
done

LOG_FILE="${PATROL_ALERT_AUDIT_LOG:-/home/oldrabbit/.claude-bots/logs/patrol-scan.jsonl}"
[[ -r "$LOG_FILE" ]] || { echo "[patrol-alert-format-audit] unreadable log: $LOG_FILE" >&2; exit 2; }

latest="$(tail -n 1 "$LOG_FILE")"
if ! jq -e 'type == "object" and (.failures | type == "array")' <<<"$latest" >/dev/null 2>&1; then
  echo "[patrol-alert-format-audit] latest round is not a patrol record" >&2
  exit 2
fi

failures=0
checked=0
while IFS= read -r alert; do
  [[ -n "$alert" ]] || continue
  checked=$((checked + 1))
  missing=()
  grep -Fq '狀態事實:' <<<"$alert" || missing+=(state_fact)
  grep -Eq 'event_age=[-0-9]+s.*未產生狀態轉移' <<<"$alert" || missing+=(state_detail)
  grep -Fq '責任事實:' <<<"$alert" || missing+=(responsibility_fact)
  grep -Eq 'assigned=.*最近一次回應: (有，timestamp=|無)' <<<"$alert" || missing+=(assigned_response)
  grep -Fq '本單目前等待對象:' <<<"$alert" || missing+=(waiting_target)
  if ((${#missing[@]})); then
    failures=$((failures + 1))
    printf '[patrol-alert-format-audit] FAIL missing=%s alert=%s\n' "$(IFS=,; echo "${missing[*]}")" "$alert" >&2
  fi
done < <(jq -r '.failures[] | select(test("^task_(pending|in_progress|review):") and contains("event_age="))' <<<"$latest")

if ((failures > 0)); then
  printf '[patrol-alert-format-audit] FAIL checked=%d invalid=%d\n' "$checked" "$failures" >&2
  exit 1
fi
printf '[patrol-alert-format-audit] PASS checked=%d latest_ts=%s\n' "$checked" "$(jq -r '.ts' <<<"$latest")"

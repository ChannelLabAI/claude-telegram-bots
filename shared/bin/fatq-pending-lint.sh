#!/usr/bin/env bash
# Near-real-time structural lint for active FATQ tasks. Reports new defect
# fingerprints once, then rearms after the defect is repaired.

set -euo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
FATQ_RELAY_DIR="${FATQ_RELAY_DIR:-/home/oldrabbit/.claude-bots/relay}"
FATQ_PENDING_LINT_STATE="${FATQ_PENDING_LINT_STATE:-/home/oldrabbit/.claude-bots/shared/.fatq-pending-lint-state.json}"
FATQ_NOW_ISO="${FATQ_NOW_ISO:-}"

now_iso() {
  if [[ -n "$FATQ_NOW_ISO" ]]; then printf '%s\n' "$FATQ_NOW_ISO"; else TZ=Asia/Taipei date +"%Y-%m-%dT%H:%M:%S+08:00"; fi
}

mkdir -p "$FATQ_RELAY_DIR" "$(dirname "$FATQ_PENDING_LINT_STATE")"
exec 9>"${FATQ_PENDING_LINT_STATE}.lock"
flock -n 9 || { echo "[fatq-pending-lint] another lint is running; skip"; exit 0; }

if [[ ! -f "$FATQ_PENDING_LINT_STATE" ]] || ! jq -e '.active | type == "object"' "$FATQ_PENDING_LINT_STATE" >/dev/null 2>&1; then
  state_tmp="$(mktemp "$(dirname "$FATQ_PENDING_LINT_STATE")/.fatq-pending-lint-state.XXXXXX")"
  jq -n '{active:{}}' > "$state_tmp"
  mv -f "$state_tmp" "$FATQ_PENDING_LINT_STATE"
fi

all_tmp="$(mktemp)"
new_tmp="$(mktemp)"
trap 'rm -f "$all_tmp" "$new_tmp"' EXIT

for state in pending in_progress review rejected; do
  dir="$FATQ_ROOT/$state"
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' task_file; do
    base="$(basename "$task_file" .json)"
    if ! jq empty "$task_file" >/dev/null 2>&1; then
      jq -cn --arg task_id "$base" --arg state "$state" --arg path "$task_file" \
        '{task_id:$task_id,state:$state,path:$path,defects:["invalid_json"]}' >> "$all_tmp"
      continue
    fi
    jq -c --arg state "$state" --arg path "$task_file" --arg fallback "$base" '
      def nonempty_string: type == "string" and length > 0;
      def string_array: type == "array" and all(.[]; type == "string");
      [
        (if (.task_id | nonempty_string) then empty else "missing_task_id" end),
        (if (.slug | nonempty_string) then empty else "missing_slug" end),
        (if (.status | nonempty_string) then empty else "missing_status" end),
        (if (.assigned | nonempty_string) then empty else "missing_assigned" end),
        (if (.reviewer | nonempty_string) then empty else "missing_reviewer" end),
        (if (.created_by | nonempty_string) then empty else "missing_created_by" end),
        (if (.goal | nonempty_string) then empty else "missing_goal" end),
        (if (.background | nonempty_string) then empty else "missing_background" end),
        (if (.context | nonempty_string) then empty else "missing_context" end),
        (if (.review_focus | nonempty_string) then empty else "missing_review_focus" end),
        (if (.deliverables | string_array) then empty else "bad_deliverables" end),
        (if (.acceptance_criteria | string_array) then empty else "bad_acceptance_criteria" end),
        (if (.out_of_scope | string_array) then empty else "bad_out_of_scope" end),
        (if ((.history // []) | type) == "array" then empty else "bad_history" end),
        (if any((.history // [])[]?; (.action // "") == "create" and (.via // "") == "fatq-cli")
         then empty else "missing_fatq_cli_create" end),
        (if any((.history // [])[]?;
              (.action // "") == "claim" and (.via // "") != "fatq-cli")
         then "unsafe_non_cli_claim" else empty end),
        (if any((.history // [])[]?;
              (.action // "") == "submit" and (.via // "") != "fatq-cli")
         then "unsafe_non_cli_submit" else empty end)
      ] as $defects
      | select($defects | length > 0)
      | {task_id:(.task_id // $fallback),state:$state,path:$path,defects:$defects}
    ' "$task_file" >> "$all_tmp"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print0)
done

while IFS= read -r item; do
  key="$(jq -r '[.task_id, (.defects | sort | join(","))] | join("|")' <<< "$item")"
  if ! jq -e --arg key "$key" '.active | has($key)' "$FATQ_PENDING_LINT_STATE" >/dev/null; then
    printf '%s\n' "$item" >> "$new_tmp"
  fi
done < "$all_tmp"

new_count="$(wc -l < "$new_tmp" | tr -d ' ')"
ts="$(now_iso)"
if [[ "$new_count" -gt 0 ]]; then
  items_json="$(jq -s '.' "$new_tmp")"
  summary="$(jq -r '.[] | "- \(.task_id) [\(.state)]: \(.defects | join(","))"' <<< "$items_json")"
  text="[FATQ active lint] 發現 ${new_count} 張新結構缺陷任務：
${summary}
@Anyachl_bot 請用 fatq-cli 修復；相同 defect fingerprint 已抑噪，修復後若復發會再告警。"
  relay_name="fatq-pending-lint-$(date -d "$ts" +%Y%m%d%H%M%S)-$$.json"
  relay_tmp="$(mktemp "$FATQ_RELAY_DIR/.fatq-pending-lint.XXXXXX")"
  jq -n --arg from_bot "fatq-pending-lint" --arg recipient "anya" --arg text "$text" \
    --arg ts "$ts" --argjson tasks "$items_json" \
    '{from_bot:$from_bot,recipient:$recipient,text:$text,ts:$ts,kind:"fatq_active_schema_lint",tasks:$tasks}' > "$relay_tmp"
  mv -f "$relay_tmp" "$FATQ_RELAY_DIR/$relay_name"
fi

# Replace, rather than append, active fingerprints: repaired defects rearm.
active_json="$(jq -s --arg ts "$ts" '
  reduce .[] as $item ({};
    ($item.task_id + "|" + ($item.defects | sort | join(","))) as $key
    | .[$key] = {seen_at:$ts,state:$item.state,path:$item.path})
' "$all_tmp")"
state_tmp="$(mktemp "$(dirname "$FATQ_PENDING_LINT_STATE")/.fatq-pending-lint-state.XXXXXX")"
jq -n --arg ts "$ts" --argjson active "$active_json" '{updated_at:$ts,active:$active}' > "$state_tmp"
mv -f "$state_tmp" "$FATQ_PENDING_LINT_STATE"

if [[ "$new_count" -gt 0 ]]; then
  echo "[fatq-pending-lint] ALERT: $new_count new defective tasks"
else
  echo "[fatq-pending-lint] OK: no new defects"
fi

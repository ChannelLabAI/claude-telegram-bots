#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROSTER_PATROL_ROOT:-/home/oldrabbit/.claude-bots}"
TEAM_CONFIG="${ROSTER_PATROL_TEAM_CONFIG:-$ROOT/shared/team-config.json}"
BOTS_DIR="${ROSTER_PATROL_BOTS_DIR:-$ROOT/bots}"
PODS_DIR="${ROSTER_PATROL_PODS_DIR:-$ROOT/pod-system/pods}"
ALIAS_FILE="${ROSTER_PATROL_ALIAS_FILE:-$ROOT/shared/loops/roster-patrol/known-aliases.json}"
REPORT_ROOT="${ROSTER_PATROL_REPORT_ROOT:-$ROOT/logs/roster-patrol}"
RELAY_DIR="${ROSTER_PATROL_RELAY_DIR:-$ROOT/relay}"
DATE_KEY="${ROSTER_PATROL_DATE:-$(date +%F)}"
NOW="${ROSTER_PATROL_NOW:-$(date -Iseconds)}"
DRY_RUN="${ROSTER_PATROL_DRY_RUN:-0}"

mkdir -p "$REPORT_ROOT"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "[roster-patrol] missing required file: $path" >&2
    exit 2
  fi
}

require_file "$TEAM_CONFIG"
require_file "$ALIAS_FILE"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

roster_json="$tmpdir/roster.json"
pod_json="$tmpdir/pods.json"
dirs_json="$tmpdir/dirs.json"
gates_json="$tmpdir/gates.json"
issues_json="$tmpdir/issues.json"
gate_scan="$tmpdir/gate-scan.txt"
report_json="$REPORT_ROOT/$DATE_KEY.json"
report_md="$REPORT_ROOT/$DATE_KEY.md"

jq -c '
  def rows($role):
    .[]? | {
      state_dir,
      username: (.bot_username // .username // null),
      display_name: (.name // .state_dir),
      role: $role
    };
  [
    (.assistants // [] | rows("assistant")),
    ((.shared_pools // {}) | to_entries[]? as $pool | ($pool.value // [] | rows($pool.key)))
  ]
  | flatten
  | map(select(.state_dir != null and .state_dir != ""))
' "$TEAM_CONFIG" > "$roster_json"

if [[ -d "$BOTS_DIR" ]]; then
  find "$BOTS_DIR" -mindepth 2 -maxdepth 2 \( -name CLAUDE.md -o -name AGENTS.md \) -printf '%h\n' \
    | awk -F/ '{print $NF}' \
    | sort -u \
    | jq -R -s 'split("\n") | map(select(length > 0)) | map({dir:.})' > "$dirs_json"
else
  echo '[]' > "$dirs_json"
fi

if [[ -d "$PODS_DIR" ]]; then
  find "$PODS_DIR" -maxdepth 1 -type f -name '*.json' -print0 \
    | sort -z \
    | xargs -0 jq -s -c '
        [
          .[] | .podName as $pod |
          (.bots // [])[]? |
          {
            pod: $pod,
            name,
            username,
            dir,
            state_dir: ((.dir // "") | split("/") | last)
          }
        ]
      ' > "$pod_json"
else
  echo '[]' > "$pod_json"
fi

jq -n \
  --slurpfile roster "$roster_json" \
  --slurpfile dirs "$dirs_json" \
  --slurpfile pods "$pod_json" \
  --slurpfile aliases "$ALIAS_FILE" '
  def alias_reason($a; $b):
    (($aliases[0].aliases // [])
      | map(select((.canonical == $a and .alias == $b) or (.canonical == $b and .alias == $a)))
      | first);
  def known($a; $b):
    (alias_reason($a; $b) // null) as $hit
    | if $hit then {known: true, known_reason: $hit.reason, known_added_at: $hit.added_at} else {known: false} end;
  def issue($category; $key; $summary; $detail; $known):
    {category: $category, key: $key, summary: $summary, detail: $detail} + $known;

  ($roster[0] // []) as $r |
  ($dirs[0] // []) as $d |
  ($pods[0] // []) as $p |
  [
    ($d[]? as $dir |
      select(([$r[]?.state_dir] | index($dir.dir) | not) and (([$p[]?.state_dir] | index($dir.dir)) | not)) |
      issue("missing_registration"; $dir.dir;
        ("bot directory has CLAUDE.md but is absent from team-config and active pods: " + $dir.dir);
        {dir: $dir.dir};
        (([$r[]?.state_dir] | map(alias_reason(.; $dir.dir)) | map(select(. != null)) | first) as $hit |
          if $hit then {known: true, known_reason: $hit.reason, known_added_at: $hit.added_at} else {known: false} end))),

    ($r[]? as $row |
      select(([$d[]?.dir] | index($row.state_dir) | not)) |
      issue("missing_directory"; $row.state_dir;
        ("team-config entry has no bots/ directory with CLAUDE.md: " + $row.state_dir);
        {state_dir: $row.state_dir, username: $row.username, role: $row.role};
        (([$d[]?.dir] | map(alias_reason($row.state_dir; .)) | map(select(. != null)) | first) as $hit |
          if $hit then {known: true, known_reason: $hit.reason, known_added_at: $hit.added_at} else {known: false} end))),

    ($p[]? as $pod |
      select($pod.state_dir != null and $pod.state_dir != "") |
      select(([$r[]?.state_dir] | index($pod.state_dir) | not)) |
      issue("pod_unregistered"; ($pod.pod + ":" + $pod.state_dir);
        ("pod bot is absent from team-config state_dir roster: " + $pod.state_dir);
        {pod: $pod.pod, name: $pod.name, username: $pod.username, state_dir: $pod.state_dir, dir: $pod.dir};
        (([$r[]?.state_dir] | map(alias_reason(.; $pod.state_dir)) | map(select(. != null)) | first) as $hit |
          if $hit then {known: true, known_reason: $hit.reason, known_added_at: $hit.added_at} else {known: false} end))),

    ($r[]? as $row |
      $p[]? as $pod |
      select($row.state_dir == $pod.state_dir and ($row.username // "") != "" and ($pod.username // "") != "" and ($row.username | ascii_downcase) != ($pod.username | ascii_downcase)) |
      issue("username_mismatch"; $row.state_dir;
        ("username mismatch for " + $row.state_dir + ": team-config=" + ($row.username // "<missing>") + " pod=" + ($pod.username // "<missing>"));
        {state_dir: $row.state_dir, team_username: $row.username, pod_username: $pod.username, pod: $pod.pod};
        known($row.username; $pod.username))),

    ($r[]? as $row |
      select(($row.username // "") != "") |
      $p[]? as $pod |
      select(($pod.username // "" | ascii_downcase) == ($row.username | ascii_downcase)) |
      select($pod.state_dir != null and $pod.state_dir != "" and $pod.state_dir != $row.state_dir) |
      issue("state_dir_drift"; ($row.state_dir + "<->" + $pod.state_dir);
        ("same username maps to different state_dir: " + ($row.username // "<missing>") + " team-config=" + $row.state_dir + " pod=" + $pod.state_dir);
        {team_state_dir: $row.state_dir, pod_state_dir: $pod.state_dir, username: $row.username, pod: $pod.pod, pod_dir: $pod.dir};
        known($row.state_dir; $pod.state_dir)))
  ]' > "$issues_json"

{
  jq -r '.. | strings' "$TEAM_CONFIG"
  if [[ -d "$PODS_DIR" ]]; then
    find "$PODS_DIR" -maxdepth 1 -type f -name '*.json' -print0 | xargs -0 jq -r '.. | strings' 2>/dev/null || true
  fi
} | grep -oE '[A-Za-z0-9_-]+-gate' > "$gate_scan" || true
sort -u "$gate_scan" | jq -R -s 'split("\n") | map(select(length > 0))' > "$gates_json"

jq -s \
  --arg now "$NOW" \
  --arg date "$DATE_KEY" \
  --slurpfile roster "$roster_json" \
  --slurpfile dirs "$dirs_json" \
  --slurpfile pods "$pod_json" \
  --slurpfile aliases "$ALIAS_FILE" \
  --slurpfile gates "$gates_json" \
  --argfile team "$TEAM_CONFIG" '
  def uniq_sorted: unique | sort;
  def gate_token($s):
    ($s | capture("(?<id>[A-Za-z0-9_-]+-gate)").id);
  .[0] as $issues |
  (($gates[0] // []) | uniq_sorted) as $gate_refs |
  (($team.external_identities // []) | map(select(endswith("-gate"))) | uniq_sorted) as $covered_gates |
  ($gate_refs - $covered_gates) as $missing_gates |
  ($issues + ($missing_gates | map({
    category: "identity_uncovered",
    key: .,
    summary: ("referenced gate identity is missing from team-config external_identities: " + .),
    detail: {identity: .},
    known: false
  }))) as $all |
  {
    generated_at: $now,
    date: $date,
    source_counts: {
      roster: (($roster[0] // []) | length),
      bot_dirs: (($dirs[0] // []) | length),
      pod_bots: (($pods[0] // []) | length),
      gate_refs: ($gate_refs | length),
      known_aliases: (($aliases[0].aliases // []) | length)
    },
    issue_counts: {
      total: ($all | length),
      alerting: ($all | map(select(.known != true)) | length),
      known: ($all | map(select(.known == true)) | length)
    },
    issues: $all
  }' "$issues_json" > "$report_json"

alerting_count="$(jq -r '.issue_counts.alerting' "$report_json")"
known_count="$(jq -r '.issue_counts.known' "$report_json")"
total_count="$(jq -r '.issue_counts.total' "$report_json")"

{
  echo "# roster-patrol $DATE_KEY"
  echo
  echo "- generated_at: $NOW"
  echo "- total: $total_count"
  echo "- alerting: $alerting_count"
  echo "- known: $known_count"
  echo
  jq -r '.issues[]? | "- [" + .category + "] " + .summary + (if .known then " (known: " + (.known_reason // "allowlisted") + ")" else "" end)' "$report_json"
} > "$report_md"

if [[ "$alerting_count" -gt 0 ]]; then
  msg="Roster patrol found $alerting_count alerting drift(s), plus $known_count known item(s). Report: $report_md"
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$RELAY_DIR"
    # 2026-08-27 修三處，原本這則告警從 2026-07 起就沒有任何人收到過：
    #   1. 收件者硬寫 anya → 改 ROSTER_PATROL_RECIPIENT（預設 diana，基礎設施巡檢歸系統管理員）
    #   2. 欄位名用 chat_id → 應為 recipient。gateway 的 findRelayBot 讀的是 recipient，
    #      chat_id 那個欄位它不當收件者用，所以這則從來比不中任何 bot
    #   3. 正文 @anya 是 **bot name**，但常駐側的 processRelayDir 比對的是 **username**
    #      （Anyachl_bot / DianaAI_v2_bot）→ 也比不中。兩條路都不中就永久滯留
    # 三個錯任一個單獨存在都會漏，所以三個一起修。
    relay_recipient="${ROSTER_PATROL_RECIPIENT:-diana}"
    relay_username="${ROSTER_PATROL_USERNAME:-DianaAI_v2_bot}"
    relay_file="$RELAY_DIR/roster-patrol-$DATE_KEY-$relay_recipient.json"
    jq -n --arg ts "$NOW" --arg text "@$relay_username $msg" --arg rcpt "$relay_recipient" \
      '{from_bot:"sancai", recipient:$rcpt, text:$text, message_id:0, ts:$ts}' > "$relay_file"
  fi
  echo "[roster-patrol] ALERT $msg"
else
  echo "[roster-patrol] OK $DATE_KEY no alerting drift; known=$known_count report=$report_md"
fi

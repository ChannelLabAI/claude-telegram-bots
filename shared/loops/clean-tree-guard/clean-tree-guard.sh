#!/usr/bin/env bash
# Detect uncommitted changes to security-critical files before they can become
# long-lived, invisible production behaviour.  The guard never reverts files.
set -euo pipefail

ROOT="${CLEAN_TREE_GUARD_ROOT:-/home/oldrabbit/.claude-bots}"
STATE_DIR="${CLEAN_TREE_GUARD_STATE_DIR:-$ROOT/shared/loops/clean-tree-guard/state}"
RELAY_DIR="${CLEAN_TREE_GUARD_RELAY_DIR:-$ROOT/relay}"
NOW_EPOCH="${CLEAN_TREE_GUARD_NOW_EPOCH:-$(date +%s)}"
NOW_ISO="${CLEAN_TREE_GUARD_NOW_ISO:-$(TZ=Asia/Taipei date -d "@$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%S+08:00')}"
MIN_PERSIST_SECS="${CLEAN_TREE_GUARD_MIN_PERSIST_SECS:-1800}"
STATE_FILE="$STATE_DIR/pending-diff.json"

WATCH_PATHS=(
  shared/hooks
  shared/bin/fatq-cli.sh
  shared/bin/fatq-dispatch.sh
  shared/bin/fatq-deploy-gate.sh
  shared/hooks/workspace-protect.sh
  ':(glob)bots/*/access.json'
)

fail() { echo "[clean-tree-guard] $*" >&2; exit 2; }
write_state() {
  local content="$1" temp
  mkdir -p "$STATE_DIR"
  temp="$(mktemp "$STATE_DIR/.pending-diff.XXXXXX")"
  printf '%s\n' "$content" > "$temp"
  mv "$temp" "$STATE_FILE"
}

[[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] || fail "CLEAN_TREE_GUARD_NOW_EPOCH must be an epoch"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "ROOT is not a git worktree: $ROOT"

# git diff covers tracked modifications/deletions/staged content; ls-files adds
# new hooks or access.json files, which git diff intentionally omits.
DIFF="$(git -C "$ROOT" diff --no-ext-diff --binary HEAD -- "${WATCH_PATHS[@]}")"
UNTRACKED="$(git -C "$ROOT" ls-files --others --exclude-standard -- "${WATCH_PATHS[@]}" | LC_ALL=C sort)"
if [[ -z "$DIFF" && -z "$UNTRACKED" ]]; then
  rm -f "$STATE_FILE"
  echo "[clean-tree-guard] clean"
  exit 0
fi

FINGERPRINT="$({
  printf '%s\n' "$DIFF"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf 'untracked:%s\n' "$path"
    sha256sum "$ROOT/$path"
  done <<< "$UNTRACKED"
} | sha256sum | awk '{print $1}')"

if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  PREVIOUS_HASH="$(jq -r '.fingerprint // empty' "$STATE_FILE")"
  FIRST_SEEN="$(jq -r '.first_seen_epoch // 0' "$STATE_FILE")"
  ALERTED="$(jq -r '.alerted // false' "$STATE_FILE")"
else
  PREVIOUS_HASH=""
  FIRST_SEEN=0
  ALERTED=false
fi

if [[ "$PREVIOUS_HASH" != "$FINGERPRINT" || ! "$FIRST_SEEN" =~ ^[0-9]+$ ]]; then
  write_state "$(jq -n --arg fingerprint "$FINGERPRINT" --argjson now "$NOW_EPOCH" --arg now_iso "$NOW_ISO" \
    '{fingerprint:$fingerprint, first_seen_epoch:$now, first_seen_at:$now_iso, alerted:false}')"
  echo "[clean-tree-guard] dirty first observation; alert suppressed"
  exit 0
fi

ELAPSED=$((NOW_EPOCH - FIRST_SEEN))
if [[ "$ALERTED" == "true" || "$ELAPSED" -lt "$MIN_PERSIST_SECS" ]]; then
  echo "[clean-tree-guard] dirty persists ${ELAPSED}s; alert suppressed"
  exit 0
fi

SUMMARY="$(git -C "$ROOT" status --short --untracked-files=all -- "${WATCH_PATHS[@]}" | sed -n '1,20p')"
MESSAGE="🔴 clean-tree-guard: security-critical uncommitted diff persisted for ${ELAPSED}s (two observations >= ${MIN_PERSIST_SECS}s apart). Files:\n${SUMMARY}\nOwner action required: inspect and commit/revert deliberately."

mkdir -p "$RELAY_DIR"
RELAY_TMP="$(mktemp "$RELAY_DIR/.clean-tree-guard.XXXXXX")"
jq -n --arg ts "$NOW_ISO" --arg text "@Anyachl_bot $MESSAGE" \
  '{from_bot:"clean-tree-guard", recipient:"anya", text:$text, message_id:0, ts:$ts}' > "$RELAY_TMP"
mv "$RELAY_TMP" "$RELAY_DIR/clean-tree-guard-${NOW_EPOCH}.json"

write_state "$(jq -n --arg fingerprint "$FINGERPRINT" --argjson first_seen "$FIRST_SEEN" --arg now_iso "$NOW_ISO" \
  '{fingerprint:$fingerprint, first_seen_epoch:$first_seen, last_alert_at:$now_iso, alerted:true}')"
echo "[clean-tree-guard] ALERT persisted dirty tree"

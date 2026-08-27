#!/usr/bin/env bash
# Archive relay envelopes only after every configured resident reader consumed them.
set -euo pipefail

ROOT="${RELAY_ARCHIVER_ROOT:-/home/oldrabbit/.claude-bots}"
RELAY_DIR="${RELAY_ARCHIVER_RELAY_DIR:-$ROOT/relay}"
READ_DIR="${RELAY_ARCHIVER_READ_DIR:-$RELAY_DIR/read}"
READERS_CONFIG="${RELAY_ARCHIVER_READERS_CONFIG:-$ROOT/shared/config/relay-consumed-readers.json}"
LOCK_FILE="${RELAY_ARCHIVER_LOCK_FILE:-/tmp/relay-consumed-archiver.lock}"
DRY_RUN=false

usage() {
  echo "Usage: relay-consumed-archiver.sh [--dry-run]" >&2
}

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true; shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[[ "$#" -eq 0 ]] || { usage; exit 2; }

for command_name in jq find flock mv sort date; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR missing-command=$command_name" >&2
    exit 2
  }
done
[[ -d "$RELAY_DIR" ]] || { echo "ERROR relay-dir-missing=$RELAY_DIR" >&2; exit 2; }
[[ -r "$READERS_CONFIG" ]] || { echo "ERROR readers-config-missing=$READERS_CONFIG" >&2; exit 2; }
jq -e '
  (.readers | type == "array" and length > 0) and
  all(.readers[];
    (.marker | type == "string" and length > 0) and
    (.aliases | type == "array" and length > 0) and
    all(.aliases[]; type == "string" and length > 0))
' "$READERS_CONFIG" >/dev/null || {
  echo "ERROR readers-config-invalid=$READERS_CONFIG" >&2
  exit 2
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "SKIP reason=lock-busy lock=$LOCK_FILE"
  exit 0
fi

declare -A ALIAS_TO_MARKER=()
while IFS=$'\t' read -r alias marker; do
  alias="${alias,,}"
  if [[ -n "${ALIAS_TO_MARKER[$alias]:-}" && "${ALIAS_TO_MARKER[$alias]}" != "$marker" ]]; then
    echo "ERROR readers-config-ambiguous-alias=$alias" >&2
    exit 2
  fi
  ALIAS_TO_MARKER["$alias"]="$marker"
done < <(jq -r '.readers[] | .marker as $marker | .aliases[] | [., $marker] | @tsv' "$READERS_CONFIG")

map_alias() {
  local alias="$1"
  [[ -n "${ALIAS_TO_MARKER[${alias,,}]:-}" ]] && printf '%s\n' "${ALIAS_TO_MARKER[${alias,,}]}"
}

looks_like_bot_username() {
  local alias="${1,,}"
  [[ "$alias" == *bot ]]
}

choose_destination() {
  local source_name="$1" stem timestamp candidate sequence=0
  candidate="$source_name"
  if [[ ! -e "$READ_DIR/$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  stem="${source_name%.json}"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  while :; do
    candidate="${stem}.conflict-${timestamp}-$$-${sequence}.json"
    [[ -e "$READ_DIR/$candidate" ]] || { printf '%s\n' "$candidate"; return; }
    sequence=$((sequence + 1))
  done
}

archive_one() {
  local source="$1" source_name recipient destination_name destination
  local alias marker suffix marker_path marker_destination i
  local -a expected=() mapped=() mentions=() markers=() moved_sources=() moved_destinations=()
  declare -A expected_set=() consumed_set=()

  source_name="$(basename "$source")"
  if ! jq -e 'type == "object"' "$source" >/dev/null 2>&1; then
    echo "SKIP file=$source_name reason=invalid-json"
    return
  fi

  recipient="$(jq -r 'if (.recipient? | type) == "string" then .recipient else "" end' "$source")"
  if [[ -n "$recipient" ]]; then
    mapfile -t mapped < <(map_alias "$recipient")
    if [[ "${#mapped[@]}" -ne 1 ]]; then
      echo "SKIP file=$source_name reason=recipient-unmapped recipient=$recipient"
      return
    fi
    expected_set["${mapped[0]}"]=1
  fi

  mapfile -t mentions < <(jq -r '(.text? // "") | strings | scan("@[A-Za-z0-9_]+") | ltrimstr("@")' "$source" | sort -fu)
  for alias in "${mentions[@]}"; do
    mapfile -t mapped < <(map_alias "$alias")
    if [[ "${#mapped[@]}" -eq 0 ]]; then
      # Technical prose frequently contains literals such as @mention,
      # @username, or pod@assist-anya. They are not Telegram bot usernames and
      # must not strand fully consumed envelopes. Conversely, every current
      # team bot username follows Telegram's ...bot suffix convention, so an
      # unknown token with that shape fails closed until readers config catches
      # up. Known non-suffix aliases are already handled by map_alias above.
      if looks_like_bot_username "$alias"; then
        echo "SKIP file=$source_name reason=mention-unmapped mention=@$alias"
        return
      fi
    elif [[ "${#mapped[@]}" -eq 1 ]]; then
      expected_set["${mapped[0]}"]=1
    else
      echo "SKIP file=$source_name reason=mention-ambiguous mention=@$alias"
      return
    fi
  done

  if [[ "${#expected_set[@]}" -eq 0 ]]; then
    echo "SKIP file=$source_name reason=expected-readers-undetermined"
    return
  fi
  mapfile -t expected < <(printf '%s\n' "${!expected_set[@]}" | sort -f)

  mapfile -d '' -t markers < <(find "$RELAY_DIR" -maxdepth 1 -type f -name "$source_name.read-by-*" -print0)
  if [[ "${#markers[@]}" -eq 0 ]]; then
    echo "SKIP file=$source_name reason=no-read-markers expected=$(IFS=,; echo "${expected[*]}")"
    return
  fi
  for marker_path in "${markers[@]}"; do
    suffix="${marker_path##*.read-by-}"
    consumed_set["${suffix,,}"]=1
  done
  for marker in "${expected[@]}"; do
    if [[ -z "${consumed_set[${marker,,}]:-}" ]]; then
      echo "SKIP file=$source_name reason=reader-pending reader=$marker"
      return
    fi
  done

  destination_name="$(choose_destination "$source_name")"
  destination="$READ_DIR/$destination_name"
  if [[ "$DRY_RUN" == true ]]; then
    echo "ARCHIVE-DRY-RUN file=$source_name destination=$destination_name readers=$(IFS=,; echo "${expected[*]}") markers=${#markers[@]}"
    return
  fi

  mkdir -p "$READ_DIR"
  for marker_path in "${markers[@]}"; do
    suffix="${marker_path##*.read-by-}"
    marker_destination="$READ_DIR/$destination_name.read-by-$suffix"
    if [[ -e "$marker_destination" ]]; then
      echo "ERROR file=$source_name reason=marker-destination-conflict destination=$(basename "$marker_destination")" >&2
      return 1
    fi
  done
  [[ ! -e "$destination" ]] || {
    echo "ERROR file=$source_name reason=json-destination-conflict destination=$destination_name" >&2
    return 1
  }

  # Markers move first and the envelope moves last, so patrol never observes an
  # archived envelope before its evidence. Roll back partial marker moves if a
  # later move fails. No relay artifact is deleted or silently overwritten.
  for marker_path in "${markers[@]}"; do
    suffix="${marker_path##*.read-by-}"
    marker_destination="$READ_DIR/$destination_name.read-by-$suffix"
    mv -n -- "$marker_path" "$marker_destination"
    if [[ -e "$marker_path" || ! -e "$marker_destination" ]]; then
      for ((i=${#moved_sources[@]}-1; i>=0; i--)); do
        mv -n -- "${moved_destinations[$i]}" "${moved_sources[$i]}" || true
      done
      echo "ERROR file=$source_name reason=marker-move-failed marker=$(basename "$marker_path")" >&2
      return 1
    fi
    moved_sources+=("$marker_path")
    moved_destinations+=("$marker_destination")
  done
  mv -n -- "$source" "$destination"
  if [[ -e "$source" || ! -e "$destination" ]]; then
    for ((i=${#moved_sources[@]}-1; i>=0; i--)); do
      mv -n -- "${moved_destinations[$i]}" "${moved_sources[$i]}" || true
    done
    echo "ERROR file=$source_name reason=json-move-failed destination=$destination_name" >&2
    return 1
  fi
  echo "ARCHIVED file=$source_name destination=$destination_name readers=$(IFS=,; echo "${expected[*]}") markers=${#markers[@]}"
}

while IFS= read -r -d '' relay_file; do
  archive_one "$relay_file"
done < <(find "$RELAY_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)

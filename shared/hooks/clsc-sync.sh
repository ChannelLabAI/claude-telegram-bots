#!/bin/bash
# clsc-sync.sh — Auto re-encode closet when wiki note is edited
# Triggered by fts5-ingest hook chain or standalone inotifywait
# Usage: clsc-sync.sh <edited_file_path>
# Or run as daemon: clsc-sync.sh --watch
#
# NOTE: --watch mode requires inotifywait (inotify-tools package).
# Single-file mode works without inotifywait.

WIKI_ROOT="$HOME/Documents/Obsidian Vault/Ocean"
V0_7_DIR="$HOME/.claude-bots/shared/clsc/v0.7"
RADAR_DIR="$HOME/.claude-bots/seabed"
LOG="$HOME/.claude-bots/logs/clsc-sync.log"

mkdir -p "$RADAR_DIR" "$(dirname "$LOG")"

re_encode() {
    local file="$1"
    if [[ "$file" == *.md ]]; then
        local group
        # Determine group from subdirectory
        local rel="${file#$WIKI_ROOT/}"
        local subdir
        subdir=$(dirname "$rel")
        case "$subdir" in
            Research*) group="research" ;;
            Chart*) group="chart" ;;
            Pearl*) group="pearl" ;;
            Currents*) group="currents" ;;
            Companies*) group="companies" ;;
            People*) group="people" ;;
            Deals*) group="deals" ;;
            Reviews*) group="reviews" ;;
            *) group="general" ;;
        esac

        python3 - <<EOF
import sys
sys.path.insert(0, '$V0_7_DIR')
from hancloset import encode_and_store
try:
    result = encode_and_store('$file', group='$group')
    print(f"SYNC {result['slug']} -> $group ({result['skeleton_tokens']} tok, {result['saving_pct']}% saving)")
except Exception as e:
    print(f"SYNC ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
        local exit_code=$?
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] re-encoded: $file -> $group (exit=$exit_code)" >> "$LOG"
        return $exit_code
    else
        echo "Skipped (not .md): $file"
    fi
}

if [[ "$1" == "--watch" ]]; then
    if ! command -v inotifywait &>/dev/null; then
        echo "ERROR: inotifywait not found. Install with: sudo apt install inotify-tools"
        exit 1
    fi
    echo "clsc-sync: watching $WIKI_ROOT"
    inotifywait -m -r -e close_write,moved_to "$WIKI_ROOT" --format '%w%f' 2>/dev/null | \
    while read -r file; do
        re_encode "$file"
    done
elif [[ -n "$1" ]]; then
    # Single file mode
    re_encode "$1"
else
    echo "Usage: clsc-sync.sh <file.md>"
    echo "       clsc-sync.sh --watch"
    exit 1
fi

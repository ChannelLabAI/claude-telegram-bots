#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/oldrabbit/.claude-bots"
GUARD="$ROOT/shared/bin/kb-guard.sh"
CONFIG="$ROOT/shared/config/kb-guard.json"
EVIDENCE_DIR="${1:?usage: kb-guard-live-check.sh EVIDENCE_DIR}"
mkdir -p "$EVIDENCE_DIR"

BEFORE="$EVIDENCE_DIR/before.json"
AFTER="$EVIDENCE_DIR/after.json"
REPORT="$EVIDENCE_DIR/report.json"

"$GUARD" fetch --config "$CONFIG" --out "$BEFORE"
"$GUARD" scan --config "$CONFIG" --snapshot "$BEFORE" > "$REPORT"
"$GUARD" fetch --config "$CONFIG" --out "$AFTER"

jq -S '.pages | map({project,title,node_token,obj_token,text,blocks})' "$BEFORE" > "$EVIDENCE_DIR/before-content.json"
jq -S '.pages | map({project,title,node_token,obj_token,text,blocks})' "$AFTER" > "$EVIDENCE_DIR/after-content.json"
cmp "$EVIDENCE_DIR/before-content.json" "$EVIDENCE_DIR/after-content.json"
jq -e '[.findings[] | select(.check=="K3" and .category=="file_token_empty")] | length >= 1' "$REPORT" >/dev/null
echo "PASS: live KB content byte-identical across guard run; at least one real empty file.token detected"

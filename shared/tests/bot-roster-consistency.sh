#!/usr/bin/env bash
# Verify that every role-definition directory has an identity anchor and that
# every non-empty anchor points to a real roster / dispatch entry.
set -euo pipefail

ROOT="${BOT_ROSTER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BOTS_DIR="${BOT_ROSTER_BOTS_DIR:-$ROOT/bots}"
ROUTING_FILE="${BOT_ROSTER_ROUTING_FILE:-$ROOT/shared/config/bot-routing.yml}"
IDENTITY_FILE="${BOT_ROSTER_IDENTITY_FILE:-$ROOT/shared/config/bot-identity-map.yml}"
DISPATCH_FILE="${BOT_ROSTER_DISPATCH_FILE:-$ROOT/shared/bin/fatq-dispatch.sh}"

for file in "$ROUTING_FILE" "$IDENTITY_FILE" "$DISPATCH_FILE"; do
  [[ -f "$file" ]] || { echo "ERROR missing required file: $file" >&2; exit 2; }
done
[[ -d "$BOTS_DIR" ]] || { echo "ERROR missing bots directory: $BOTS_DIR" >&2; exit 2; }

python3 - "$BOTS_DIR" "$ROUTING_FILE" "$IDENTITY_FILE" "$DISPATCH_FILE" <<'PYTHON'
import os
import re
import sys
import yaml

bots_dir, routing_file, identity_file, dispatch_file = sys.argv[1:]
with open(routing_file, encoding="utf-8") as file:
    routing = yaml.safe_load(file) or {}
with open(identity_file, encoding="utf-8") as file:
    identity = yaml.safe_load(file) or {}

directories = sorted(
    name for name in os.listdir(bots_dir)
    if os.path.isfile(os.path.join(bots_dir, name, "CLAUDE.md"))
    or os.path.isfile(os.path.join(bots_dir, name, "AGENTS.md"))
)
rows = identity.get("bots", [])
roster = routing.get("bot_roster", [])
errors = []

for directory in {row.get("directory") for row in rows}:
    if sum(row.get("directory") == directory for row in rows) > 1:
        errors.append(f"duplicate identity-map directory: {directory}")
for directory in directories:
    if not any(row.get("directory") == directory for row in rows):
        errors.append(f"orphan role-definition directory: {directory} (missing from bot-identity-map.yml)")
for row in rows:
    directory = row.get("directory")
    if directory not in directories:
        errors.append(f"identity-map directory has no CLAUDE.md or AGENTS.md: {directory}")

roster_ids = {row.get("id") for row in roster}
for row in roster:
    for key in ("id", "directory", "role", "engine", "handle"):
        if key not in row:
            errors.append(f"bot_roster entry missing {key}: {row}")

with open(dispatch_file, encoding="utf-8") as file:
    dispatch_keys = [match.group(1) or match.group(2) for line in file
                     if (match := re.match(r'^\s*\[(?:"([^"]+)"|([^\]]+))\]=', line))]
for row in rows:
    roster_id = str(row.get("roster_id", ""))
    dispatch_key = str(row.get("dispatch_key", ""))
    if roster_id and roster_id not in roster_ids:
        errors.append(f"dead roster_id for {row.get('directory')}: {roster_id}")
    if dispatch_key and dispatch_key not in dispatch_keys:
        errors.append(f"dead dispatch_key for {row.get('directory')}: {dispatch_key}")

print(f"Inventory role-definition directories ({len(directories)}): {', '.join(directories)}")
print(f"Identity anchors ({len(rows)}): {', '.join(sorted(row['directory'] for row in rows))}")
covered = [directory for directory in ("sara", "spark") if directory in directories and any(row.get("directory") == directory for row in rows)]
print(f"Codex AGENTS-only coverage: {', '.join(covered)}")
print(f"Dispatch keys ({len(dispatch_keys)}): {', '.join(dispatch_keys)}")
if errors:
    for error in errors:
        print(f"ERROR {error}", file=sys.stderr)
    sys.exit(1)
print("PASS bot roster consistency")
PYTHON

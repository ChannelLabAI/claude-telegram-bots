#!/usr/bin/env bash
# Detect stale or missing bot identity keys without changing configuration.
set -uo pipefail

for required in timeout python3; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'BOT_IDENTITY_KEY_DRIFT ERROR missing-command=%s\n' "$required" >&2
    exit 2
  }
done

source_path="${BASH_SOURCE[0]}"
case "$source_path" in
  */*) source_dir="${source_path%/*}" ;;
  *) source_dir="." ;;
esac
script_dir="$(cd -P -- "$source_dir" && pwd)"
root="${BOT_IDENTITY_DRIFT_ROOT:-$script_dir/../..}"
hard_timeout="${BOT_IDENTITY_DRIFT_TIMEOUT:-20s}"

# The Python worker uses only the standard library and never spawns a child.
# timeout therefore bounds every external call/subprocess made by this script.
exec timeout --signal=TERM --kill-after=2s "$hard_timeout" python3 - "$root" <<'PY'
import json
import re
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1]).resolve()
bots_dir = root / "bots"
findings = []


def emit_inventory(table, selector, semantics, completeness):
    print(
        f"INVENTORY table={table} selector={selector} "
        f"key_semantics={semantics} completeness={completeness}"
    )


def drift(table, semantics, kind, key, detail=""):
    suffix = f" detail={detail}" if detail else ""
    findings.append(
        f"DRIFT table={table} key_semantics={semantics} "
        f"type={kind} key={key}{suffix}"
    )


def assert_full_coverage_count(table, actual_label, actual, expected_label, expected):
    """Make the CHECK cardinality invariant independently fail-closed."""
    if actual != expected:
        findings.append(
            f"ASSERT table={table} completeness=full-coverage "
            f"type=count-mismatch {actual_label}={actual} "
            f"{expected_label}={expected}"
        )


def read_text(relative):
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        drift(relative, "N/A", "unreadable-table", relative, type(exc).__name__)
        return ""


if not bots_dir.is_dir():
    print(f"BOT_IDENTITY_KEY_DRIFT ERROR missing-bots-dir={bots_dir}")
    raise SystemExit(2)

bot_dirs = sorted(p.name for p in bots_dir.iterdir() if p.is_dir())
bot_dir_set = set(bot_dirs)

# BOT_NAME is parsed from each existing start.sh; it is deliberately not
# inferred from the directory name.
bot_names = {}
for bot_dir in bot_dirs:
    start = bots_dir / bot_dir / "start.sh"
    if not start.is_file():
        continue
    try:
        text = start.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        drift("bots/*/start.sh", "BOT_NAME", "unreadable-source", bot_dir, type(exc).__name__)
        continue
    match = re.search(r'^BOT_NAME=(?:"([^"]+)"|\'([^\']+)\'|([^\s#]+))', text, re.MULTILINE)
    if not match:
        # Some support directories carry a start.sh-shaped helper without a
        # runtime BOT_NAME. They are not members of the BOT_NAME identity set.
        continue
    value = next(part for part in match.groups() if part is not None)
    bot_names[bot_dir] = value

for value, count in sorted(Counter(bot_names.values()).items()):
    if count > 1:
        drift("bots/*/start.sh", "BOT_NAME", "duplicate-source-key", value, f"count={count}")
bot_name_set = set(bot_names.values())

# Table inventory. Each row records its own key semantics and completeness;
# subset maps intentionally do not manufacture missing-key failures.
emit_inventory(
    "shared/lib/bot-crons.yml", "top-level mapping", "BOT_NAME", "full-coverage"
)
cron_text = read_text("shared/lib/bot-crons.yml")
cron_records = {}
current = None
for line in cron_text.splitlines():
    top = re.match(
        r'^([A-Za-z0-9][A-Za-z0-9_-]*):(?:\s*(\[\]))?\s*(?:#.*)?$', line
    )
    if top:
        current = top.group(1)
        cron_records.setdefault(current, False)
        if top.group(2) != "[]":
            cron_records[current] = True
        continue
    if current and re.match(r'^\s+-\s+cron:', line):
        cron_records[current] = True
cron_orphans = set(cron_records) - bot_name_set
stale_cron_key_by_bot_name = {
    bot_names[key]: key
    for key in cron_orphans
    if cron_records[key] and key in bot_names and bot_names[key] != key
}
for key in sorted(cron_orphans):
    # Empty declarations have no operational lookup payload, so they are not
    # named as orphan-key findings. This is intentional, not a parser side
    # effect: on a full-coverage table an extra empty declaration still changes
    # the CHECK cardinality and the independent assertion below fails closed.
    if cron_records[key]:
        drift("shared/lib/bot-crons.yml", "BOT_NAME", "orphan-key", key)
for key in sorted(bot_name_set - set(cron_records)):
    # A BOT_NAME can be missing either because a directory-name key was left
    # behind during a rename or because the bot was never registered at all.
    # The symmetric difference catches both; retain the stale-key detail when
    # it can be resolved without making that trace a prerequisite.
    detail = ""
    if key in stale_cron_key_by_bot_name:
        detail = f"stale-directory-key={stale_cron_key_by_bot_name[key]}"
    drift("shared/lib/bot-crons.yml", "BOT_NAME", "missing-key", key, detail)
print(
    f"CHECK table=shared/lib/bot-crons.yml keys={len(cron_records)} "
    f"expected_bot_names={len(bot_name_set)}"
)
assert_full_coverage_count(
    "shared/lib/bot-crons.yml",
    "keys",
    len(cron_records),
    "expected_bot_names",
    len(bot_name_set),
)

emit_inventory(
    "pod-system/hooks/vault-map.json", "top-level object", "DIRECTORY_NAME", "authorized-subset"
)
vault_text = read_text("pod-system/hooks/vault-map.json")
try:
    vault_data = json.loads(vault_text) if vault_text else {}
    if not isinstance(vault_data, dict):
        raise ValueError("top-level-not-object")
    vault_keys = {str(k) for k in vault_data if not str(k).startswith("_")}
except (json.JSONDecodeError, ValueError) as exc:
    drift("pod-system/hooks/vault-map.json", "DIRECTORY_NAME", "invalid-table", "<json>", str(exc))
    vault_keys = set()
for key in sorted(vault_keys - bot_dir_set):
    drift("pod-system/hooks/vault-map.json", "DIRECTORY_NAME", "orphan-key", key)
print(
    f"CHECK table=pod-system/hooks/vault-map.json keys={len(vault_keys)} "
    f"existing_directories={len(bot_dir_set)} subset=true"
)

emit_inventory(
    "shared/config/bot-routing.yml", "bot_roster[].id", "FATQ_ASSIGNED", "full-coverage"
)
routing_text = read_text("shared/config/bot-routing.yml")
roster = []
in_roster = False
current_row = None
for line in routing_text.splitlines():
    if line == "bot_roster:":
        in_roster = True
        continue
    if in_roster and line and not line.startswith((" ", "#")):
        break
    if not in_roster:
        continue
    row_id = re.match(r'^\s{2}- id:\s*["\']?([^\s"\']+)', line)
    if row_id:
        current_row = {"id": row_id.group(1), "directory": ""}
        roster.append(current_row)
        continue
    directory = re.match(r'^\s{4}directory:\s*["\']?([^\s"\']+)', line)
    if directory and current_row is not None:
        current_row["directory"] = directory.group(1)

fatq_ids = [row["id"] for row in roster]
roster_dirs = [row["directory"] for row in roster if row["directory"]]
for value, count in sorted(Counter(fatq_ids).items()):
    if count > 1:
        drift("shared/config/bot-routing.yml", "FATQ_ASSIGNED", "duplicate-key", value, f"count={count}")
for row in roster:
    if not row["directory"]:
        drift("shared/config/bot-routing.yml", "FATQ_ASSIGNED", "missing-directory-link", row["id"])
    elif row["directory"] not in bot_dir_set:
        drift(
            "shared/config/bot-routing.yml",
            "FATQ_ASSIGNED",
            "orphan-key",
            row["id"],
            f"directory={row['directory']}",
        )
for value, count in sorted(Counter(roster_dirs).items()):
    if count > 1:
        drift("shared/config/bot-routing.yml", "FATQ_ASSIGNED", "duplicate-directory-link", value, f"count={count}")
for directory in sorted(bot_dir_set - set(roster_dirs)):
    drift("shared/config/bot-routing.yml", "FATQ_ASSIGNED", "missing-key", directory, "directory-not-in-roster")
print(
    f"CHECK table=shared/config/bot-routing.yml fatq_ids={len(fatq_ids)} "
    f"linked_directories={len(set(roster_dirs))} expected_directories={len(bot_dir_set)}"
)
assert_full_coverage_count(
    "shared/config/bot-routing.yml",
    "linked_directories",
    len(set(roster_dirs)),
    "expected_directories",
    len(bot_dir_set),
)

emit_inventory(
    "shared/config/model-router.yml", "top-level bot_defaults", "DIRECTORY_NAME", "fallback-subset"
)
model_text = read_text("shared/config/model-router.yml")
model_keys = set()
in_defaults = False
for line in model_text.splitlines():
    if line == "bot_defaults:":
        in_defaults = True
        continue
    if in_defaults and line and not line.startswith((" ", "#")):
        break
    if in_defaults:
        match = re.match(r'^\s{2}([A-Za-z0-9][A-Za-z0-9_-]*):', line)
        if match and match.group(1) != "_default":
            model_keys.add(match.group(1))
for key in sorted(model_keys - bot_dir_set):
    drift("shared/config/model-router.yml", "DIRECTORY_NAME", "orphan-key", key)
print(
    f"CHECK table=shared/config/model-router.yml keys={len(model_keys)} "
    f"existing_directories={len(bot_dir_set)} subset=true"
)

for finding in sorted(findings):
    print(finding)

if findings:
    print(f"BOT_IDENTITY_KEY_DRIFT FAIL findings={len(findings)}")
    raise SystemExit(1)

print(
    f"BOT_IDENTITY_KEY_DRIFT OK tables=4 bot_dirs={len(bot_dir_set)} "
    f"bot_names={len(bot_name_set)} fatq_ids={len(set(fatq_ids))}"
)
PY

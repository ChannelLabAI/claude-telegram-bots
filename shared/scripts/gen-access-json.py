#!/usr/bin/env python3
"""
gen-access-json.py — Generate access.json for a bot from team-config.json

This is the DEMO migration script showing how to replace hardcoded chat_ids
with dynamic values from team-config.json.

Usage:
    python3 gen-access-json.py anya [--write]

Without --write: prints the generated access.json to stdout.
With --write: overwrites the bot's access.json in place (after backup).

Currently demoed for: anya
Extend for other bots by adding entries to BOT_CONFIGS below.
"""

import json, sys, shutil, datetime
from pathlib import Path

sys.path.insert(0, str(Path("~/.claude-bots/shared/lib").expanduser()))
from team_config import cfg

BOTS_DIR = Path("~/.claude-bots").expanduser()

# Bot-specific config that CANNOT be derived from team-config.json
# (dmPolicy, allowFrom, requireMention are bot-specific decisions)
BOT_CONFIGS = {
    "anya": {
        "dmPolicy": "allowlist",
        "allowFrom_keys": ["lt", "chuange"],  # map to dms keys
        "groups": [
            # (chat_id_source, requireMention)
            ("lt_command",    True),
            ("ron_command",   True),
            ("nicky_command", True),
            ("cj_extra_1",    True),
            ("test_group",    False),
            ("coordinator",   True),
            ("main_team",     True),
        ]
    }
}


def generate_access_json(bot_name: str) -> dict:
    if bot_name not in BOT_CONFIGS:
        raise ValueError(f"No config defined for bot '{bot_name}'. Add it to BOT_CONFIGS.")

    bot_cfg = BOT_CONFIGS[bot_name]

    # Build allowFrom from owner keys
    allow_from = [cfg.dm(key) for key in bot_cfg["allowFrom_keys"]]

    # Build groups from team-config group keys
    groups = {}
    for group_key, require_mention in bot_cfg["groups"]:
        chat_id = cfg.group_id(group_key)
        groups[chat_id] = {
            "requireMention": require_mention,
            "allowFrom": []
        }

    return {
        "dmPolicy": bot_cfg["dmPolicy"],
        "allowFrom": allow_from,
        "groups": groups,
        "pending": {}
    }


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <bot_name> [--write]", file=sys.stderr)
        sys.exit(1)

    bot_name = sys.argv[1]
    write_mode = "--write" in sys.argv

    access_json = generate_access_json(bot_name)
    output = json.dumps(access_json, indent=2, ensure_ascii=False)

    if write_mode:
        target = BOTS_DIR / "state" / bot_name / "access.json"
        backup = target.with_suffix(f".json.bak-{datetime.date.today().isoformat()}")
        shutil.copy(target, backup)
        print(f"Backed up to: {backup}")
        target.write_text(output)
        print(f"Written to: {target}")
    else:
        print(output)


if __name__ == "__main__":
    main()

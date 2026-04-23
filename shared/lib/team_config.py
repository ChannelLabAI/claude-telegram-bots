"""
team_config.py — Python helper for reading ~/.claude-bots/shared/team-config.json

Usage:
    from team_config import cfg

    # Group IDs
    cfg.main_team_id          # "-1003634255226"
    cfg.coordinator_id        # "-5175060310"
    cfg.lt_command_id         # "-5267778636"

    # DM IDs (owner user_ids)
    cfg.dm("lt")              # "1050312492"
    cfg.dm("ron")             # "5288537361"

    # Pools
    cfg.builder_pool          # [{"name": "Anna", "bot_username": "annadesu_bot", ...}, ...]
    cfg.reviewer_pool
    cfg.designer_pool

    # Bot usernames
    cfg.bot_username("anna")  # "annadesu_bot"
    cfg.bot_username("Bella") # "Bellalovechl_Bot"

    # Owner preferences
    cfg.preferred_builders("lt")    # ["anna", "sancai"]
    cfg.preferred_reviewers("ron")  # ["ron-reviewer"]
"""

import json
import os
from pathlib import Path
from typing import Optional

_DEFAULT_CONFIG_PATH = Path("~/.claude-bots/shared/team-config.json").expanduser()


class TeamConfig:
    def __init__(self, config_path: Path = _DEFAULT_CONFIG_PATH):
        with open(config_path) as f:
            self._data = json.load(f)

    # ── Groups ──────────────────────────────────────────────────────────────

    @property
    def main_team_id(self) -> str:
        return self._data["groups"]["main_team"]["chat_id"]

    @property
    def coordinator_id(self) -> str:
        return self._data["groups"]["coordinator"]["chat_id"]

    @property
    def lt_command_id(self) -> str:
        return self._data["groups"]["lt_command"]["chat_id"]

    @property
    def ron_command_id(self) -> str:
        return self._data["groups"]["ron_command"]["chat_id"]

    @property
    def nicky_command_id(self) -> str:
        return self._data["groups"]["nicky_command"]["chat_id"]

    @property
    def cj_command_id(self) -> str:
        return self._data["groups"]["cj_command"]["chat_id"]

    def group_id(self, key: str) -> str:
        """Get any group chat_id by key (e.g., 'main_team', 'coordinator')."""
        return self._data["groups"][key]["chat_id"]

    # ── DMs ─────────────────────────────────────────────────────────────────

    def dm(self, owner_key: str) -> str:
        """Get owner's Telegram user_id (e.g., dm('lt') → '1050312492')."""
        return self._data["dms"][owner_key]

    # ── Pools ────────────────────────────────────────────────────────────────

    @property
    def builder_pool(self) -> list[dict]:
        return self._data["shared_pools"]["builder"]

    @property
    def reviewer_pool(self) -> list[dict]:
        return self._data["shared_pools"]["reviewer"]

    @property
    def designer_pool(self) -> list[dict]:
        return self._data["shared_pools"]["designer"]

    @property
    def all_shared_bots(self) -> list[dict]:
        return self.builder_pool + self.reviewer_pool + self.designer_pool

    # ── Lookups ──────────────────────────────────────────────────────────────

    def bot_username(self, state_dir: str) -> Optional[str]:
        """
        Get bot @username by state_dir name (e.g., 'anna' → 'annadesu_bot').
        Returns None if not found or not set.
        """
        for pool in (self.builder_pool, self.reviewer_pool, self.designer_pool):
            for bot in pool:
                if bot.get("state_dir") == state_dir:
                    return bot.get("bot_username")
        for asst in self._data.get("assistants", []):
            if asst.get("state_dir") == state_dir:
                return asst.get("bot_username")
        return None

    def preferred_builders(self, owner_key: str) -> list[str]:
        """Get preferred builder state_dirs for an owner (e.g., 'lt' → ['anna', 'sancai'])."""
        prefs = self._data.get("owner_preferences", {}).get(owner_key, {})
        return prefs.get("builder", [])

    def preferred_reviewers(self, owner_key: str) -> list[str]:
        """Get preferred reviewer state_dirs for an owner."""
        prefs = self._data.get("owner_preferences", {}).get(owner_key, {})
        return prefs.get("reviewer", [])

    def owner_user_id(self, owner_key: str) -> str:
        """Get owner's Telegram user_id (alias for dm())."""
        return self.dm(owner_key)

    # ── Raw access ───────────────────────────────────────────────────────────

    def get(self, *keys):
        """Navigate nested keys: cfg.get('groups', 'main_team', 'chat_id')."""
        val = self._data
        for k in keys:
            val = val[k]
        return val


# Singleton instance
cfg = TeamConfig()

if __name__ == "__main__":
    # Quick smoke test
    print(f"main_team_id: {cfg.main_team_id}")
    print(f"coordinator_id: {cfg.coordinator_id}")
    print(f"lt dm: {cfg.dm('lt')}")
    print(f"anna username: {cfg.bot_username('anna')}")
    print(f"bella username: {cfg.bot_username('Bella')}")
    print(f"lt preferred builders: {cfg.preferred_builders('lt')}")
    print(f"ron preferred reviewers: {cfg.preferred_reviewers('ron')}")
    print(f"builder pool: {[b['name'] for b in cfg.builder_pool]}")
    print(f"reviewer pool: {[r['name'] for r in cfg.reviewer_pool]}")

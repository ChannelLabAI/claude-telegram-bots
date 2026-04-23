#!/usr/bin/env python3
"""
l2_loader.py — L2 On-Demand Block Trigger Matcher
===================================================

Takes current conversation text as input, checks against block trigger keyword
lists, returns list of block file paths that should be injected.

Matching logic: OR match — any trigger keyword match loads the block.
Fail-safe: when uncertain, INCLUDE the block (never miss a load).

Usage:
    from l2_loader import L2Loader
    loader = L2Loader("/path/to/blocks/")
    blocks = loader.match("I need to restart the VPS")
    # → ["/path/to/blocks/block-vps-ops.md"]

CLI:
    python3 l2_loader.py /path/to/blocks/ "conversation text here"
"""

import json
import os
import sys
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional


def _parse_frontmatter(content: str) -> dict:
    """
    Parse YAML frontmatter from a markdown file.
    Returns dict with 'triggers' list and 'description' string.
    Fails gracefully: returns empty dict if no frontmatter.
    """
    if not content.startswith("---"):
        return {}

    end = content.find("\n---", 3)
    if end == -1:
        return {}

    fm_text = content[3:end].strip()
    result = {}

    # Parse triggers list
    triggers_match = re.search(
        r'^triggers:\s*\[([^\]]*)\]', fm_text, re.MULTILINE
    )
    if triggers_match:
        raw = triggers_match.group(1)
        # Split by comma, strip quotes and whitespace
        triggers = [
            t.strip().strip('"').strip("'")
            for t in raw.split(",")
            if t.strip().strip('"').strip("'")
        ]
        result["triggers"] = triggers
    else:
        # Try multi-line list format
        triggers_block = re.search(
            r'^triggers:\s*\n((?:\s+-\s+.+\n?)+)', fm_text, re.MULTILINE
        )
        if triggers_block:
            triggers = re.findall(r'-\s+"?([^"\n]+)"?', triggers_block.group(1))
            result["triggers"] = [t.strip() for t in triggers]
        else:
            result["triggers"] = []

    # Parse description
    desc_match = re.search(r'^description:\s*"?([^"\n]+)"?', fm_text, re.MULTILINE)
    if desc_match:
        result["description"] = desc_match.group(1).strip()
    else:
        result["description"] = ""

    return result


class L2Loader:
    """
    Matches conversation text against L2 block trigger keywords.
    Loads block metadata lazily from disk.
    """

    def __init__(self, blocks_dir: str):
        self.blocks_dir = Path(blocks_dir)
        self._catalog: List[dict] = []  # [{path, triggers, description}]
        self._loaded = False

    def _load_catalog(self):
        """Scan blocks_dir and parse all block frontmatter."""
        if self._loaded:
            return
        self._catalog = []

        if not self.blocks_dir.exists():
            self._loaded = True
            return

        for md_file in sorted(self.blocks_dir.glob("block-*.md")):
            try:
                content = md_file.read_text(encoding="utf-8")
                meta = _parse_frontmatter(content)
                self._catalog.append({
                    "path": str(md_file),
                    "triggers": meta.get("triggers", []),
                    "description": meta.get("description", ""),
                })
            except Exception:
                # Fail-safe: include the block even if we can't parse it
                self._catalog.append({
                    "path": str(md_file),
                    "triggers": [],
                    "description": "",
                    "_parse_error": True,
                })

        self._loaded = True

    def match(self, conversation_text: str, include_on_parse_error: bool = True) -> List[str]:
        """
        Check conversation text against all block triggers.

        Args:
            conversation_text: The full conversation text to scan.
            include_on_parse_error: If a block had a parse error, include it
                                    (fail-safe: never miss a load).

        Returns:
            List of absolute file paths for blocks that should be injected.
        """
        self._load_catalog()

        matched = []

        for block in self._catalog:
            # Fail-safe: include blocks with parse errors
            if block.get("_parse_error") and include_on_parse_error:
                matched.append(block["path"])
                continue

            # No triggers defined → include (fail-safe)
            if not block["triggers"]:
                matched.append(block["path"])
                continue

            # Case-insensitive keyword matching
            text_lower = conversation_text.lower()
            for trigger in block["triggers"]:
                if trigger.lower() in text_lower:
                    matched.append(block["path"])
                    break

        return matched

    def match_with_reasons(self, conversation_text: str) -> List[dict]:
        """
        Like match(), but returns dicts with {path, trigger_matched, description}.
        Useful for debugging.
        """
        self._load_catalog()

        results = []
        text_lower = conversation_text.lower()

        for block in self._catalog:
            matched_trigger = None

            if block.get("_parse_error"):
                matched_trigger = "(parse_error — fail-safe include)"
            elif not block["triggers"]:
                matched_trigger = "(no triggers — fail-safe include)"
            else:
                for trigger in block["triggers"]:
                    if trigger.lower() in text_lower:
                        matched_trigger = trigger
                        break

            if matched_trigger is not None:
                results.append({
                    "path": block["path"],
                    "trigger_matched": matched_trigger,
                    "description": block["description"],
                })

        return results

    def list_all(self) -> List[dict]:
        """List all known blocks and their triggers (for inspection)."""
        self._load_catalog()
        return [
            {
                "path": b["path"],
                "triggers": b["triggers"],
                "description": b["description"],
            }
            for b in self._catalog
        ]


# ---------------------------------------------------------------------------
# Dogfood stats logging
# ---------------------------------------------------------------------------

DEFAULT_STATS_PATH = os.path.expanduser("~/.claude-bots/bots/anya/l2_stats.json")


def log_session(
    query: str,
    matched_blocks: List[str],
    stats_path: Optional[str] = None,
) -> None:
    """
    Append a session entry to l2_stats.json and increment block_hit_counts.

    Args:
        query: The conversation text / query snippet that was matched.
        matched_blocks: List of block names (e.g. "block-vps-ops") or full paths
                        that were loaded for this session.
        stats_path: Path to l2_stats.json. Defaults to DEFAULT_STATS_PATH.
                    Pass a custom path for testing.

    Fail-safe: logs nothing and returns quietly on any error (never crash the bot).
    """
    if stats_path is None:
        stats_path = DEFAULT_STATS_PATH

    try:
        stats_file = Path(stats_path)

        # Load existing stats, or start fresh if file doesn't exist
        if stats_file.exists():
            try:
                data = json.loads(stats_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                data = {}
        else:
            data = {}

        # Ensure required keys exist
        if "sessions" not in data:
            data["sessions"] = []
        if "block_hit_counts" not in data:
            data["block_hit_counts"] = {}

        # Normalize block names: strip directory and .md extension
        normalized_blocks = []
        for b in matched_blocks:
            name = Path(b).stem  # e.g. "block-vps-ops"
            normalized_blocks.append(name)

        # Build session entry
        session_entry = {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "query_snippet": query[:120],  # cap to avoid huge entries
            "blocks_loaded": normalized_blocks,
        }
        data["sessions"].append(session_entry)

        # Increment hit counts
        for name in normalized_blocks:
            data["block_hit_counts"][name] = data["block_hit_counts"].get(name, 0) + 1

        # Write atomically via .tmp
        tmp_path = str(stats_path) + ".tmp"
        Path(tmp_path).write_text(
            json.dumps(data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        os.replace(tmp_path, stats_path)

    except Exception:
        # Fail-safe: never crash the bot over stats logging
        pass


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: l2_loader.py <blocks_dir> [conversation_text]", file=sys.stderr)
        print("       l2_loader.py <blocks_dir> --list", file=sys.stderr)
        sys.exit(1)

    blocks_dir = sys.argv[1]
    loader = L2Loader(blocks_dir)

    if len(sys.argv) >= 3 and sys.argv[2] == "--list":
        for block in loader.list_all():
            print(f"\n{Path(block['path']).name}")
            print(f"  desc: {block['description']}")
            print(f"  triggers ({len(block['triggers'])}): {', '.join(block['triggers'][:5])}"
                  + (" ..." if len(block['triggers']) > 5 else ""))
        return

    # Read conversation text from args or stdin
    if len(sys.argv) >= 3:
        conversation_text = " ".join(sys.argv[2:])
    else:
        conversation_text = sys.stdin.read()

    results = loader.match_with_reasons(conversation_text)

    if not results:
        print("No blocks matched.")
        return

    print(f"Matched {len(results)} block(s):")
    for r in results:
        print(f"  {Path(r['path']).name}")
        print(f"    trigger: {r['trigger_matched']}")
        print(f"    desc:    {r['description']}")


if __name__ == "__main__":
    main()

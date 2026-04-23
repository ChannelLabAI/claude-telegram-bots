#!/usr/bin/env python3
"""Hook body for wikilink-required.sh.

Reads a PreToolUse JSON payload from stdin. Exits 0 to allow, 2 to block.
Scope: ~/Documents/Obsidian Vault/Ocean/**/*.md and ~/.claude-bots/tasks/**/*.json.
Whitelist: basename starts with "_", basename ends with "_archive.md",
paths under Ocean/珍珠卡/_drafts/, basename matches Reviews/CR-*.

Source: ADR v0.4 §10 (張凌赫提案), task 20260408-122517-0a1a.
"""
import json
import os
import pathlib
import re
import sys

HOME = os.path.expanduser("~")
WIKI_PREFIX = os.path.join(HOME, "Documents/Obsidian Vault/Ocean") + "/"
TASKS_PREFIX = os.path.join(HOME, ".claude-bots/tasks") + "/"
WIKILINK_RE = re.compile(r"\[\[[^\]]+\]\]")


def allow() -> "None":
    sys.exit(0)


def block(path: str) -> "None":
    sys.stderr.write(
        f"BLOCKED [wikilink-required]: {path}\n"
        f"This file requires \u22651 wikilink. Add a [[link]] before saving.\n"
        f"Scope: Ocean/**/*.md and tasks/**/*.json. "
        f"Whitelist: _*.md, *_archive.md, Pearl/_drafts/, Reviews/CR-*.\n"
    )
    sys.exit(2)


def main() -> "None":
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()

    tool = data.get("tool_name", "")
    if tool not in ("Edit", "Write", "MultiEdit"):
        allow()

    ti = data.get("tool_input", {}) or {}
    fp = ti.get("file_path", "") or ""
    if not fp:
        allow()

    try:
        abs_path = str(pathlib.Path(fp).expanduser().resolve(strict=False))
    except Exception:
        abs_path = fp
    basename = os.path.basename(abs_path)

    in_wiki = abs_path.startswith(WIKI_PREFIX) and abs_path.endswith(".md")
    in_tasks = abs_path.startswith(TASKS_PREFIX) and abs_path.endswith(".json")
    if not (in_wiki or in_tasks):
        allow()

    # Whitelist.
    if basename.startswith("_"):
        allow()
    if basename.endswith("_archive.md"):
        allow()
    if abs_path.startswith(WIKI_PREFIX + "Pearl/_drafts/"):
        allow()
    if abs_path.startswith(WIKI_PREFIX + "Reviews/") and basename.startswith("CR-"):
        allow()

    def read_disk() -> str:
        try:
            with open(abs_path, "r", encoding="utf-8") as fh:
                return fh.read()
        except Exception:
            return ""

    if tool == "Write":
        new_content = ti.get("content", "") or ""
    elif tool == "Edit":
        disk = read_disk()
        old_s = ti.get("old_string", "") or ""
        new_s = ti.get("new_string", "") or ""
        if old_s and old_s in disk:
            new_content = disk.replace(old_s, new_s, 1)
        else:
            # Conservative fallback when old_string not present (e.g. new file).
            new_content = new_s
    else:  # MultiEdit
        new_content = read_disk()
        for e in (ti.get("edits") or []):
            old_s = e.get("old_string", "") or ""
            new_s = e.get("new_string", "") or ""
            if old_s and old_s in new_content:
                new_content = new_content.replace(old_s, new_s, 1)
            else:
                new_content += "\n" + new_s

    count = len(WIKILINK_RE.findall(new_content))
    if count >= 1:
        allow()
    block(fp)


if __name__ == "__main__":
    main()

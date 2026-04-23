#!/usr/bin/env python3
"""Pearl lint hook — PreToolUse guard for Ocean/珍珠卡/ writes.

Rules:
  BLOCK if word count > 300 (split required, technical content → Chart/)
  BLOCK if frontmatter missing required fields: type, created
  WARN  if [[wikilink]] count < 2 (stderr warning, not block)

Scope: ~/Documents/Obsidian Vault/Ocean/珍珠卡/**/*.md only.
"""
import json
import os
import pathlib
import re
import sys

HOME = os.path.expanduser("~")
PEARL_PREFIX = os.path.join(HOME, "Documents/Obsidian Vault/Ocean/珍珠卡") + "/"
WIKILINK_RE = re.compile(r"\[\[[^\]]+\]\]")
FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)


def allow():
    sys.exit(0)


def block(msg: str):
    sys.stderr.write(f"BLOCKED [pearl-lint]: {msg}\n")
    sys.exit(2)


def warn(msg: str):
    sys.stderr.write(f"WARN [pearl-lint]: {msg}\n")


def get_content(data: dict) -> str:
    tool = data.get("tool_name", "")
    ti = data.get("tool_input", {}) or {}
    fp = ti.get("file_path", "") or ""

    if tool == "Write":
        return ti.get("content", "") or ""
    elif tool == "Edit":
        try:
            with open(fp, "r", encoding="utf-8") as f:
                disk = f.read()
        except Exception:
            disk = ""
        old_s = ti.get("old_string", "") or ""
        new_s = ti.get("new_string", "") or ""
        if old_s and old_s in disk:
            return disk.replace(old_s, new_s, 1)
        return new_s
    elif tool == "MultiEdit":
        try:
            with open(fp, "r", encoding="utf-8") as f:
                content = f.read()
        except Exception:
            content = ""
        for e in (ti.get("edits") or []):
            old_s = e.get("old_string", "") or ""
            new_s = e.get("new_string", "") or ""
            if old_s and old_s in content:
                content = content.replace(old_s, new_s, 1)
        return content
    return ""


def main():
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

    # Only applies to Pearl/ .md files
    if not (abs_path.startswith(PEARL_PREFIX) and abs_path.endswith(".md")):
        allow()

    # Whitelist: underscore prefix files (_index.md, _lint-*.md, etc.)
    if os.path.basename(abs_path).startswith("_"):
        allow()

    content = get_content(data)

    # Strip frontmatter for word count
    body = re.sub(r"^---\s*\n.*?\n---\s*\n", "", content, flags=re.DOTALL)
    word_count = len(body.split())

    # Check frontmatter
    fm_match = FRONTMATTER_RE.match(content)
    if fm_match:
        fm_text = fm_match.group(1)
        missing = []
        if "type:" not in fm_text:
            missing.append("type")
        if "created:" not in fm_text:
            missing.append("created")
        if missing:
            block(f"{fp}: missing frontmatter fields: {', '.join(missing)}. Required: type, created.")
        if "compiled_at:" not in fm_text:
            warn(f"{fp}: missing 'compiled_at' in frontmatter. Add 'compiled_at: YYYY-MM-DD'.")
    else:
        block(f"{fp}: missing frontmatter. Pearl cards require: type: card, created: YYYY-MM-DD.")

    # Word count check (> 300 words → block)
    if word_count > 300:
        block(
            f"{fp}: {word_count} words > 300 limit. "
            "Split into smaller cards, or move technical content to Ocean/技術海圖/."
        )

    # Wikilink check (< 2 → warn only)
    wikilink_count = len(WIKILINK_RE.findall(content))
    if wikilink_count < 2:
        warn(
            f"{fp}: only {wikilink_count} [[wikilink]](s). "
            "Pearl cards should have ≥2 wikilinks to maximize knowledge graph density."
        )

    # Timeline section check (BLOCK if missing)
    if "## Timeline" not in content:
        block(
            f"{fp}: missing '## Timeline' section. "
            "Pearl cards require dual-layer structure: '## Compiled Truth' + '## Timeline'."
        )

    allow()


if __name__ == "__main__":
    main()

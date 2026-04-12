#!/usr/bin/env python3
"""
pearl_draft_generator.py — Auto-generate Pearl card drafts from today's conversations
Called on assistant stop hook. Scans today's messages + relay/*.json for insights/patterns.
"""

import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import anthropic

# ── Config ────────────────────────────────────────────────────────────────────
DB_PATH = os.path.expanduser("~/.claude-bots/memory.db")
RELAY_DIR = os.path.expanduser("~/.claude-bots/relay")
DRAFTS_DIR = os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/Pearl/_drafts"
)
HASH_STATE = os.path.expanduser("~/.claude-bots/state/assistant/pearl-draft-hashes.json")
HAIKU_MODEL = "claude-haiku-4-5-20251001"
MAX_CONTENT_CHARS = 4000


def load_seen_hashes() -> set:
    """Load today's already-processed content hashes."""
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        with open(HASH_STATE, "r") as f:
            data = json.load(f)
        # Only keep today's hashes
        return set(data.get(today_str, []))
    except Exception:
        return set()


def save_hash(content_hash: str):
    """Persist a processed hash for today."""
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        with open(HASH_STATE, "r") as f:
            data = json.load(f)
    except Exception:
        data = {}
    # Prune old dates, keep only today
    data = {today_str: list(set(data.get(today_str, [])) | {content_hash})}
    os.makedirs(os.path.dirname(HASH_STATE), exist_ok=True)
    with open(HASH_STATE, "w") as f:
        json.dump(data, f)


def get_today_messages(conn: sqlite3.Connection) -> list[str]:
    """Query today's messages from memory.db."""
    cur = conn.cursor()
    cur.execute(
        """
        SELECT user, text
        FROM messages
        WHERE ts >= datetime('now', 'start of day', '-8 hours')
          AND text IS NOT NULL
          AND text != ''
        ORDER BY ts ASC
        """
    )
    rows = cur.fetchall()
    return [f"[{r[0]}] {r[1]}" for r in rows]


def get_relay_messages() -> list[str]:
    """Read *.json files from relay directory."""
    relay_path = Path(RELAY_DIR)
    if not relay_path.exists():
        return []

    lines = []
    for fpath in sorted(relay_path.glob("*.json")):
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                data = json.load(f)
            # Try to extract text content from relay message
            if isinstance(data, dict):
                text = data.get("text") or data.get("message") or data.get("content") or ""
                if text:
                    lines.append(str(text)[:500])
            elif isinstance(data, list):
                for item in data[:5]:
                    if isinstance(item, dict):
                        text = item.get("text") or item.get("message") or ""
                        if text:
                            lines.append(str(text)[:200])
        except Exception:
            pass
    return lines


def slugify(text: str, max_len: int = 30) -> str:
    """Generate a slug from text."""
    # Remove non-alphanumeric (keep CJK, latin, digits)
    slug = re.sub(r"[^\w\u4e00-\u9fff]", "-", text[:max_len])
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug or "insight"


def find_related_wikilinks(content: str, limit: int = 3) -> list[str]:
    """Try to find related wikilinks via closet_search."""
    try:
        sys.path.insert(0, "/home/oldrabbit/.claude-bots/shared/memocean-mcp")
        from memocean_mcp.tools.radar_search import radar_search
        # Extract card title (first line after #) for a meaningful query
        title_match = re.search(r"^#\s*(.+)", content, re.MULTILINE)
        if title_match:
            query = title_match.group(1).strip()[:100]
        else:
            query = content[:80]
        results = radar_search(query, limit=limit)
        links = []
        if isinstance(results, list):
            for r in results:
                if isinstance(r, dict):
                    slug = r.get("slug") or r.get("title") or ""
                    if slug:
                        links.append(f"[[{slug}]]")
        elif isinstance(results, str):
            # May return formatted string
            found = re.findall(r"\[([^\]]+)\]", results)
            links = [f"[[{f}]]" for f in found[:limit]]
        return links[:limit]
    except Exception as e:
        print(f"[warn] radar_search failed: {e}", file=sys.stderr)
        return []


def main():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("[pearl-draft] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(0)  # Non-fatal: don't block stop hook

    client = anthropic.Anthropic(api_key=api_key)

    conn = sqlite3.connect(DB_PATH)
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    try:
        print(f"[pearl-draft] start at {datetime.now().isoformat()}")

        # Collect content
        db_msgs = get_today_messages(conn)
        relay_msgs = get_relay_messages()
        all_lines = db_msgs + relay_msgs

        if not all_lines:
            print("[pearl-draft] no messages today, skip")
            return

        blob = "\n".join(all_lines)
        # Truncate to last 4000 chars if too long
        if len(blob) > MAX_CONTENT_CHARS:
            blob = blob[-MAX_CONTENT_CHARS:]

        print(f"[pearl-draft] content blob: {len(blob)} chars")

        # Dedup: skip if this exact blob was already processed today
        content_hash = hashlib.sha256(blob.encode()).hexdigest()[:16]
        seen = load_seen_hashes()
        if content_hash in seen:
            print(f"[pearl-draft] content hash {content_hash} already processed today, skip")
            return
        save_hash(content_hash)

        # Call Haiku
        prompt = (
            "以下是今天的對話記錄。找出含有「判斷/洞見/模式」的段落"
            "（排除純事實、操作步驟、待辦事項）。"
            "如果有，生成一張 Pearl card 草稿（繁體中文，< 300 字）。"
            "格式：\n# 卡片標題（一句話）\n\n核心想法 2-5 句話。\n\n"
            "如果沒有值得記錄的洞見，回覆 'NO_INSIGHT'。\n\n"
            "對話記錄：\n" + blob
        )

        resp = client.messages.create(
            model=HAIKU_MODEL,
            max_tokens=600,
            messages=[{"role": "user", "content": prompt}],
        )
        response_text = resp.content[0].text.strip()

        if "NO_INSIGHT" in response_text.upper() or not response_text.strip():
            print("[pearl-draft] no insight found, skip")
            return

        print(f"[pearl-draft] haiku returned content ({len(response_text)} chars)")

        # Extract title for slug
        title_match = re.search(r"^#\s*(.+)", response_text, re.MULTILINE)
        title = title_match.group(1).strip() if title_match else response_text[:30]
        slug = slugify(title)

        # Ensure draft content is < 300 chars (body, not counting frontmatter)
        body = response_text
        if len(body) > 300:
            body = body[:297] + "..."

        # Find related wikilinks (pass full body so title extraction can work)
        wikilinks = find_related_wikilinks(body)

        # Build frontmatter + content
        links_section = ""
        if wikilinks:
            links_section = "\n連結：\n" + "\n".join(f"- {l}" for l in wikilinks)

        draft_content = (
            f"---\n"
            f"type: card\n"
            f"source_bot: assistant\n"
            f"created: {today_str}\n"
            f"compiled_at: {today_str}\n"
            f"source: 對話\n"
            f"status: draft\n"
            f"---\n\n"
            f"## Compiled Truth\n\n"
            f"{body}\n"
            f"{links_section}\n\n"
            f"---\n\n"
            f"## Timeline\n\n"
            f"- {today_str} 初稿生成（對話萃取）\n"
        )

        # Write to _drafts
        drafts_path = Path(DRAFTS_DIR)
        drafts_path.mkdir(parents=True, exist_ok=True)

        filename = f"{today_str}-{slug}.md"
        filepath = drafts_path / filename

        # Skip if file with same slug already exists
        if filepath.exists():
            print(f"[pearl-draft] file already exists: {filepath}, skip")
            return

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(draft_content)

        print(f"[pearl-draft] written: {filepath}")

    finally:
        conn.close()


if __name__ == "__main__":
    main()

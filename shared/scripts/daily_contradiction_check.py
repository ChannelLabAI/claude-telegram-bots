#!/usr/bin/env python3
"""
daily_contradiction_check.py — MemOcean Gap 3: Standalone contradiction detection.

Detects new radar entries (last 7 days) that may conflict with existing entries
using Haiku LLM comparison.

Usage:
  python daily_contradiction_check.py [--db PATH] [--days N]

Output: JSON array of {slug_new, slug_old, detail} dicts printed to stdout.
Requires ANTHROPIC_API_KEY environment variable.
"""

import argparse
import datetime
import json
import logging
import os
import sqlite3
from pathlib import Path

logger = logging.getLogger("daily_contradiction_check")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

_HAIKU_MODEL = "claude-haiku-4-5-20251001"


def detect_contradictions(conn: sqlite3.Connection, recent_days: int = 7) -> list[dict]:
    """Get radar entries added in last recent_days. For each, use Haiku to compare
    against ALL existing radar entries to find potential contradictions.
    Returns list of {slug_new, slug_old, detail}.
    If ANTHROPIC_API_KEY not set: return [].
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        logger.info("detect_contradictions: ANTHROPIC_API_KEY not set, skipping")
        return []

    try:
        import anthropic
    except ImportError:
        logger.warning("detect_contradictions: anthropic package not installed, skipping")
        return []

    cutoff = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=recent_days)
    ).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        new_rows = conn.execute(
            "SELECT slug, clsc FROM radar WHERE encoded_at >= ?",
            (cutoff,),
        ).fetchall()
        all_rows = conn.execute(
            "SELECT slug, clsc FROM radar WHERE encoded_at < ?",
            (cutoff,),
        ).fetchall()
    except sqlite3.OperationalError as e:
        logger.warning("detect_contradictions: query failed: %s", e)
        return []

    if not new_rows or not all_rows:
        logger.info("detect_contradictions: no new or existing entries to compare")
        return []

    client = anthropic.Anthropic(api_key=api_key)
    contradictions = []
    chunk_size = 20

    for new_slug, new_clsc in new_rows:
        # Chunk existing entries to stay within context limits
        for chunk_start in range(0, len(all_rows), chunk_size):
            chunk = all_rows[chunk_start:chunk_start + chunk_size]
            existing_text = "\n".join(
                f"[{slug}]: {clsc[:300]}" for slug, clsc in chunk
            )
            prompt = f"""You are a knowledge base quality checker. Compare the NEW entry against EXISTING entries.
Find ONLY direct factual contradictions (e.g. same entity has conflicting facts).
Ignore stylistic differences, partial overlaps, or complementary information.

NEW ENTRY [{new_slug}]:
{new_clsc[:500]}

EXISTING ENTRIES:
{existing_text}

If you find a contradiction, output JSON array like:
[{{"slug_new": "{new_slug}", "slug_old": "existing_slug", "detail": "brief description"}}]

If no contradictions, output exactly: []
Output only valid JSON, nothing else."""

            try:
                response = client.messages.create(
                    model=_HAIKU_MODEL,
                    max_tokens=300,
                    temperature=0,
                    timeout=10,
                    messages=[{"role": "user", "content": prompt}],
                )
                text = response.content[0].text.strip()
                parsed = json.loads(text)
                if isinstance(parsed, list):
                    contradictions.extend(parsed)
            except Exception as e:
                logger.debug("detect_contradictions: Haiku call failed for %s: %s", new_slug, e)

    logger.info("detect_contradictions: found %d potential contradictions", len(contradictions))
    return contradictions


def main() -> None:
    parser = argparse.ArgumentParser(
        description="MemOcean daily contradiction detection — standalone script"
    )
    parser.add_argument(
        "--db",
        default=str(Path.home() / ".claude-bots" / "memory.db"),
        help="Path to memory.db (default: ~/.claude-bots/memory.db)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Look for new entries added in last N days (default: 7)",
    )
    args = parser.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        logger.error("DB not found at %s", db_path)
        print(json.dumps([], ensure_ascii=False))
        return

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row

    try:
        contradictions = detect_contradictions(conn, recent_days=args.days)
        print(json.dumps(contradictions, ensure_ascii=False, indent=2))
    finally:
        conn.close()


if __name__ == "__main__":
    main()

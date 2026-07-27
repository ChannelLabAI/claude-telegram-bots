#!/usr/bin/env python3
"""Ingest one mirrored Markdown file through MemOcean's idempotent file ingester."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "memocean-mcp"
sys.path.insert(0, str(ROOT))

from memocean_mcp.tools.ingest_file import ingest_file  # noqa: E402
from memocean_mcp.config import FTS_DB  # noqa: E402


def remove_relocated_radar_row(old_value: str, new_value: str) -> bool:
    old_path = Path(old_value).expanduser().resolve()
    new_path = Path(new_value).expanduser().resolve()
    if (
        old_path == new_path
        or old_path.name != new_path.name
        or old_path.suffix.lower() != ".md"
        or not old_path.is_file()
    ):
        raise ValueError("invalid relocated path")
    conn = sqlite3.connect(str(FTS_DB))
    try:
        row = conn.execute(
            "SELECT slug FROM radar WHERE drawer_path=?", (str(old_path),)
        ).fetchone()
        if not row:
            return False
        conn.execute("DELETE FROM radar WHERE drawer_path=?", (str(old_path),))
        conn.execute("DELETE FROM radar_fts WHERE slug=?", (row[0],))
        conn.commit()
        return True
    finally:
        conn.close()


def main() -> int:
    if len(sys.argv) not in (2, 4) or (len(sys.argv) == 4 and sys.argv[2] != "--relocated-from"):
        print(json.dumps({"error": "usage", "code": "USAGE"}))
        return 2
    result = ingest_file(sys.argv[1])
    if not result.get("error") and len(sys.argv) == 4:
        try:
            result["relocated_radar"] = remove_relocated_radar_row(sys.argv[3], sys.argv[1])
        except Exception:
            result = {"error": "relocated radar cleanup failed", "code": "RELOCATE_FAIL"}
    print(json.dumps(result, ensure_ascii=False))
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())

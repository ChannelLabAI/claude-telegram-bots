"""
closet_search.py — Search the closet table (CLSC skeletons) in memory.db.

Multi-term AND search: splits query on whitespace, requires all terms present
in the aaak column (legacy column name; now holds CLSC skeletons) using instr()
for Unicode safety. Handles hyphenated slugs like 'Knowledge-Infra-ADR' that
LIKE exact-phrase would miss.

Returns list of dicts: slug, aaak, tokens, drawer_path, savings_pct (vs verbatim).
"""
import sqlite3
from pathlib import Path

from ..config import FTS_DB


def closet_search(query: str, limit: int = 5) -> list[dict]:
    """
    Search CLSC skeletons in the closet table.

    Multi-term AND: 'Knowledge Infra' → aaak contains 'Knowledge' AND 'Infra'.
    Falls back to empty list if closet table doesn't exist yet.

    Returns list of dicts with keys: slug, aaak, tokens, drawer_path.
    """
    if not query or not query.strip():
        return []

    if not FTS_DB.exists():
        return []

    terms = [t.strip() for t in query.split() if t.strip()]
    if not terms:
        return []

    try:
        conn = sqlite3.connect(str(FTS_DB))
        conn.row_factory = sqlite3.Row

        # Multi-term AND via instr() — works on TEXT columns, Unicode-safe
        where = " AND ".join("instr(aaak, ?) > 0" for _ in terms)
        sql = f"SELECT slug, aaak, tokens, drawer_path FROM closet WHERE {where} LIMIT ?"
        params = terms + [limit]

        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [dict(r) for r in rows]

    except sqlite3.OperationalError:
        # closet table not yet created
        return []

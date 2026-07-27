#!/usr/bin/env python3
"""Ingest one mirrored Markdown file through MemOcean's idempotent file ingester."""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "memocean-mcp"
sys.path.insert(0, str(ROOT))

from memocean_mcp.tools.ingest_file import _make_slug, ingest_file  # noqa: E402
from memocean_mcp.config import FTS_DB  # noqa: E402


def reconcile_radar_path(
    path_value: str,
) -> tuple[bool, bool, list[dict[str, object]]]:
    """Keep one auditable survivor before ingest_file performs its path upsert."""
    source_path = Path(path_value).expanduser().resolve()
    path = str(source_path)
    canonical_slug = _make_slug(source_path)
    conn = sqlite3.connect(str(FTS_DB))
    try:
        rows = conn.execute(
            """
            SELECT rowid, slug, drawer_path
            FROM radar
            WHERE drawer_path=? OR slug=?
            ORDER BY CASE WHEN slug=? THEN 0 ELSE 1 END, rowid
            """,
            (path, canonical_slug, canonical_slug),
        ).fetchall()
        if not rows:
            return False, False, []
        kept_rowid, kept_slug, _kept_path = rows[0]
        removed: list[dict[str, object]] = []
        for rowid, slug, _drawer_path in rows[1:]:
            conn.execute("DELETE FROM radar WHERE rowid=?", (rowid,))
            conn.execute("DELETE FROM radar_fts WHERE slug=?", (slug,))
            removed.append({
                "path": path,
                "kept_rowid": kept_rowid,
                "kept_slug_before_upsert": kept_slug,
                "removed_rowid": rowid,
                "removed_slug": slug,
            })
        conn.commit()
        return True, kept_slug == canonical_slug, removed
    finally:
        conn.close()


def assert_single_radar_path(path_value: str, expected_slug: str) -> None:
    path = str(Path(path_value).expanduser().resolve())
    conn = sqlite3.connect(str(FTS_DB))
    try:
        rows = conn.execute(
            "SELECT slug FROM radar WHERE drawer_path=? ORDER BY rowid", (path,)
        ).fetchall()
    finally:
        conn.close()
    if rows != [(expected_slug,)]:
        raise RuntimeError(
            f"radar path invariant failed: expected one {expected_slug!r} row, got {rows!r}"
        )


def restore_ingested_radar_path(path_value: str, slug: str) -> None:
    """store_sonar rewrites drawer_path to its bundle; restore the source file."""
    path = str(Path(path_value).expanduser().resolve())
    conn = sqlite3.connect(str(FTS_DB))
    try:
        cursor = conn.execute(
            "UPDATE radar SET drawer_path=? WHERE slug=?", (path, slug)
        )
        if cursor.rowcount != 1:
            raise RuntimeError(f"radar slug invariant failed: {slug!r}")
        conn.commit()
    finally:
        conn.close()


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
    radar_only = len(sys.argv) == 3 and sys.argv[2] == "--radar-only"
    relocated = len(sys.argv) == 4 and sys.argv[2] == "--relocated-from"
    if len(sys.argv) != 2 and not radar_only and not relocated:
        print(json.dumps({"error": "usage", "code": "USAGE"}))
        return 2
    existed, canonical_ready, removed_duplicates = reconcile_radar_path(sys.argv[1])
    if radar_only and canonical_ready:
        result = {"slug": str(_make_slug(Path(sys.argv[1]).expanduser().resolve()))}
    else:
        result = ingest_file(sys.argv[1])
    if not result.get("error"):
        try:
            restore_ingested_radar_path(sys.argv[1], str(result["slug"]))
            assert_single_radar_path(sys.argv[1], str(result["slug"]))
            for record in removed_duplicates:
                record["kept_slug_after_upsert"] = str(result["slug"])
            result["radar_action"] = "updated" if existed else "inserted"
            result["radar_duplicates_removed"] = removed_duplicates
        except Exception:
            result = {"error": "radar path reconciliation failed", "code": "RADAR_RECONCILE_FAIL"}
    if not result.get("error") and relocated:
        try:
            result["relocated_radar"] = remove_relocated_radar_row(sys.argv[3], sys.argv[1])
        except Exception:
            result = {"error": "relocated radar cleanup failed", "code": "RELOCATE_FAIL"}
    print(json.dumps(result, ensure_ascii=False))
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())

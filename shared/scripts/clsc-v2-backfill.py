#!/usr/bin/env python3
"""
clsc-v2-backfill.py — CLSC v2 Bi-temporal migration script.

Adds valid_from / valid_until columns to the radar table, backfills
valid_from from encoded_at (all 6334 rows have this), with fallbacks
for any remaining NULLs.

Usage:
  python3 clsc-v2-backfill.py [--dry-run] [--db-path PATH]

Options:
  --dry-run     Print ALTER/UPDATE SQL but don't execute.
  --db-path     Override DB path (default: ~/.claude-bots/memory.db).
"""
import argparse
import re
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB_PATH = Path.home() / ".claude-bots" / "memory.db"


def run(db_path: Path, dry_run: bool) -> None:
    if not db_path.exists():
        print(f"[error] DB not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(str(db_path))
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(radar)")}
        has_valid_from = "valid_from" in cols
        has_valid_until = "valid_until" in cols

        # ── D1-step 1: Check idempotency ────────────────────────────────
        if has_valid_from and has_valid_until:
            print("[clsc-v2-backfill] valid_from/valid_until already exist — checking backfill only")
        else:
            # ── D1-step 2 & 3: ALTER TABLE ──────────────────────────────
            if not has_valid_from:
                sql = "ALTER TABLE radar ADD COLUMN valid_from TEXT"
                print(f"[sql] {sql}")
                if not dry_run:
                    conn.execute(sql)

            if not has_valid_until:
                sql = "ALTER TABLE radar ADD COLUMN valid_until TEXT"
                print(f"[sql] {sql}")
                if not dry_run:
                    conn.execute(sql)

            if not dry_run:
                conn.commit()

        # ── D1-step 4: Create index ──────────────────────────────────────
        sql_idx = (
            "CREATE INDEX IF NOT EXISTS idx_radar_valid_until "
            "ON radar(valid_until) WHERE valid_until IS NOT NULL"
        )
        print(f"[sql] {sql_idx}")
        if not dry_run:
            conn.execute(sql_idx)
            conn.commit()

        # ── D1-step 5: Backfill valid_from from encoded_at ───────────────
        sql_backfill = (
            "UPDATE radar SET valid_from = datetime(encoded_at) "
            "WHERE valid_from IS NULL AND encoded_at IS NOT NULL"
        )
        print(f"[sql] {sql_backfill}")
        if not dry_run:
            cur = conn.execute(sql_backfill)
            print(f"[clsc-v2-backfill] backfill from encoded_at: {cur.rowcount} rows")
            conn.commit()

        # ── D1-step 6: Fallback for remaining NULLs ──────────────────────
        # Try slug date prefix first (YYYY-MM-DD from first 10 chars)
        if not dry_run:
            null_slugs = conn.execute(
                "SELECT slug FROM radar WHERE valid_from IS NULL"
            ).fetchall()
            date_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}")
            fallback_date = 0
            fallback_default = 0
            for (slug,) in null_slugs:
                if slug and date_pattern.match(slug[:10]):
                    date_val = slug[:10] + "T00:00:00Z"
                    conn.execute(
                        "UPDATE radar SET valid_from = ? WHERE slug = ?",
                        (date_val, slug),
                    )
                    fallback_date += 1
                else:
                    conn.execute(
                        "UPDATE radar SET valid_from = '2026-01-01T00:00:00Z' WHERE slug = ?",
                        (slug,),
                    )
                    fallback_default += 1
            if null_slugs:
                conn.commit()
                print(
                    f"[clsc-v2-backfill] fallback: date-prefix={fallback_date}, "
                    f"default-2026-01-01={fallback_default}"
                )
        else:
            sql_fallback_date = (
                "UPDATE radar SET valid_from = (slug || 'T00:00:00Z') "
                "WHERE valid_from IS NULL AND slug REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}'"
            )
            sql_fallback_default = (
                "UPDATE radar SET valid_from = '2026-01-01T00:00:00Z' "
                "WHERE valid_from IS NULL"
            )
            print(f"[sql] {sql_fallback_date}")
            print(f"[sql] {sql_fallback_default}")

        if not dry_run:
            # Final sanity check
            null_count = conn.execute(
                "SELECT count(*) FROM radar WHERE valid_from IS NULL"
            ).fetchone()[0]
            total = conn.execute("SELECT count(*) FROM radar").fetchone()[0]
            print(
                f"[clsc-v2-backfill] done. total={total}, valid_from_nulls={null_count}"
            )
            if null_count > 0:
                print(
                    f"[warn] {null_count} rows still have NULL valid_from!",
                    file=sys.stderr,
                )
        else:
            print("[clsc-v2-backfill] dry-run complete — no changes made")

    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="CLSC v2 bi-temporal migration")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print SQL but don't execute",
    )
    parser.add_argument(
        "--db-path",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Path to memory.db (default: {DEFAULT_DB_PATH})",
    )
    args = parser.parse_args()
    run(args.db_path, args.dry_run)


if __name__ == "__main__":
    main()

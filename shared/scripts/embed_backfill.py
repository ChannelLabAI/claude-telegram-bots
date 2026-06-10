#!/usr/bin/env python3
"""P1 M1: Embed backfill — fill missing radar_vec rows.
Usage: python3 embed_backfill.py [--batch N] [--db PATH] [--dry-run]

Finds radar rows whose slug has no entry in radar_vec, then embeds and stores them.
radar_vec uses sqlite-vec virtual table (slug-keyed). Coverage tracked via health_metrics.
"""
import argparse
import datetime
import sqlite3
import sys
from pathlib import Path

# Add memocean-mcp to Python path
sys.path.insert(0, str(Path.home() / '.claude-bots/shared/memocean-mcp'))


def main():
    parser = argparse.ArgumentParser(description='P1 M1: Embed backfill for radar_vec')
    parser.add_argument('--batch', type=int, default=200, help='Max rows to embed per run')
    parser.add_argument('--db', default=str(Path.home() / '.claude-bots/memory.db'), help='Path to memory.db')
    parser.add_argument('--dry-run', action='store_true', help='Preview without writing embeddings')
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)

    # Check loop_config.embed_backfill_enabled
    try:
        row = conn.execute("SELECT value FROM loop_config WHERE key='embed_backfill_enabled'").fetchone()
        if row and row[0] == '0':
            print('[embed_backfill] disabled via loop_config')
            conn.close()
            return
    except sqlite3.OperationalError:
        # loop_config table not yet created — safe to continue
        pass

    # Try to load sqlite-vec extension
    has_vec = False
    try:
        conn.enable_load_extension(True)
        import sqlite_vec  # type: ignore
        conn.load_extension(sqlite_vec.loadable_path())
        has_vec = True
    except Exception as e:
        print(f'[embed_backfill] sqlite-vec not available: {e}')

    if not has_vec:
        print('[embed_backfill] sqlite-vec required but not available — skipping')
        conn.close()
        return

    # Find radar rows without embeddings.
    # radar_vec_rowids.id stores slug values (not integer rowids).
    # A radar row is "missing" its embedding when its slug is not in radar_vec_rowids.id.
    try:
        rows = conn.execute("""
            SELECT r.slug, COALESCE(r.content, r.clsc, '') as text
            FROM radar r
            WHERE r.slug IS NOT NULL AND r.slug != ''
              AND NOT EXISTS (
                  SELECT 1 FROM radar_vec_rowids rv WHERE rv.id = r.slug
              )
            ORDER BY r.encoded_at DESC
            LIMIT ?
        """, (args.batch,)).fetchall()
    except sqlite3.OperationalError as e:
        print(f'[embed_backfill] query error: {e}')
        conn.close()
        return

    if not rows:
        print('[embed_backfill] no rows to backfill')
        # Still report coverage
        _report_coverage(conn, args.dry_run)
        conn.close()
        return

    print(f'[embed_backfill] {len(rows)} rows need embeddings...')

    if args.dry_run:
        print(f'[embed_backfill] DRY-RUN: would embed {len(rows)} rows')
        _report_coverage(conn, dry_run=True)
        conn.close()
        return

    # Import reranker and embed
    try:
        from memocean_mcp.tools.reranker import embed_and_store_batch  # type: ignore
    except ImportError as e:
        print(f'[embed_backfill] cannot import reranker: {e}')
        conn.close()
        return

    items = [(slug, text or '') for slug, text in rows]
    done = embed_and_store_batch(conn, items)
    print(f'[embed_backfill] embedded {done}/{len(rows)} rows')

    _report_coverage(conn, dry_run=False)
    conn.close()


def _report_coverage(conn: sqlite3.Connection, dry_run: bool) -> None:
    """Report embedding coverage and write to health_metrics."""
    try:
        total = conn.execute('SELECT COUNT(*) FROM radar').fetchone()[0]
        vec_count = conn.execute(
            'SELECT COUNT(DISTINCT id) FROM radar_vec_rowids'
        ).fetchone()[0]
        coverage = vec_count / total if total > 0 else 0.0
        print(f'[embed_backfill] coverage: {vec_count}/{total} = {coverage:.1%}')

        if dry_run:
            return

        now = datetime.datetime.utcnow().isoformat() + 'Z'
        status = 'GREEN' if coverage > 0.5 else 'AMBER'
        conn.execute(
            'INSERT INTO health_metrics (ts, signal, value, status) VALUES (?, ?, ?, ?)',
            (now, 'embed_backfill_coverage', coverage, status),
        )
        conn.commit()
    except Exception as e:
        print(f'[embed_backfill] coverage report error: {e}')


if __name__ == '__main__':
    main()

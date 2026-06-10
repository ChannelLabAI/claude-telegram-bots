#!/usr/bin/env python3
"""setup-p1-tables.py — Diana P1 table setup.
Creates: query_log, chat_owner_map, proposal_queue, stale_resolution_log, loop_config
Run once: python3 setup-p1-tables.py
"""
import sqlite3
from pathlib import Path

DB_PATH = Path.home() / '.claude-bots' / 'memory.db'

DDL = [
    """CREATE TABLE IF NOT EXISTS query_log (
        ts TEXT,
        query TEXT,
        source TEXT,
        hit_count INTEGER,
        top_score REAL
    )""",
    """CREATE TABLE IF NOT EXISTS chat_owner_map (
        chat_id TEXT PRIMARY KEY,
        owner TEXT,
        confidence REAL,
        method TEXT
    )""",
    """CREATE TABLE IF NOT EXISTS proposal_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT,
        kind TEXT,
        summary TEXT,
        evidence_json TEXT,
        status TEXT DEFAULT 'pending',
        decided_by TEXT,
        decided_at TEXT
    )""",
    """CREATE TABLE IF NOT EXISTS stale_resolution_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT,
        stale_candidate_id INTEGER,
        slug TEXT,
        action TEXT,
        reason TEXT,
        reversible INTEGER DEFAULT 1
    )""",
    """CREATE TABLE IF NOT EXISTS loop_config (
        key TEXT PRIMARY KEY,
        value TEXT
    )""",
]

LOOP_CONFIG_DEFAULTS = [
    ('loop_enabled', '1'),
    ('query_log_enabled', '1'),
    ('embed_backfill_enabled', '1'),
    ('embed_backfill_batch', '200'),
    ('stale_digest_enabled', '1'),
    ('stale_digest_batch', '80'),
    ('owner_mapping_enabled', '1'),
    ('owner_auto_threshold', '0.8'),
    ('max_actions_per_day', '2000'),
]


def main():
    print(f'[setup-p1-tables] DB: {DB_PATH}')
    conn = sqlite3.connect(str(DB_PATH))

    for ddl in DDL:
        table_name = ddl.split('EXISTS')[1].split('(')[0].strip()
        conn.execute(ddl)
        print(f'  [ok] table: {table_name}')

    for key, value in LOOP_CONFIG_DEFAULTS:
        conn.execute(
            "INSERT OR IGNORE INTO loop_config (key, value) VALUES (?, ?)",
            (key, value),
        )
        print(f'  [ok] loop_config: {key} = {value}')

    conn.commit()

    # Verify all 5 tables exist
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).fetchall()]
    required = {'query_log', 'chat_owner_map', 'proposal_queue', 'stale_resolution_log', 'loop_config'}
    missing = required - set(tables)
    if missing:
        print(f'[ERROR] missing tables: {missing}')
        conn.close()
        raise SystemExit(1)

    # Verify loop_config rows
    cfg_rows = conn.execute("SELECT key, value FROM loop_config ORDER BY key").fetchall()
    print(f'\n[verify] loop_config ({len(cfg_rows)} rows):')
    for k, v in cfg_rows:
        print(f'  {k} = {v}')

    conn.close()
    print('\n[setup-p1-tables] All 5 tables ready.')


if __name__ == '__main__':
    main()

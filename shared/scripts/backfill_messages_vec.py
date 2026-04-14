#!/usr/bin/env python3
"""
backfill_messages_vec.py — Embed all messages into messages_vec for semantic search.

Idempotent: skips messages already present in messages_vec.
Uses BGE-m3 (ONNX INT8 or FlagEmbedding) via reranker._embed_texts.
"""
import sys
import os
import time
import sqlite3

# Make memocean_mcp importable
_MCP_PATH = "/home/oldrabbit/.claude-bots/shared/memocean-mcp"
if _MCP_PATH not in sys.path:
    sys.path.insert(0, _MCP_PATH)

DB_PATH = "/home/oldrabbit/.claude-bots/memory.db"
BATCH_SIZE = 32

def main():
    t0 = time.monotonic()

    # Try to import required modules
    try:
        from memocean_mcp.tools.reranker import _embed_texts, _load_sqlite_vec, _float_vec_to_blob, _EMBED_DIM
    except ImportError as e:
        print(f"[backfill] WARNING: cannot import memocean_mcp.tools.reranker: {e}")
        print("[backfill] Exiting gracefully — install memocean-mcp dependencies first.")
        sys.exit(0)

    # Connect to DB
    conn = sqlite3.connect(DB_PATH)

    # Load sqlite-vec extension
    if not _load_sqlite_vec(conn):
        print("[backfill] WARNING: sqlite-vec extension not available.")
        print("[backfill] Exiting gracefully — install sqlite-vec first.")
        conn.close()
        sys.exit(0)

    # Create messages_vec virtual table if not exists
    conn.execute(
        f"CREATE VIRTUAL TABLE IF NOT EXISTS messages_vec "
        f"USING vec0(msg_key TEXT PRIMARY KEY, embedding float[{_EMBED_DIM}])"
    )
    conn.commit()

    # Find messages that need embedding (idempotent)
    rows = conn.execute(
        """
        SELECT chat_id, message_id, text FROM messages
        WHERE text IS NOT NULL AND text != ''
        AND (chat_id || ':' || message_id) NOT IN (SELECT msg_key FROM messages_vec)
        """
    ).fetchall()

    total = len(rows)
    # Count already-embedded (skipped)
    already_embedded = conn.execute("SELECT count(*) FROM messages_vec").fetchone()[0]
    skipped = already_embedded

    print(f"[backfill] {total} messages to embed, {skipped} already embedded (skipped)")

    if total == 0:
        elapsed = time.monotonic() - t0
        print(f"[backfill] done. 0 embedded, {skipped} skipped, elapsed {elapsed:.1f}s")
        conn.close()
        return

    stored = 0
    errors = 0

    for i in range(0, total, BATCH_SIZE):
        batch = rows[i:i + BATCH_SIZE]
        texts = [r[2] for r in batch]  # text column
        msg_keys = [f"{r[0]}:{r[1]}" for r in batch]  # chat_id:message_id

        embs = _embed_texts(texts)
        if embs is None:
            print(f"[backfill] WARNING: embedding failed for batch {i}–{i+len(batch)}, skipping")
            errors += len(batch)
            continue

        for msg_key, emb in zip(msg_keys, embs):
            blob = _float_vec_to_blob(emb)
            conn.execute("DELETE FROM messages_vec WHERE msg_key = ?", (msg_key,))
            conn.execute(
                "INSERT INTO messages_vec(msg_key, embedding) VALUES (?, ?)",
                (msg_key, blob),
            )
        conn.commit()

        stored += len(batch)
        print(f"[backfill] {stored}/{total} messages embedded")

    elapsed = time.monotonic() - t0
    print(f"[backfill] done. {stored} embedded, {skipped} skipped, elapsed {elapsed:.1f}s")
    if errors:
        print(f"[backfill] WARNING: {errors} messages failed to embed")

    conn.close()


if __name__ == "__main__":
    main()

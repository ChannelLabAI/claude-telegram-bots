#!/usr/bin/env python3
"""
tg_daily_ingest.py — Daily TG message ingest to Ocean/Seabed
Stage 1: Rule-based pre-filter (~200 → ~50)
Stage 2: Haiku reranking (~50 → ≤20)
Then: write CLSC sonar to memory.db radar + seabed/chats.clsc.md
"""

import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

import anthropic

# Ocean Seabed writer — optional import (graceful degradation if not available)
try:
    _SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
    if _SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, _SCRIPTS_DIR)
    from ocean_seabed_write import write_message_to_seabed as _write_seabed
    _SEABED_ENABLED = True
except ImportError as _e:
    _SEABED_ENABLED = False
    import logging as _log
    _log.getLogger("tg_daily_ingest").warning("ocean_seabed_write not available: %s", _e)

# ── Config ────────────────────────────────────────────────────────────────────
DB_PATH = os.path.expanduser("~/.claude-bots/memory.db")
CHATS_CLSC = os.path.expanduser("~/.claude-bots/seabed/chats.clsc.md")
CHATS_CLSC_OBSIDIAN = os.path.expanduser(
    "~/Documents/Obsidian Vault/Ocean/Seabed/chats/_index.clsc.md"
)
OLDRABBIT_CHAT_ID = "1050312492"
HAIKU_MODEL = "claude-haiku-4-5-20251001"
DECISION_KEYWORDS = ["確認", "決定", "方向", "改成", "取消", "結論"]
MONEY_PATTERN = re.compile(r"(NT\$|USD\$|\$)\d+")


def get_today_messages(conn: sqlite3.Connection) -> list[dict]:
    """Query messages for today (UTC+8 midnight = 16:00 UTC previous day)."""
    cur = conn.cursor()
    cur.execute(
        """
        SELECT chat_id, message_id, user, ts, text
        FROM messages
        WHERE ts >= datetime('now', 'start of day', '-8 hours')
          AND text IS NOT NULL
          AND text != ''
        ORDER BY ts ASC
        """
    )
    rows = cur.fetchall()
    return [
        {
            "chat_id": r[0],
            "message_id": r[1],
            "user": r[2],
            "ts": r[3],
            "text": r[4],
        }
        for r in rows
    ]


def rule_filter(messages: list[dict]) -> list[dict]:
    """Stage 1: Rule-based pre-filter."""
    kept = []
    for msg in messages:
        text = msg.get("text") or ""
        if len(text) > 100:
            kept.append(msg)
            continue
        if any(kw in text for kw in DECISION_KEYWORDS):
            kept.append(msg)
            continue
        if MONEY_PATTERN.search(text):
            kept.append(msg)
            continue
        if msg.get("user") == "oldrabbit_eth" or "@oldrabbit" in text.lower():
            kept.append(msg)
            continue
    return kept


def haiku_rerank(client: anthropic.Anthropic, messages: list[dict]) -> list[tuple[dict, int]]:
    """Stage 2: Haiku scoring, keep score >= 3. Returns list of (message, score) pairs."""
    if not messages:
        return []

    items = []
    for i, msg in enumerate(messages):
        text = msg["text"][:300]  # truncate for prompt
        items.append(f"{i}. {text}")

    prompt = (
        "以下是一批 Telegram 訊息。請為每一條訊息評分 1-5，"
        "評分標準：對商業團隊知識庫的長期價值。\n"
        "5=極高價值（決策/洞見/重要共識），3=有一定參考價值，1=無長期意義。\n"
        "只回傳 JSON 陣列，格式：[{\"index\": 0, \"score\": 3}, ...]\n\n"
        + "\n".join(items)
    )

    try:
        resp = client.messages.create(
            model=HAIKU_MODEL,
            max_tokens=1024,
            messages=[{"role": "user", "content": prompt}],
        )
        raw = resp.content[0].text.strip()
        # Extract JSON array from response
        match = re.search(r"\[.*\]", raw, re.DOTALL)
        if not match:
            print(f"[warn] haiku rerank: no JSON array found, keeping all", file=sys.stderr)
            return [(msg, 3) for msg in messages]
        scores = json.loads(match.group(0))
        score_map = {item["index"]: item["score"] for item in scores}
        kept = [
            (msg, score_map.get(i, 0))
            for i, msg in enumerate(messages)
            if score_map.get(i, 0) >= 3
        ]
        return kept[:20]
    except Exception as e:
        print(f"[warn] haiku rerank failed: {e}, keeping all pre-filtered", file=sys.stderr)
        return [(msg, 3) for msg in messages[:20]]


def extract_entities(text: str, max_count: int = 5) -> list[str]:
    """Simple entity extraction: words > 3 chars, deduplicated."""
    # Remove punctuation, split
    words = re.findall(r"[\w\u4e00-\u9fff]+", text)
    # CJK chars: keep sequences >= 2; Latin words: keep length >= 4
    entities = []
    seen = set()
    for w in words:
        if len(w) >= 2 and w not in seen:
            seen.add(w)
            entities.append(w)
        if len(entities) >= max_count:
            break
    return entities


def build_clsc_skeleton(msg: dict, score: int) -> str:
    """Build CLSC skeleton line for a message."""
    text = msg.get("text", "")
    # Parse date from ts (format: 2026-04-10T...)
    ts = msg.get("ts", "")
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        date_str = dt.strftime("%Y%m%d")
    except Exception:
        date_str = datetime.now(timezone.utc).strftime("%Y%m%d")

    try:
        chat_id_abs = abs(int(msg.get("chat_id", 0)))
    except (ValueError, TypeError):
        chat_id_abs = 0
    message_id = msg.get("message_id", "0")
    slug = f"tg-{date_str}-{chat_id_abs}-{message_id}"

    entities = extract_entities(text)
    entities_str = ",".join(entities) if entities else "unknown"

    # Topics: 2-3 simple tags based on content
    topics = []
    if any(kw in text for kw in ["決定", "確認", "結論", "方向"]):
        topics.append("decision")
    if MONEY_PATTERN.search(text):
        topics.append("finance")
    if len(text) > 200:
        topics.append("discussion")
    if not topics:
        topics.append("chat")
    topics_str = ",".join(topics[:3])

    key_quote = text[:50].replace("|", "｜").replace('"', "'")
    weight = score

    return slug, f'[{slug}|{entities_str}|{topics_str}|"{key_quote}"|{weight}|neutral|tg]'


def slug_in_file(slug: str, filepath: str) -> bool:
    """Check if slug already exists in file."""
    if not os.path.exists(filepath):
        return False
    with open(filepath, "r", encoding="utf-8") as f:
        return slug in f.read()


def ingest_message(
    conn: sqlite3.Connection, msg: dict, score: int, chats_clsc_path: str,
    extra_clsc_paths: list[str] | None = None
) -> bool:
    """Write message to radar table and chats.clsc.md. Returns True if ingested."""
    slug, skeleton_line = build_clsc_skeleton(msg, score)

    # Write to radar table
    import hashlib
    text = msg.get("text", "")
    source_hash = hashlib.md5(text.encode()).hexdigest()
    drawer_path = f"tg:{msg['chat_id']}:{msg['message_id']}"
    tokens = len(text) // 4  # rough estimate

    cur = conn.cursor()
    cur.execute(
        """
        INSERT OR IGNORE INTO radar (slug, clsc, tokens, drawer_path, source_hash)
        VALUES (?, ?, ?, ?, ?)
        """,
        (slug, skeleton_line, tokens, drawer_path, source_hash),
    )
    inserted_db = cur.rowcount > 0

    # Non-blocking: embed message into messages_vec for semantic search
    try:
        import sys as _sys
        _mcp_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "memocean-mcp")
        if _mcp_path not in _sys.path:
            _sys.path.insert(0, _mcp_path)
        from memocean_mcp.tools.reranker import _embed_texts, _load_sqlite_vec, _float_vec_to_blob, _EMBED_DIM
        msg_key = f"{msg['chat_id']}:{msg['message_id']}"
        msg_text = msg.get("text", "")
        if msg_text and _load_sqlite_vec(conn):
            conn.execute(
                "CREATE VIRTUAL TABLE IF NOT EXISTS messages_vec "
                f"USING vec0(msg_key TEXT PRIMARY KEY, embedding float[{_EMBED_DIM}])"
            )
            embs = _embed_texts([msg_text])
            if embs:
                blob = _float_vec_to_blob(embs[0])
                conn.execute("DELETE FROM messages_vec WHERE msg_key = ?", (msg_key,))
                conn.execute("INSERT INTO messages_vec(msg_key, embedding) VALUES (?, ?)", (msg_key, blob))
                conn.commit()
    except Exception as _e:
        import logging as _logging
        _logging.getLogger("tg_daily_ingest").warning("messages_vec embed failed for %s: %s", msg.get("message_id"), _e)

    # Append to chats.clsc.md if not already there
    inserted_file = False
    for path in [chats_clsc_path] + (extra_clsc_paths or []):
        if not slug_in_file(slug, path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(skeleton_line + "\n")
            inserted_file = True

    return inserted_db or inserted_file


def main():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("[error] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)
    conn = sqlite3.connect(DB_PATH)

    try:
        print(f"[tg-daily-ingest] start at {datetime.now().isoformat()}")

        # Stage 0: Ocean Origin Rule — write ALL raw messages to Seabed first.
        # This is unconditional; rule_filter/haiku_rerank below are for CLSC/radar curation only.
        all_msgs = get_today_messages(conn)
        print(f"[tg-daily-ingest] total today: {len(all_msgs)}")

        if _SEABED_ENABLED:
            seabed_written = 0
            for _msg in all_msgs:
                try:
                    _write_seabed(_msg)
                    seabed_written += 1
                except Exception as _se:
                    import logging as _logging
                    _logging.getLogger("tg_daily_ingest").warning(
                        "seabed write failed for %s:%s: %s",
                        _msg.get("chat_id"), _msg.get("message_id"), _se,
                    )
            print(f"[tg-daily-ingest] seabed written: {seabed_written}/{len(all_msgs)}")

        filtered = rule_filter(all_msgs)
        print(f"[tg-daily-ingest] after rule filter: {len(filtered)}")

        if not filtered:
            print("[tg-daily-ingest] nothing to ingest, done")
            return

        # Cap at 50 for Haiku
        filtered = filtered[:50]

        # Stage 2: Haiku rerank — returns list of (msg, score) pairs
        ranked_pairs = haiku_rerank(client, filtered)
        print(f"[tg-daily-ingest] after haiku rerank: {len(ranked_pairs)}")

        # Ingest each message using the score from the single Haiku call
        ingested = 0
        for msg, score in ranked_pairs:
            if ingest_message(conn, msg, score, CHATS_CLSC, extra_clsc_paths=[CHATS_CLSC_OBSIDIAN]):
                ingested += 1

        conn.commit()
        print(f"[tg-daily-ingest] ingested: {ingested}, done at {datetime.now().isoformat()}")

    finally:
        conn.close()


if __name__ == "__main__":
    main()

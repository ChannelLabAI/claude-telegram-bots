#!/usr/bin/env python3
"""
stale_knowledge_check.py — MemOcean P4: Stale Knowledge Detection weekly health check.

Detects:
  - Cold entries: radar rows not accessed in >= 30 days (or never accessed, encoded > 30 days ago)
  - Contradictions: new radar entries (last 7 days) that may conflict with existing entries

Usage:
  python stale_knowledge_check.py [--dry-run] [--db PATH]
"""

import argparse
import datetime
import json
import logging
import os
import sqlite3
from pathlib import Path

logger = logging.getLogger("stale_knowledge_check")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

_TG_GROUP_CHAT_ID = "GROUP_CHAT_ID"
_HAIKU_MODEL = "claude-haiku-4-5-20251001"


def migrate_schema(conn: sqlite3.Connection) -> None:
    """Add last_accessed column to radar and create stale_candidates table. Idempotent."""
    # Check if last_accessed already exists
    cols = {row[1] for row in conn.execute("PRAGMA table_info(radar)")}
    if "last_accessed" not in cols:
        try:
            conn.execute("ALTER TABLE radar ADD COLUMN last_accessed TEXT")
            conn.commit()
            logger.info("migrate_schema: added last_accessed column to radar")
        except sqlite3.OperationalError as e:
            # Another process may have added it already
            logger.debug("migrate_schema: last_accessed already exists or error: %s", e)

    # Create stale_candidates table
    conn.execute("""
        CREATE TABLE IF NOT EXISTS stale_candidates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slug TEXT NOT NULL,
            reason TEXT NOT NULL,
            detail TEXT,
            detected_at TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            confirmed_by TEXT,
            UNIQUE(slug, reason)
        )
    """)
    conn.commit()
    logger.debug("migrate_schema: stale_candidates table ensured")


def detect_cold_entries(conn: sqlite3.Connection, days: int = 30) -> list[dict]:
    """Return slugs cold for >= days (never accessed OR last_accessed older than days).
    Also require encoded_at > 30 days ago (skip brand-new entries).
    Returns list of {slug, encoded_at, last_accessed}"""
    cutoff = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    ).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        rows = conn.execute(
            """
            SELECT slug, encoded_at, last_accessed
            FROM radar
            WHERE encoded_at < ?
              AND (last_accessed IS NULL OR last_accessed < ?)
            """,
            (cutoff, cutoff),
        ).fetchall()
    except sqlite3.OperationalError as e:
        logger.warning("detect_cold_entries: query failed: %s", e)
        return []

    result = []
    for row in rows:
        result.append({
            "slug": row[0],
            "encoded_at": row[1],
            "last_accessed": row[2],
        })
    logger.info("detect_cold_entries: found %d cold entries (>=%d days)", len(result), days)
    return result


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
        # Chunk existing entries
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


def write_stale_candidates(conn: sqlite3.Connection, candidates: list[dict]) -> int:
    """INSERT OR IGNORE into stale_candidates. Returns count inserted."""
    if not candidates:
        return 0

    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    inserted = 0

    for c in candidates:
        slug = c.get("slug") or c.get("slug_new", "")
        reason = c.get("reason", "cold")
        detail = c.get("detail")

        if not slug:
            continue

        # Check if already exists
        existing = conn.execute(
            "SELECT id FROM stale_candidates WHERE slug=? AND reason=?",
            (slug, reason),
        ).fetchone()
        if existing:
            continue

        conn.execute(
            "INSERT INTO stale_candidates (slug, reason, detail, detected_at, status) VALUES (?, ?, ?, ?, 'pending')",
            (slug, reason, detail, now),
        )
        inserted += 1

    conn.commit()
    logger.info("write_stale_candidates: inserted %d new candidates", inserted)
    return inserted


def generate_report(conn: sqlite3.Connection) -> dict:
    """Return {cold_count, contradiction_count, pending_total, sample_cold: [slug, ...] up to 5}"""
    try:
        cold_count = conn.execute(
            "SELECT COUNT(*) FROM stale_candidates WHERE reason='cold'"
        ).fetchone()[0]
        contradiction_count = conn.execute(
            "SELECT COUNT(*) FROM stale_candidates WHERE reason='contradiction'"
        ).fetchone()[0]
        pending_total = conn.execute(
            "SELECT COUNT(*) FROM stale_candidates WHERE status='pending'"
        ).fetchone()[0]
        sample_cold = [
            row[0] for row in conn.execute(
                "SELECT slug FROM stale_candidates WHERE reason='cold' LIMIT 5"
            ).fetchall()
        ]
    except sqlite3.OperationalError:
        cold_count = contradiction_count = pending_total = 0
        sample_cold = []

    return {
        "cold_count": cold_count,
        "contradiction_count": contradiction_count,
        "pending_total": pending_total,
        "sample_cold": sample_cold,
    }


def send_tg_report(report: dict, tg_token: str, chat_id: str) -> None:
    """POST to Telegram Bot API. Chat to: team group (GROUP_CHAT_ID)."""
    import urllib.request

    cold = report.get("cold_count", 0)
    contradiction = report.get("contradiction_count", 0)
    pending = report.get("pending_total", 0)
    sample = report.get("sample_cold", [])
    sample_line = ""
    if sample:
        sample_line = "\n樣本: " + ", ".join(sample[:5])

    text = (
        f"📊 Stale Knowledge 週報\n"
        f"冷條目: {cold}\n"
        f"潛在矛盾: {contradiction}\n"
        f"待確認: {pending}"
        f"{sample_line}"
    )

    url = f"https://api.telegram.org/bot{tg_token}/sendMessage"
    payload = json.dumps({
        "chat_id": chat_id,
        "text": text,
    }).encode("utf-8")

    try:
        import urllib.request
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
        logger.info("send_tg_report: TG message sent to %s", chat_id)
    except Exception as e:
        logger.warning("send_tg_report: failed: %s", e)


def run_health_check(db_path: Path, dry_run: bool = False) -> dict:
    """Main entry: migrate + detect cold + detect contradictions + write candidates (if not dry_run) + generate report + send TG (if not dry_run).
    Returns report dict."""
    if not db_path.exists():
        logger.warning("run_health_check: DB not found at %s", db_path)
        return {"cold_count": 0, "contradiction_count": 0, "pending_total": 0, "sample_cold": []}

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row

    try:
        # Step 1: Migrate schema
        migrate_schema(conn)

        # Step 2: Detect cold entries
        cold_entries = detect_cold_entries(conn)
        cold_candidates = [
            {"slug": e["slug"], "reason": "cold", "detail": None}
            for e in cold_entries
        ]

        # Step 3: Detect contradictions
        contradiction_list = detect_contradictions(conn)
        contradiction_candidates = [
            {
                "slug": c.get("slug_new", c.get("slug", "")),
                "reason": "contradiction",
                "detail": c.get("detail"),
            }
            for c in contradiction_list
        ]

        all_candidates = cold_candidates + contradiction_candidates

        # Step 4: Write candidates (skip if dry-run)
        if not dry_run:
            write_stale_candidates(conn, all_candidates)
        else:
            logger.info("run_health_check: dry-run, skipping write_stale_candidates")

        # Step 5: Generate report
        report = generate_report(conn)
        # In dry-run, override with detected counts since nothing was written
        if dry_run:
            report["cold_count"] = len(cold_candidates)
            report["contradiction_count"] = len(contradiction_candidates)
            report["pending_total"] = len(all_candidates)
            report["sample_cold"] = [e["slug"] for e in cold_entries[:5]]

        # Step 6: Send TG (skip if dry-run)
        if not dry_run:
            tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
            if tg_token:
                send_tg_report(report, tg_token, _TG_GROUP_CHAT_ID)
            else:
                logger.warning("run_health_check: TELEGRAM_BOT_TOKEN not set, skipping TG")
        else:
            logger.info("run_health_check: dry-run, skipping TG send")

        return report

    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MemOcean P4: Stale Knowledge Detection")
    parser.add_argument("--dry-run", action="store_true", help="Detect only, do not write to DB or send TG")
    parser.add_argument("--db", default=str(Path.home() / ".claude-bots" / "memory.db"), help="Path to memory.db")
    args = parser.parse_args()

    report = run_health_check(Path(args.db), dry_run=args.dry_run)
    print(json.dumps(report, ensure_ascii=False, indent=2))

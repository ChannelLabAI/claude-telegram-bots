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

_TG_GROUP_CHAT_ID = "-1003634255226"
_HAIKU_MODEL = "claude-haiku-4-5-20251001"


def migrate_schema(conn: sqlite3.Connection) -> None:
    """Add required columns to radar and create stale_candidates table. Idempotent."""
    # Check existing columns
    cols = {row[1] for row in conn.execute("PRAGMA table_info(radar)")}

    # All required radar columns (Gap 3/4 additions: confidence, access_count, status)
    new_radar_cols = [
        ("last_accessed", "TEXT"),
        ("confidence", "REAL DEFAULT 0.8"),
        ("access_count", "INTEGER DEFAULT 0"),
        ("status", "TEXT DEFAULT 'active'"),
    ]
    for col_name, col_def in new_radar_cols:
        if col_name not in cols:
            try:
                conn.execute(f"ALTER TABLE radar ADD COLUMN {col_name} {col_def}")
                conn.commit()
                logger.info("migrate_schema: added %s column to radar", col_name)
            except sqlite3.OperationalError as e:
                logger.debug("migrate_schema: %s already exists or error: %s", col_name, e)

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
        f"📊 KG 健康日報\n"
        f"冷條目（30天未存取）: {cold}\n"
        f"待確認: {pending}"
        f"{sample_line}\n\n"
        f"@annadesu_bot 請確認冷條目是否需要清理或補強。"
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


def archive_stale_entries(conn: sqlite3.Connection, db_path: Path) -> int:
    """Archive entries with status='pending' AND detected_at < now - 14 days.

    Archive = write to ~/Documents/Obsidian Vault/Ocean/Depth/{slug}.md
    Update DB: status='archived'
    Returns count of archived entries.
    """
    cutoff = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)
    ).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        rows = conn.execute(
            "SELECT id, slug, reason, detail, detected_at FROM stale_candidates "
            "WHERE status='pending' AND detected_at < ?",
            (cutoff,),
        ).fetchall()
    except sqlite3.OperationalError as e:
        logger.warning("archive_stale_entries: query failed: %s", e)
        return 0

    if not rows:
        logger.info("archive_stale_entries: no entries eligible for archiving")
        return 0

    depth_dir = Path.home() / "Documents" / "Obsidian Vault" / "Ocean" / "Depth"
    depth_dir.mkdir(parents=True, exist_ok=True)

    archived = 0
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    for row in rows:
        entry_id = row[0]
        slug = row[1]
        reason = row[2]
        detail = row[3] or ""
        detected_at = row[4]

        # Fetch radar entry for context
        radar_clsc = ""
        try:
            radar_row = conn.execute(
                "SELECT clsc FROM radar WHERE slug=?", (slug,)
            ).fetchone()
            if radar_row:
                radar_clsc = radar_row[0] or ""
        except Exception:
            pass

        # Write archive file — use Path(slug).name to prevent path traversal
        archive_path = depth_dir / Path(slug).name
        assert archive_path.parent == depth_dir, f"path traversal detected: {archive_path}"
        content = (
            f"---\n"
            f"slug: {slug}\n"
            f"reason: {reason}\n"
            f"detected_at: {detected_at}\n"
            f"archived_at: {now}\n"
            f"status: archived\n"
            f"---\n\n"
            f"# Archived: {slug}\n\n"
            f"**Reason**: {reason}\n\n"
            f"**Detail**: {detail}\n\n"
            f"**Detected at**: {detected_at}\n\n"
        )
        if radar_clsc:
            content += f"## Last Known Content\n\n```\n{radar_clsc[:1000]}\n```\n"

        try:
            archive_path.write_text(content, encoding="utf-8")
        except Exception as e:
            logger.warning("archive_stale_entries: failed to write %s: %s", archive_path, e)
            continue

        # Update stale_candidates status
        try:
            conn.execute(
                "UPDATE stale_candidates SET status='archived' WHERE id=?",
                (entry_id,),
            )
        except Exception as e:
            logger.warning("archive_stale_entries: failed to update DB for %s: %s", slug, e)
            continue

        # Also update radar entry status if column exists
        try:
            radar_cols = {r[1] for r in conn.execute("PRAGMA table_info(radar)")}
            if "status" in radar_cols:
                conn.execute(
                    "UPDATE radar SET status='archived' WHERE slug=?",
                    (slug,),
                )
        except Exception:
            pass

        archived += 1
        logger.info("archive_stale_entries: archived %s → %s", slug, archive_path)

    conn.commit()
    logger.info("archive_stale_entries: archived %d entries total", archived)
    return archived


def run_health_check(db_path: Path, dry_run: bool = False, archive: bool = False) -> dict:
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

        # Step 3: Contradiction detection — delegated to bot session via TG notification
        # (removed Haiku call; Anya reviews cold entries and handles contradictions in session)
        contradiction_candidates = []

        all_candidates = cold_candidates + contradiction_candidates

        # Step 4: Write candidates (skip if dry-run)
        if not dry_run:
            write_stale_candidates(conn, all_candidates)
        else:
            logger.info("run_health_check: dry-run, skipping write_stale_candidates")

        # Step 4.5: Archive old pending entries (only when --archive flag is set)
        archived_count = 0
        if archive and not dry_run:
            archived_count = archive_stale_entries(conn, db_path)
            logger.info("run_health_check: archived %d entries", archived_count)
        elif archive and dry_run:
            logger.info("run_health_check: dry-run + archive — skipping archive writes")

        # Step 5: Generate report
        report = generate_report(conn)
        # In dry-run, override with detected counts since nothing was written
        if dry_run:
            report["cold_count"] = len(cold_candidates)
            report["contradiction_count"] = len(contradiction_candidates)
            report["pending_total"] = len(all_candidates)
            report["sample_cold"] = [e["slug"] for e in cold_entries[:5]]

        report["archived_count"] = archived_count

        # Step 6: Send TG via 梧桐 bot (sender != receiver, so Anna can receive the @mention)
        if not dry_run:
            tg_token = os.environ.get("WUTUNG_BOT_TOKEN", "")
            if not tg_token:
                env_path = Path.home() / ".claude-bots" / "shared" / ".env"
                if env_path.exists():
                    for line in env_path.read_text(encoding="utf-8").splitlines():
                        if line.startswith("WUTUNG_BOT_TOKEN="):
                            tg_token = line.split("=", 1)[1].strip().strip('"').strip("'")
                            break
            if tg_token:
                send_tg_report(report, tg_token, _TG_GROUP_CHAT_ID)
            else:
                logger.warning("run_health_check: WUTUNG_BOT_TOKEN not set, skipping TG")
        else:
            logger.info("run_health_check: dry-run, skipping TG send")

        return report

    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MemOcean P4: Stale Knowledge Detection")
    parser.add_argument("--dry-run", action="store_true", help="Detect only, do not write to DB or send TG")
    parser.add_argument("--db", default=str(Path.home() / ".claude-bots" / "memory.db"), help="Path to memory.db")
    parser.add_argument(
        "--archive",
        action="store_true",
        help="Archive pending entries older than 14 days to Ocean/Depth/ and mark status=archived",
    )
    args = parser.parse_args()

    report = run_health_check(Path(args.db), dry_run=args.dry_run, archive=args.archive)
    print(json.dumps(report, ensure_ascii=False, indent=2))

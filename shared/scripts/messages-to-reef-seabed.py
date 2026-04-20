#!/usr/bin/env python3
"""
messages-to-reef-seabed.py — MemOcean Gap 1: daily messages → reef Seabed integration.

Scans yesterday's (or --date) messages, detects entity mentions via entity_registry,
maps each entity to a reef, and writes daily conversation segments to:
  Ocean/Seabed/reef/{current}-{reef}/{date}-{entity_id}.md

Also stores each written file in the MemOcean radar table (group=reef-{entity})
so that memocean_radar_search can surface reef content.

Usage:
  python3 messages-to-reef-seabed.py [--dry-run] [--date YYYY-MM-DD] [--days N] [--db PATH]
"""

import argparse
import hashlib
import json
import logging
import os
import re
import sqlite3
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

logger = logging.getLogger("messages_to_reef_seabed")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

DB_PATH = Path(os.path.expanduser("~/.claude-bots/memory.db"))
OCEAN_VAULT = Path(os.path.expanduser("~/Documents/Obsidian Vault/Ocean"))
LOG_DIR = Path(os.path.expanduser("~/.claude-bots/logs/messages-to-seabed"))
MAP_YML = Path(os.path.dirname(os.path.abspath(__file__))) / "entity-reef-map.yml"

# Minimum surface alias length to match (avoid noise from 1-2 char tokens)
MIN_SURFACE_LEN = 3


# ── Load config ───────────────────────────────────────────────────────────────

def load_map(map_path: Path) -> dict:
    if not map_path.exists():
        logger.warning("entity-reef-map.yml not found at %s, using empty map", map_path)
        return {}
    with open(map_path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def build_entity_reef_index(conn: sqlite3.Connection, cfg: dict) -> dict:
    """Build {surface_lower: {entity_id, canonical, category, current, reef}} from entity_registry.
    Skip entities in cfg['skip_entities']. Skip entities where reef resolves to None."""
    skip = set(cfg.get("skip_entities", []))
    people_map = cfg.get("people", {})
    brands_map = cfg.get("brands", {})
    projects_map = cfg.get("projects", {})
    cat_defaults = cfg.get("category_defaults", {})

    def resolve_reef(entity_id: str, category: str) -> tuple[str, str] | None:
        if entity_id in skip:
            return None
        cat_map = {"people": people_map, "brands": brands_map, "projects": projects_map}.get(category, {})
        if entity_id in cat_map:
            mapping = cat_map[entity_id]
            if mapping is None:
                return None
            return mapping["current"], mapping["reef"]
        default = cat_defaults.get(category)
        if default is None:
            return None
        return default["current"], default["reef"]

    rows = conn.execute(
        "SELECT entity_id, canonical, category, surface FROM entity_registry"
    ).fetchall()

    index: dict = {}
    for entity_id, canonical, category, surface in rows:
        if not surface or len(surface) < MIN_SURFACE_LEN:
            continue
        resolved = resolve_reef(entity_id, category)
        if resolved is None:
            continue
        current, reef = resolved
        key = surface.lower()
        if key not in index:
            index[key] = {
                "entity_id": entity_id,
                "canonical": canonical,
                "category": category,
                "current": current,
                "reef": reef,
            }
    logger.info("build_entity_reef_index: %d surface aliases loaded", len(index))
    return index


# ── Fetch messages ─────────────────────────────────────────────────────────────

def fetch_messages(conn: sqlite3.Connection, date_str: str) -> list[dict]:
    """Fetch messages for a calendar day (UTC+8). date_str = YYYY-MM-DD."""
    # UTC+8 midnight = prev day 16:00 UTC
    d = datetime.strptime(date_str, "%Y-%m-%d")
    start_utc = (d - timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    end_utc = (d + timedelta(days=1) - timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ")

    rows = conn.execute(
        """
        SELECT bot_name, chat_id, user, ts, message_id, text
        FROM messages
        WHERE ts >= ? AND ts < ?
          AND text IS NOT NULL AND text != ''
        ORDER BY ts ASC
        """,
        (start_utc, end_utc),
    ).fetchall()
    return [
        {"bot": r[0], "chat_id": r[1], "user": r[2], "ts": r[3],
         "message_id": r[4], "text": r[5]}
        for r in rows
    ]


# ── Entity detection ──────────────────────────────────────────────────────────

def detect_entities(text: str, index: dict) -> list[dict]:
    """Return list of matched entities in text. Each match: {entity_id, canonical, current, reef}."""
    text_lower = text.lower()
    seen_ids: set = set()
    matches = []
    for surface, info in index.items():
        eid = info["entity_id"]
        if eid in seen_ids:
            continue
        # Word-boundary-aware search: allow CJK characters without word boundary
        if re.search(re.escape(surface), text_lower):
            seen_ids.add(eid)
            matches.append(info)
    return matches


# ── Radar storage ──────────────────────────────────────────────────────────────

def _store_reef_radar(db_path: Path, entity: str, slug: str, content: str, drawer_path: str) -> None:
    """Upsert reef file content into MemOcean radar + radar_fts tables."""
    source_hash = hashlib.sha256(content.encode()).hexdigest()
    tokens = len(content) // 4
    try:
        conn = sqlite3.connect(str(db_path))
        conn.execute(
            "INSERT OR REPLACE INTO radar (slug, clsc, tokens, drawer_path, source_hash) VALUES (?,?,?,?,?)",
            (slug, content, tokens, drawer_path, source_hash),
        )
        conn.execute("DELETE FROM radar_fts WHERE slug = ?", (slug,))
        conn.execute("INSERT INTO radar_fts (slug, clsc) VALUES (?,?)", (slug, content))
        conn.commit()
        conn.close()
        logger.debug("radar upsert: %s (group=reef-%s)", slug, entity)
    except Exception as e:
        logger.warning("radar store failed for %s: %s", slug, e)


# ── Write Seabed ──────────────────────────────────────────────────────────────

def seabed_path(date_str: str, current: str, reef: str, entity_id: str) -> Path:
    # Phase 1.5: unified Seabed/reef/{current}-{reef}/ namespace
    # Qualified name avoids collisions when same reef name appears in multiple Currents.
    entity = f"{current}-{reef}".lower().replace(" ", "-")
    return OCEAN_VAULT / "Seabed" / "reef" / entity / f"{date_str}-{entity_id}.md"


def format_ts_local(ts_utc: str) -> str:
    """Convert ISO UTC ts to HH:MM (UTC+8)."""
    try:
        dt = datetime.strptime(ts_utc, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
    except ValueError:
        try:
            dt = datetime.strptime(ts_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            return ts_utc[:16]
    local = dt + timedelta(hours=8)
    return local.strftime("%H:%M")


def write_seabed_file(path: Path, date_str: str, current: str, reef: str,
                      canonical: str, entity_id: str, messages: list[dict],
                      dry_run: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header_written = path.exists()

    # Format new lines
    new_lines = []
    for msg in messages:
        t = format_ts_local(msg["ts"])
        user = msg.get("user") or msg.get("bot") or "?"
        text = msg["text"].replace("\n", " ").strip()
        new_lines.append(f"- {t} [{user}] {text}")

    if not new_lines:
        return

    if dry_run:
        logger.info("[dry-run] would write %d lines to %s", len(new_lines), path)
        return

    if not header_written:
        frontmatter = (
            f"---\n"
            f"type: seabed\n"
            f"current: {current}\n"
            f"reef: {reef}\n"
            f"entity: {canonical}\n"
            f"entity_id: {entity_id}\n"
            f"date: {date_str}\n"
            f"source: telegram-messages\n"
            f"---\n\n"
            f"## {date_str} — {canonical}\n\n"
        )
        content = frontmatter + "\n".join(new_lines) + "\n"
    else:
        content = "\n".join(new_lines) + "\n"

    # Atomic write (same dir, rename)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=".tmp_")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            if header_written:
                existing = path.read_text(encoding="utf-8")
                # Dedup: skip lines whose message text already appears
                existing_lines = set(existing.splitlines())
                new_lines = [l for l in new_lines if l not in existing_lines]
                if not new_lines:
                    os.unlink(tmp_path)
                    return
                f.write(existing.rstrip("\n") + "\n" + "\n".join(new_lines) + "\n")
            else:
                f.write(content)
        os.replace(tmp_path, path)
        logger.info("wrote %d lines → %s", len(new_lines), path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ── Main ──────────────────────────────────────────────────────────────────────

def run(date_str: str, db_path: Path, dry_run: bool) -> dict:
    cfg = load_map(MAP_YML)
    conn = sqlite3.connect(str(db_path))

    try:
        index = build_entity_reef_index(conn, cfg)
        messages = fetch_messages(conn, date_str)
        logger.info("fetched %d messages for %s", len(messages), date_str)

        # Group messages by (current, reef, entity_id)
        groups: dict[tuple, list] = defaultdict(list)
        entity_meta: dict[tuple, dict] = {}

        for msg in messages:
            text = msg.get("text") or ""
            if len(text) < 5:
                continue
            matches = detect_entities(text, index)
            for info in matches:
                key = (info["current"], info["reef"], info["entity_id"])
                groups[key].append(msg)
                if key not in entity_meta:
                    entity_meta[key] = info

        logger.info("grouped into %d entity-reef buckets", len(groups))

        # Write each bucket + store in radar
        written = []
        for key, msgs in groups.items():
            current, reef, entity_id = key
            info = entity_meta[key]
            path = seabed_path(date_str, current, reef, entity_id)
            write_seabed_file(path, date_str, current, reef,
                              info["canonical"], entity_id, msgs, dry_run)
            if not dry_run and path.exists():
                entity_key = f"{current}-{reef}".lower().replace(" ", "-")
                slug = f"reef:{entity_key}-{date_str}"
                radar_content = path.read_text(encoding="utf-8")
                _store_reef_radar(db_path, entity_key, slug, radar_content, str(path))
            written.append({
                "current": current,
                "reef": reef,
                "entity_id": entity_id,
                "messages": len(msgs),
                "path": str(path),
            })

        report = {
            "date": date_str,
            "messages_total": len(messages),
            "buckets": len(groups),
            "files_written": len(written),
            "dry_run": dry_run,
            "files": written,
        }

        # Write log
        if not dry_run:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            log_path = LOG_DIR / f"{date_str}.json"
            log_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

        return report

    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MemOcean Gap 1: messages → reef Seabed")
    parser.add_argument("--date", default=None,
                        help="Target date YYYY-MM-DD (default: yesterday UTC+8)")
    parser.add_argument("--days", type=int, default=1,
                        help="Process N days back from --date (default: 1)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Detect only, do not write files")
    parser.add_argument("--db", default=str(DB_PATH),
                        help="Path to memory.db")
    args = parser.parse_args()

    if args.date:
        base_date = datetime.strptime(args.date, "%Y-%m-%d")
    else:
        # Default: yesterday (UTC+8)
        base_date = datetime.now(timezone.utc) + timedelta(hours=8) - timedelta(days=1)
        base_date = base_date.replace(hour=0, minute=0, second=0, microsecond=0)

    for i in range(args.days):
        target = (base_date - timedelta(days=i)).strftime("%Y-%m-%d")
        report = run(target, Path(args.db), dry_run=args.dry_run)
        print(json.dumps(report, ensure_ascii=False, indent=2))

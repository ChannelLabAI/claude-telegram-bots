#!/usr/bin/env python3
"""
dream_cycle.py — Dream Cycle Phase 1 nightly batch pipeline.

Steps:
  1. Collect messages from memory.db (past 24h)
  2. Entity extraction via Haiku NER (batch, max 50 blocks)
  2.5. Entity normalization via alias table
  3. KG diff (check existing triples, detect duplicates/conflicts)
  4. Write to KG + Closet (live mode only)
  5. Reference stitching (wikilinks between related Closet entries)
  6. Generate report JSON + TG notification

Usage:
  python3 dream_cycle.py --mode=dry-run   (default, no writes)
  python3 dream_cycle.py --mode=live      (writes to DB)
"""

import argparse
import fcntl
import hashlib
import json
import logging
import os
import re
import signal
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ── Path setup ──────────────────────────────────────────────────────────────
SHARED_DIR = Path.home() / ".claude-bots" / "shared"
sys.path.insert(0, str(SHARED_DIR / "clsc" / "v0.7"))
sys.path.insert(0, str(SHARED_DIR / "kg"))
sys.path.insert(0, str(SHARED_DIR / "memocean-mcp" / "memocean_mcp" / "tools"))

# ── Constants ────────────────────────────────────────────────────────────────
MEMORY_DB = Path.home() / ".claude-bots" / "memory.db"
LOCK_FILE = Path("/tmp/dream-cycle.lock")
LOG_DIR = Path.home() / ".claude-bots" / "logs" / "dream-cycle"
ALIAS_TABLE_PATH = SHARED_DIR / "config" / "alias_table.yaml"
TIMEOUT_SECONDS = 1800  # 30 minutes
HAIKU_MODEL = "claude-haiku-4-5-20251001"
TG_CHAT_ID = 1050312492  # 老兔's private chat

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("dream_cycle")

# ── Optional imports ─────────────────────────────────────────────────────────
try:
    import anthropic as _anthropic_module
    ANTHROPIC_AVAILABLE = True
except ImportError:
    ANTHROPIC_AVAILABLE = False
    logger.warning("anthropic package not available — LLM steps will be skipped")

try:
    import yaml as _yaml_module
    YAML_AVAILABLE = True
except ImportError:
    YAML_AVAILABLE = False
    logger.warning("PyYAML not available — using fallback YAML parser")


# ── Minimal YAML fallback ────────────────────────────────────────────────────

def _parse_alias_yaml_fallback(text: str) -> dict:
    """
    Minimal YAML parser for the alias_table.yaml format.
    Only handles the specific structure we need.
    """
    result = {"entities": []}
    current_entity = None
    in_entities = False

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if stripped == "entities:":
            in_entities = True
            continue

        if in_entities:
            if stripped.startswith("- canonical:"):
                if current_entity:
                    result["entities"].append(current_entity)
                canonical = stripped[len("- canonical:"):].strip()
                current_entity = {"canonical": canonical, "aliases": [], "type": "unknown"}
            elif stripped.startswith("canonical:"):
                if current_entity:
                    result["entities"].append(current_entity)
                canonical = stripped[len("canonical:"):].strip()
                current_entity = {"canonical": canonical, "aliases": [], "type": "unknown"}
            elif stripped.startswith("aliases:") and current_entity is not None:
                # Parse inline list: [a, b, c]
                val = stripped[len("aliases:"):].strip()
                if val.startswith("[") and val.endswith("]"):
                    items = val[1:-1].split(",")
                    current_entity["aliases"] = [i.strip() for i in items]
            elif stripped.startswith("type:") and current_entity is not None:
                current_entity["type"] = stripped[len("type:"):].strip()

    if current_entity:
        result["entities"].append(current_entity)

    return result


# ── Schema migration ─────────────────────────────────────────────────────────

def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create dream_cycle tables if they don't exist."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS dream_cycle_runs (
            run_id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            mode TEXT NOT NULL,
            content_hash TEXT,
            status TEXT DEFAULT 'running_step1',
            report_json TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS dream_cycle_changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            change_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            before_value TEXT,
            after_value TEXT,
            confidence REAL,
            source_block TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (run_id) REFERENCES dream_cycle_runs(run_id)
        );

        CREATE INDEX IF NOT EXISTS idx_dc_changes_run ON dream_cycle_changes(run_id);
        CREATE INDEX IF NOT EXISTS idx_dc_changes_target ON dream_cycle_changes(target_id);
    """)
    conn.commit()


# ── Alias table loading ───────────────────────────────────────────────────────

def load_alias_table(path: Path = ALIAS_TABLE_PATH) -> dict:
    """
    Load alias table from YAML file.
    Returns dict mapping lowercase alias → canonical name.
    Also returns entity type info.
    """
    if not path.exists():
        logger.warning("Alias table not found at %s", path)
        return {}

    text = path.read_text(encoding="utf-8")

    if YAML_AVAILABLE:
        data = _yaml_module.safe_load(text)
    else:
        data = _parse_alias_yaml_fallback(text)

    alias_map = {}  # lowercase alias → canonical
    for entry in data.get("entities", []):
        canonical = entry.get("canonical", "")
        if not canonical:
            continue
        # canonical maps to itself (lowercase)
        alias_map[canonical.lower()] = canonical
        for alias in entry.get("aliases", []):
            alias_map[alias.lower()] = canonical

    return alias_map


def load_alias_table_full(path: Path = ALIAS_TABLE_PATH) -> list:
    """Load full entity list with type info."""
    if not path.exists():
        return []

    text = path.read_text(encoding="utf-8")
    if YAML_AVAILABLE:
        data = _yaml_module.safe_load(text)
    else:
        data = _parse_alias_yaml_fallback(text)

    return data.get("entities", [])


# ── Entity normalization ──────────────────────────────────────────────────────

def normalize_entity(name: str, alias_map: dict) -> str:
    """Normalize a single entity name to its canonical form."""
    return alias_map.get(name.lower(), name)


def normalize_entities(entities: list, alias_map: dict) -> list:
    """
    Normalize a list of entity names, merging aliases to canonical names.
    Returns deduplicated list of canonical names.
    """
    seen = set()
    result = []
    for e in entities:
        canonical = normalize_entity(e, alias_map)
        if canonical not in seen:
            seen.add(canonical)
            result.append(canonical)
    return result


def normalize_triples(triples: list, alias_map: dict) -> list:
    """
    Normalize subject and object in each triple using the alias map.
    Returns list of (subject, predicate, object, confidence) tuples.
    """
    normalized = []
    seen = set()
    for triple in triples:
        if len(triple) < 3:
            continue
        subj = normalize_entity(str(triple[0]), alias_map)
        pred = str(triple[1])
        obj = normalize_entity(str(triple[2]), alias_map)
        conf = triple[3] if len(triple) > 3 else 0.8

        key = (subj.lower(), pred.lower(), obj.lower())
        if key not in seen:
            seen.add(key)
            normalized.append((subj, pred, obj, conf))
    return normalized


# ── Crash recovery ────────────────────────────────────────────────────────────

def check_incomplete_run(conn: sqlite3.Connection) -> dict | None:
    """Check for any runs that didn't complete. Returns latest incomplete run or None."""
    try:
        row = conn.execute(
            "SELECT run_id, started_at, status FROM dream_cycle_runs "
            "WHERE finished_at IS NULL ORDER BY started_at DESC LIMIT 1"
        ).fetchone()
        if row:
            return {"run_id": row[0], "started_at": row[1], "status": row[2]}
        return None
    except sqlite3.OperationalError:
        return None


# ── Lock file management ──────────────────────────────────────────────────────

class LockFile:
    """Context manager for dream cycle lock file."""

    def __init__(self, path: Path = LOCK_FILE):
        self.path = path
        self._fp = None

    def __enter__(self):
        self._fp = open(self.path, "w")
        try:
            fcntl.flock(self._fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._fp.close()
            raise RuntimeError(
                f"Dream Cycle is already running (lock file: {self.path})"
            )
        self._fp.write(str(os.getpid()))
        self._fp.flush()
        return self

    def __exit__(self, *args):
        if self._fp:
            fcntl.flock(self._fp, fcntl.LOCK_UN)
            self._fp.close()
        if self.path.exists():
            self.path.unlink()


# ── Step 1: Collect messages ──────────────────────────────────────────────────

def collect_messages(conn: sqlite3.Connection) -> list:
    """
    Collect messages from memory.db sent in the past 24 hours.
    Returns list of message dicts.
    """
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
    try:
        # Detect available columns (schema varies across environments)
        col_info = conn.execute("PRAGMA table_info(messages)").fetchall()
        col_names = {row[1] for row in col_info}
        user_col = "user" if "user" in col_names else ("from_id" if "from_id" in col_names else None)
        bot_col = "bot_name" if "bot_name" in col_names else None
        select_user = f", {user_col}" if user_col else ""
        select_bot = f", {bot_col}" if bot_col else ""

        rows = conn.execute(
            f"SELECT rowid, text, ts, chat_id{select_user}{select_bot} "
            "FROM messages "
            "WHERE ts >= ? "
            "ORDER BY ts ASC",
            (cutoff,),
        ).fetchall()
        messages = []
        col_offset = 4  # after rowid, text, ts, chat_id
        for row in rows:
            row = tuple(row)
            msg = {
                "id": row[0],
                "text": row[1] or "",
                "ts": row[2],
                "chat_id": row[3],
                "from_id": None,
                "bot_name": None,
            }
            idx = col_offset
            if user_col:
                msg["from_id"] = row[idx] if len(row) > idx else None
                idx += 1
            if bot_col:
                msg["bot_name"] = row[idx] if len(row) > idx else None
                idx += 1
            messages.append(msg)
        logger.info("Step 1: collected %d messages (past 24h)", len(messages))
        return messages
    except sqlite3.OperationalError as e:
        logger.warning("Step 1: DB error collecting messages: %s", e)
        return []


def group_into_blocks(messages: list) -> list:
    """Group messages by chat_id, filter bot commands."""
    from collections import defaultdict
    by_chat: dict = defaultdict(list)
    for msg in messages:
        text = msg.get("text", "") or ""
        # Filter out bot commands (short /command messages)
        if text.startswith("/") and len(text) < 50:
            continue
        chat_id = msg.get("chat_id", "unknown")
        by_chat[chat_id].append(msg)

    blocks = []
    for chat_id, msgs in by_chat.items():
        if msgs:
            # Combine messages into a conversation block (max 3000 chars)
            text = "\n".join(
                f"[{m.get('bot_name','?')}] {m.get('text','')}" for m in msgs
            )
            blocks.append({
                "chat_id": chat_id,
                "text": text[:3000],
                "msg_count": len(msgs),
                "ts_start": msgs[0].get("ts", ""),
                "ts_end": msgs[-1].get("ts", ""),
            })
    return blocks[:50]  # Cap at 50 blocks


def step1_collect_messages(conn: sqlite3.Connection) -> list:
    """
    Collect messages from memory.db sent in the past 24 hours.
    Returns list of message dicts.
    """
    return collect_messages(conn)


# ── Step 2: Entity extraction via Haiku ───────────────────────────────────────

NER_PROMPT_TEMPLATE = """Extract entities and relationships from the following Telegram messages.
For each relationship, output a JSON array of triples: [subject, predicate, object, confidence(0-1)].
Focus on: people, organizations, projects, tools, roles, and actions.
Only extract clear, factual relationships. Skip opinions and noise.

Messages:
{text}

Output ONLY a JSON array of triples, no explanation. Example:
[["OldRabbit", "is_ceo_of", "ChannelLab", 0.95], ["Anna", "works_on", "MemOcean", 0.8]]

If no clear relationships found, output: []"""


def _batch_messages(messages: list, max_chars: int = 3000) -> list:
    """Split messages into batches by character count."""
    batches = []
    current_batch = []
    current_len = 0

    for msg in messages:
        text = msg.get("text", "")
        if not text.strip():
            continue
        msg_len = len(text)
        if current_batch and current_len + msg_len > max_chars:
            batches.append(current_batch)
            current_batch = [msg]
            current_len = msg_len
        else:
            current_batch.append(msg)
            current_len += msg_len

    if current_batch:
        batches.append(current_batch)

    return batches


def step2_extract_entities(messages: list, max_batches: int = 50) -> list:
    """
    Extract entity triples from messages using Haiku NER.
    Returns list of (subject, predicate, object, confidence) tuples.
    Gracefully degrades if ANTHROPIC_API_KEY not set or anthropic not installed.
    """
    if not ANTHROPIC_AVAILABLE:
        logger.info("Step 2: skipping NER (anthropic not available)")
        return []

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        logger.info("Step 2: skipping NER (ANTHROPIC_API_KEY not set)")
        return []

    client = _anthropic_module.Anthropic(api_key=api_key)
    batches = _batch_messages(messages)[:max_batches]

    if not batches:
        logger.info("Step 2: no message content to extract from")
        return []

    all_triples = []
    for i, batch in enumerate(batches):
        combined_text = "\n".join(
            f"[{msg.get('ts', '')}] {msg.get('text', '')}"
            for msg in batch
        )
        prompt = NER_PROMPT_TEMPLATE.format(text=combined_text)

        try:
            msg = client.messages.create(
                model=HAIKU_MODEL,
                max_tokens=500,
                messages=[{"role": "user", "content": prompt}],
            )
            result_text = msg.content[0].text.strip()
            # Strip markdown code fences (Haiku sometimes wraps JSON in ```json ... ```)
            result_text = re.sub(r'^```(?:json)?\s*|\s*```$', '', result_text, flags=re.DOTALL)

            # Parse JSON triples
            triples = json.loads(result_text)
            if isinstance(triples, list):
                for t in triples:
                    if isinstance(t, list) and len(t) >= 3:
                        conf = float(t[3]) if len(t) > 3 else 0.8
                        all_triples.append((str(t[0]), str(t[1]), str(t[2]), conf))

        except json.JSONDecodeError:
            logger.warning("Step 2: batch %d returned non-JSON: %s", i, result_text[:100])
        except Exception as e:
            logger.warning("Step 2: batch %d error: %s", i, e)

    logger.info("Step 2: extracted %d raw triples from %d batches", len(all_triples), len(batches))
    return all_triples


# ── Step 2.5: Normalize entities ──────────────────────────────────────────────

def step25_normalize(triples: list, alias_map: dict) -> list:
    """Normalize entity names in triples using alias table."""
    normalized = normalize_triples(triples, alias_map)
    logger.info("Step 2.5: normalized %d → %d unique triples", len(triples), len(normalized))
    return normalized


# ── Step 3: KG diff ───────────────────────────────────────────────────────────

def step3_kg_diff(triples: list) -> dict:
    """
    Check normalized triples against existing KG.
    Returns dict with 'new', 'duplicate', 'conflict' lists.
    """
    result = {"new": [], "duplicate": [], "conflict": []}

    try:
        from kg_helper import kg_query
    except ImportError:
        logger.warning("Step 3: kg_helper not available, treating all as new")
        result["new"] = triples
        return result

    for subj, pred, obj, conf in triples:
        existing = kg_query(subj)
        existing_for_pred = [
            f for f in existing if f.get("predicate") == pred
        ]

        if not existing_for_pred:
            result["new"].append((subj, pred, obj, conf))
        elif any(f.get("object") == obj for f in existing_for_pred):
            result["duplicate"].append((subj, pred, obj, conf))
        else:
            # Different object for same subject+predicate → possible conflict
            result["conflict"].append({
                "new": (subj, pred, obj, conf),
                "existing": existing_for_pred,
            })

    logger.info(
        "Step 3: KG diff — new=%d, duplicate=%d, conflict=%d",
        len(result["new"]), len(result["duplicate"]), len(result["conflict"]),
    )
    return result


def diff_closet(entities: list, blocks: list, closet_search_fn=None) -> list:
    """For each extracted entity, check if Closet has an entry and if update is needed."""
    if closet_search_fn is None:
        try:
            from closet_search import closet_search as _cs
            closet_search_fn = _cs
        except ImportError:
            logger.warning("diff_closet: closet_search not available, skipping closet diff")
            return []

    closet_changes = []
    for entity in entities:
        name = entity.get("name", "") if isinstance(entity, dict) else str(entity)
        if not name:
            continue
        try:
            existing = closet_search_fn(name, limit=1)
        except Exception:
            existing = []

        if existing:
            existing_clsc = existing[0].get("clsc", "")
            existing_slug = existing[0].get("slug", "")
            # Find new context from blocks mentioning this entity
            new_context = " ".join(
                b["text"] for b in blocks if name.lower() in b["text"].lower()
            )[:500]
            if new_context and new_context not in existing_clsc:
                closet_changes.append({
                    "type": "update",
                    "slug": existing_slug,
                    "patch": f"[{entity.get('type','?') if isinstance(entity, dict) else '?'}:{name}]",
                    "entity": name,
                })
        else:
            # New entity — create a stub Closet entry
            entity_type = entity.get("type", "concept") if isinstance(entity, dict) else "concept"
            closet_changes.append({
                "type": "create",
                "slug": name.lower().replace(" ", "-"),
                "entity": name,
                "type_str": entity_type,
                "skeleton": f"[{entity_type}:{name}|src:dream-cycle]",
            })
    return closet_changes


# ── Step 4: Write to KG + Closet ─────────────────────────────────────────────

def step4_write_kg(diff: dict, run_id: str, conn: sqlite3.Connection, mode: str) -> int:
    """
    Write new triples to KG (live mode only).
    Returns count of written triples.
    """
    if mode == "dry-run":
        logger.info("Step 4: dry-run — skipping KG writes (%d new triples)", len(diff["new"]))
        return 0

    try:
        from kg_helper import kg_add
    except ImportError:
        logger.warning("Step 4: kg_helper not available, skipping KG write")
        return 0

    written = 0
    for subj, pred, obj, conf in diff["new"]:
        try:
            kg_add(subj, pred, obj, source="dream-cycle", confidence=conf)
            # Record change
            conn.execute(
                "INSERT INTO dream_cycle_changes "
                "(run_id, change_type, target_id, after_value, confidence) "
                "VALUES (?, 'kg_triple_added', ?, ?, ?)",
                (run_id, f"{subj}|{pred}|{obj}", json.dumps([subj, pred, obj]), conf),
            )
            written += 1
        except Exception as e:
            logger.warning("Step 4: failed to write triple %s|%s|%s: %s", subj, pred, obj, e)

    conn.commit()
    logger.info("Step 4: wrote %d new triples to KG", written)
    return written


def step4_refresh_closet(diff: dict, alias_entities: list, blocks: list, mode: str) -> int:
    """
    Refresh Closet skeletons for entities involved in new triples (live mode only).
    Also applies closet_changes from diff_closet.
    Returns count of refreshed entries.
    """
    # Build entity list from triples for closet diff
    entity_names: set = set()
    for subj, pred, obj, conf in diff.get("new", []):
        entity_names.add(subj)
        entity_names.add(obj)

    # Build entity dicts for diff_closet
    entity_dicts = [{"name": n, "type": "concept"} for n in entity_names]

    # Compute closet changes (dry-run: count but don't write)
    closet_changes = diff_closet(entity_dicts, blocks)

    if mode == "dry-run":
        logger.info(
            "Step 4: dry-run — skipping Closet refresh (%d changes pending)", len(closet_changes)
        )
        return len(closet_changes)  # report count for dry-run visibility

    try:
        from closet import store_skeleton
    except ImportError:
        logger.warning("Step 4: closet import not available, skipping Closet refresh")
        return 0

    try:
        from kg_helper import kg_query
        kg_query_available = True
    except ImportError:
        kg_query_available = False

    refreshed = 0

    # Apply closet_changes
    for change in closet_changes:
        try:
            if change["type"] == "create":
                group = change.get("type_str", "general")
                store_skeleton(group, change["slug"], change["skeleton"])
                refreshed += 1
            elif change["type"] == "update":
                try:
                    from closet_search import closet_search as _cs
                    existing = _cs(change["slug"], limit=1)
                except ImportError:
                    existing = []
                if existing:
                    updated = existing[0]["clsc"] + " | " + change["patch"]
                    store_skeleton("general", change["slug"], updated)
                    refreshed += 1
        except Exception as e:
            logger.warning("Step 4: failed to apply closet change %s: %s", change.get("slug"), e)

    # Also refresh from KG facts for entities with new triples
    if kg_query_available:
        for entity in entity_names:
            try:
                from kg_helper import kg_query
                facts = kg_query(entity)
                if not facts:
                    continue

                # Build a simple CLSC skeleton from facts
                lines = [f"[{entity}|KG facts as of dream-cycle]"]
                for fact in facts[:10]:  # limit to 10 facts per entity
                    f_pred = fact.get("predicate", "")
                    f_obj = fact.get("object", "")
                    f_conf = fact.get("confidence", 1.0)
                    lines.append(f"  {f_pred}: {f_obj} (conf={f_conf:.2f})")

                skeleton = "\n".join(lines)
                group = "dream-cycle"
                slug = entity.replace(" ", "-").lower()
                store_skeleton(group, slug, skeleton)
                refreshed += 1
            except Exception as e:
                logger.warning("Step 4: failed to refresh closet for %s: %s", entity, e)

    logger.info("Step 4: refreshed %d Closet entries", refreshed)
    return refreshed


# ── Step 5: Reference stitching ───────────────────────────────────────────────

def step5_stitch_references(diff: dict, mode: str) -> int:
    """
    Add wikilinks between related Closet entries for entities in the same triple.
    Returns count of stitched links.
    """
    if mode == "dry-run":
        logger.info("Step 5: dry-run — skipping reference stitching")
        return 0

    stitched = 0
    try:
        from closet import read_closet, store_skeleton
    except ImportError:
        logger.warning("Step 5: closet imports not available, skipping stitching")
        return 0

    # For each new triple, add cross-references in both entity's skeletons
    for subj, pred, obj, conf in diff["new"]:
        subj_slug = subj.replace(" ", "-").lower()
        obj_slug = obj.replace(" ", "-").lower()
        group = "dream-cycle"

        try:
            # Add reference from subject → object
            existing = read_closet(group)
            if f"[[{obj}]]" not in existing:
                ref_line = f"[{subj_slug}|xref: [[{obj}]] via {pred}]"
                store_skeleton(group, f"{subj_slug}-xref-{obj_slug}", ref_line)
                stitched += 1
        except Exception as e:
            logger.warning("Step 5: stitching failed for %s→%s: %s", subj, obj, e)

    logger.info("Step 5: stitched %d cross-references", stitched)
    return stitched


def _load_tg_token() -> str:
    """Load TG bot token from env or .env file."""
    tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not tg_token:
        env_path = SHARED_DIR / ".env"
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                if line.startswith("TELEGRAM_BOT_TOKEN="):
                    tg_token = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break
    return tg_token


def send_tg_notification(text: str, tg_token: str, chat_id: int) -> None:
    """Send a plain text message to a Telegram chat."""
    if not tg_token:
        logger.warning("send_tg_notification: no token, skipping")
        return
    try:
        import urllib.request
        import urllib.parse
        url = f"https://api.telegram.org/bot{tg_token}/sendMessage"
        data = urllib.parse.urlencode({
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
        }).encode("utf-8")
        req = urllib.request.Request(url, data=data)
        urllib.request.urlopen(req, timeout=10)
        logger.info("TG notification sent")
    except Exception as e:
        logger.warning("TG notification failed: %s", e)


def step6_send_tg_report(report: dict) -> None:
    """Send report summary to 老兔's Telegram chat."""
    tg_token = _load_tg_token()
    if not tg_token:
        logger.warning("Step 6: TELEGRAM_BOT_TOKEN not set, skipping TG notification")
        return

    s = report["summary"]
    mode_tag = "DRY-RUN" if report["mode"] == "dry-run" else "LIVE"
    content_hash_line = ""
    if report.get("content_hash"):
        content_hash_line = f"\nhash: {report['content_hash'][:12]}..."
    text = (
        f"Dream Cycle complete — {mode_tag}\n"
        f"Messages scanned: {s['messages_scanned']}\n"
        f"Triples extracted: {s['triples_extracted_raw']} -> normalized: {s['triples_after_normalization']}\n"
        f"New KG facts: {s['triples_new']} written: {s['kg_written']}\n"
        f"Duplicates: {s['triples_duplicate']} | Conflicts: {s['triples_conflict']}\n"
        f"Closet refreshed: {s['closet_refreshed']} | Stitched: {s['references_stitched']}"
        f"{content_hash_line}\n"
        f"{report['started_at'][:19]} -> {report['finished_at'][:19]}"
    )
    send_tg_notification(text, tg_token, TG_CHAT_ID)


# ── Timeout handler ───────────────────────────────────────────────────────────

def _timeout_handler(signum, frame):
    logger.error("Dream Cycle exceeded 30-minute timeout — aborting")
    sys.exit(2)


# ── Update run status helper ──────────────────────────────────────────────────

def update_run_status(run_id: str, status: str, conn: sqlite3.Connection) -> None:
    conn.execute(
        "UPDATE dream_cycle_runs SET status=? WHERE run_id=?",
        (status, run_id),
    )
    conn.commit()


# keep old name as alias for compatibility
def _update_run_status(conn: sqlite3.Connection, run_id: str, status: str) -> None:
    update_run_status(run_id, status, conn)


# ── Crash recovery: resume from step ─────────────────────────────────────────

def resume_from_step(run_id: str, last_step_str: str, conn: sqlite3.Connection, mode: str, limit: int = 50) -> int:
    """Resume an incomplete run from the last checkpoint step."""
    try:
        step_num = int(last_step_str.replace("running_step", "").replace(".", ""))
    except Exception:
        step_num = 1

    logger.info("Resuming run %s from step %s (parsed=%d)", run_id, last_step_str, step_num)
    # Step 1 is idempotent — always safe to re-collect
    messages = collect_messages(conn)
    blocks = group_into_blocks(messages)
    return _run_steps(run_id, messages, blocks, conn, mode, start_from_step=step_num)


# ── Main pipeline steps ───────────────────────────────────────────────────────

def _run_steps(
    run_id: str,
    messages: list,
    blocks: list,
    conn: sqlite3.Connection,
    mode: str,
    start_from_step: int = 1,
) -> int:
    """
    Execute pipeline steps, optionally skipping steps before start_from_step.
    Returns 0 on success, 1 on failure.
    """
    # step tracking helpers
    def should_run(step: int) -> bool:
        return step >= start_from_step

    tg_token = _load_tg_token()

    try:
        # ── Step 2 ──────────────────────────────────────────────────────────
        if should_run(2):
            triples_raw = step2_extract_entities(messages)
            update_run_status(run_id, "running_step25", conn)
        else:
            logger.info("Skipping step 2 (already done)")
            triples_raw = []

        triples_raw_count = len(triples_raw)

        # ── Step 2.5 ─────────────────────────────────────────────────────────
        if should_run(2):
            alias_map = load_alias_table()
            triples_normalized = step25_normalize(triples_raw, alias_map)
            update_run_status(run_id, "running_step3", conn)
        else:
            logger.info("Skipping step 2.5 (already done)")
            triples_normalized = []

        # ── Step 3 ──────────────────────────────────────────────────────────
        if should_run(3):
            diff = step3_kg_diff(triples_normalized)
            update_run_status(run_id, "running_step4", conn)
        else:
            logger.info("Skipping step 3 (already done)")
            diff = {"new": [], "duplicate": [], "conflict": []}

        # ── Step 4 ──────────────────────────────────────────────────────────
        if should_run(4):
            alias_entities = load_alias_table_full()
            kg_written = step4_write_kg(diff, run_id, conn, mode)
            closet_refreshed = step4_refresh_closet(diff, alias_entities, blocks, mode)
            update_run_status(run_id, "running_step5", conn)
        else:
            logger.info("Skipping step 4 (already done)")
            kg_written = 0
            closet_refreshed = 0

        # ── Step 5 ──────────────────────────────────────────────────────────
        if should_run(5):
            stitched = step5_stitch_references(diff, mode)
            update_run_status(run_id, "running_step6", conn)
        else:
            logger.info("Skipping step 5 (already done)")
            stitched = 0

        # ── Step 6 ──────────────────────────────────────────────────────────
        started_at = conn.execute(
            "SELECT started_at FROM dream_cycle_runs WHERE run_id=?", (run_id,)
        ).fetchone()
        started_at_str = started_at[0] if started_at else datetime.now(timezone.utc).isoformat()

        content_hash_row = conn.execute(
            "SELECT content_hash FROM dream_cycle_runs WHERE run_id=?", (run_id,)
        ).fetchone()
        content_hash = content_hash_row[0] if content_hash_row else None

        report = step6_generate_report(
            run_id=run_id,
            mode=mode,
            messages_count=len(messages),
            triples_raw=triples_raw_count,
            triples_normalized=len(triples_normalized),
            diff=diff,
            kg_written=kg_written,
            closet_refreshed=closet_refreshed,
            stitched=stitched,
            started_at=started_at_str,
            content_hash=content_hash,
        )

        # Mark run as finished
        finished_at = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "UPDATE dream_cycle_runs SET finished_at=?, status=?, report_json=? WHERE run_id=?",
            (finished_at, "complete", json.dumps(report), run_id),
        )
        conn.commit()

        step6_send_tg_report(report)
        logger.info("=== Dream Cycle complete | run_id=%s ===", run_id)
        return 0

    except Exception as e:
        logger.exception("Dream Cycle failed")
        try:
            update_run_status(run_id, "failed", conn)
        except Exception:
            pass
        send_tg_notification(
            f"Dream Cycle execution error\nerror: {type(e).__name__}: {str(e)[:100]}\nSee log for details",
            tg_token,
            TG_CHAT_ID,
        )
        raise


# ── Main pipeline ─────────────────────────────────────────────────────────────

def run_pipeline(mode: str) -> int:
    """Run the full Dream Cycle pipeline. Returns exit code."""
    run_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc).isoformat()
    logger.info("=== Dream Cycle starting | run_id=%s mode=%s ===", run_id, mode)

    # Set hard timeout
    signal.signal(signal.SIGALRM, _timeout_handler)
    signal.alarm(TIMEOUT_SECONDS)

    try:
        with LockFile() as _lock:
            return _run_pipeline_locked(run_id, started_at, mode)
    except RuntimeError as e:
        logger.error("Cannot acquire lock: %s", e)
        return 1
    finally:
        signal.alarm(0)  # cancel timeout


def _run_pipeline_locked(run_id: str, started_at: str, mode: str) -> int:
    """Inner pipeline run (lock already held)."""
    if not MEMORY_DB.exists():
        logger.error("memory.db not found at %s", MEMORY_DB)
        return 1

    conn = sqlite3.connect(str(MEMORY_DB))
    conn.row_factory = sqlite3.Row

    try:
        # Schema migration
        ensure_schema(conn)

        # ── Step 1: Collect messages + compute content_hash ──────────────────
        messages = collect_messages(conn)
        blocks = group_into_blocks(messages)

        # Compute content_hash for idempotency (P1-6)
        content_hash = hashlib.sha256(
            json.dumps(sorted([m.get("text", "") for m in messages])).encode()
        ).hexdigest()

        # Check if this content was already processed (idempotency)
        existing = conn.execute(
            "SELECT run_id, status FROM dream_cycle_runs WHERE content_hash = ? AND status = 'complete'",
            (content_hash,),
        ).fetchone()
        if existing:
            logger.info(
                "Content already processed in run %s, skipping (idempotent)", existing[0]
            )
            # Write a skip log
            today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            skip_report = {
                "run_id": run_id,
                "mode": mode,
                "started_at": started_at,
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "status": "skipped",
                "reason": "idempotent",
                "content_hash": content_hash,
                "previous_run_id": existing[0],
            }
            log_path = LOG_DIR / f"{today}.json"
            tmp_path = LOG_DIR / f"{today}.json.tmp"
            tmp_path.write_text(json.dumps(skip_report, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp_path.rename(log_path)
            logger.info("Skipped — report written to %s", log_path)
            return 0

        # Check for incomplete runs → resume instead of starting fresh
        incomplete = check_incomplete_run(conn)
        if incomplete:
            logger.warning(
                "Found incomplete run: %s (started: %s, status: %s) — resuming",
                incomplete["run_id"], incomplete["started_at"], incomplete["status"],
            )
            try:
                return resume_from_step(
                    incomplete["run_id"],
                    incomplete["status"],
                    conn,
                    mode,
                )
            except Exception:
                logger.warning("Resume failed, starting fresh run")

        # Register new run with content_hash
        conn.execute(
            "INSERT INTO dream_cycle_runs (run_id, started_at, mode, status, content_hash) VALUES (?, ?, ?, ?, ?)",
            (run_id, started_at, mode, "running_step2", content_hash),
        )
        conn.commit()

        try:
            return _run_steps(run_id, messages, blocks, conn, mode, start_from_step=2)
        except Exception:
            return 1

    except Exception as e:
        logger.exception("Pipeline setup failed: %s", e)
        return 1
    finally:
        conn.close()


# ── Step 6: Report (updated signature) ───────────────────────────────────────

def step6_generate_report(
    run_id: str,
    mode: str,
    messages_count: int,
    triples_raw: int,
    triples_normalized: int,
    diff: dict,
    kg_written: int,
    closet_refreshed: int,
    stitched: int,
    started_at: str,
    content_hash: str = None,
) -> dict:
    """Generate report JSON and save to logs/dream-cycle/YYYY-MM-DD.json."""
    finished_at = datetime.now(timezone.utc).isoformat()
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    report = {
        "run_id": run_id,
        "mode": mode,
        "started_at": started_at,
        "finished_at": finished_at,
        "content_hash": content_hash,
        "summary": {
            "messages_scanned": messages_count,
            "triples_extracted_raw": triples_raw,
            "triples_after_normalization": triples_normalized,
            "triples_new": len(diff.get("new", [])),
            "triples_duplicate": len(diff.get("duplicate", [])),
            "triples_conflict": len(diff.get("conflict", [])),
            "kg_written": kg_written,
            "closet_refreshed": closet_refreshed,
            "references_stitched": stitched,
        },
        "conflicts": [
            {
                "new": c["new"][:3] if isinstance(c.get("new"), (list, tuple)) else str(c.get("new", "")),
                "existing_count": len(c.get("existing", [])),
            }
            for c in diff.get("conflict", [])[:5]  # top 5 conflicts
        ],
        "status": "complete",
    }

    # Write to log file (atomic: write .tmp then rename)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"{today}.json"
    tmp_path = LOG_DIR / f"{today}.json.tmp"

    tmp_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.rename(log_path)

    logger.info("Step 6: report written to %s", log_path)
    return report


# ── CLI entry point ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Dream Cycle — nightly KG batch pipeline")
    parser.add_argument(
        "--mode",
        choices=["dry-run", "live"],
        default="dry-run",
        help="dry-run: no writes; live: writes to DB (default: dry-run)",
    )
    args = parser.parse_args()

    sys.exit(run_pipeline(args.mode))


if __name__ == "__main__":
    main()

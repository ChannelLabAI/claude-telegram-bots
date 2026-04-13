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
MEMORY_DB_PATH = MEMORY_DB  # alias for phase 2 code
LOCK_FILE = Path("/tmp/dream-cycle.lock")
LOG_DIR = Path.home() / ".claude-bots" / "logs" / "dream-cycle"
ALIAS_TABLE_PATH = SHARED_DIR / "config" / "alias_table.yaml"
TIMEOUT_SECONDS = 1800  # 30 minutes
HAIKU_MODEL = "claude-haiku-4-5-20251001"
TG_CHAT_ID = 0  # OWNER_CHAT_ID — set via env or team.env

# ── Phase 2 constants ─────────────────────────────────────────────────────────
DRAFTS_DIR = Path.home() / "Documents" / "Obsidian Vault" / "Ocean" / "Pearl" / "_drafts"
KG_DB = Path.home() / ".claude-bots" / "kg.db"

# ── FATQ task queue ───────────────────────────────────────────────────────────
TASKS_DIR = Path.home() / ".claude-bots" / "tasks"
PEARL_DIR = Path.home() / "Documents" / "Obsidian Vault" / "Ocean" / "Pearl"

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


# ── Anthropic client helper ───────────────────────────────────────────────────

def _get_anthropic_client():
    """Return an Anthropic client if available and API key is set, else None."""
    if not ANTHROPIC_AVAILABLE:
        return None
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None
    return _anthropic_module.Anthropic(api_key=api_key)


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
[["owner", "is_ceo_of", "company", 0.95], ["builder", "works_on", "project", 0.8]]

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


def diff_radar(entities: list, blocks: list, radar_search_fn=None) -> list:
    """For each extracted entity, check if Radar has an entry and if update is needed."""
    if radar_search_fn is None:
        try:
            from radar_search import radar_search as _cs
            radar_search_fn = _cs
        except ImportError:
            logger.warning("diff_radar: radar_search not available, skipping radar diff")
            return []

    radar_changes = []
    for entity in entities:
        name = entity.get("name", "") if isinstance(entity, dict) else str(entity)
        if not name:
            continue
        try:
            existing = radar_search_fn(name, limit=1)
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
                radar_changes.append({
                    "type": "update",
                    "slug": existing_slug,
                    "patch": f"[{entity.get('type','?') if isinstance(entity, dict) else '?'}:{name}]",
                    "entity": name,
                })
        else:
            # New entity — create a stub Radar entry
            entity_type = entity.get("type", "concept") if isinstance(entity, dict) else "concept"
            radar_changes.append({
                "type": "create",
                "slug": name.lower().replace(" ", "-"),
                "entity": name,
                "type_str": entity_type,
                "skeleton": f"[{entity_type}:{name}|src:dream-cycle]",
            })
    return radar_changes


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


def step4_refresh_radar(diff: dict, alias_entities: list, blocks: list, mode: str) -> int:
    """
    Refresh Radar sonars for entities involved in new triples (live mode only).
    Also applies radar_changes from diff_radar.
    Returns count of refreshed entries.
    """
    # Build entity list from triples for radar diff
    entity_names: set = set()
    for subj, pred, obj, conf in diff.get("new", []):
        entity_names.add(subj)
        entity_names.add(obj)

    # Build entity dicts for diff_radar
    entity_dicts = [{"name": n, "type": "concept"} for n in entity_names]

    # Compute radar changes (dry-run: count but don't write)
    radar_changes = diff_radar(entity_dicts, blocks)

    if mode == "dry-run":
        logger.info(
            "Step 4: dry-run — skipping Radar refresh (%d changes pending)", len(radar_changes)
        )
        return len(radar_changes)  # report count for dry-run visibility

    try:
        from radar import store_sonar as store_skeleton
    except ImportError:
        logger.warning("Step 4: radar import not available, skipping radar refresh")
        return 0

    try:
        from kg_helper import kg_query
        kg_query_available = True
    except ImportError:
        kg_query_available = False

    refreshed = 0

    # Apply radar_changes
    for change in radar_changes:
        try:
            if change["type"] == "create":
                group = change.get("type_str", "general")
                store_skeleton(group, change["slug"], change["skeleton"])
                refreshed += 1
            elif change["type"] == "update":
                try:
                    from radar_search import radar_search as _cs
                    existing = _cs(change["slug"], limit=1)
                except ImportError:
                    existing = []
                if existing:
                    updated = existing[0]["clsc"] + " | " + change["patch"]
                    store_skeleton("general", change["slug"], updated)
                    refreshed += 1
        except Exception as e:
            logger.warning("Step 4: failed to apply radar change %s: %s", change.get("slug"), e)

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
                logger.warning("Step 4: failed to refresh radar for %s: %s", entity, e)

    logger.info("Step 4: refreshed %d Radar entries", refreshed)
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
        from radar import read_radar as read_closet, store_sonar as store_skeleton
    except ImportError:
        logger.warning("Step 5: radar imports not available, skipping stitching")
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


# ── Phase 2: Schema migration ─────────────────────────────────────────────────

def _migrate_phase2_schema(conn: sqlite3.Connection) -> None:
    """Idempotent Phase 2 schema migration."""
    # pearl_fts FTS5 virtual table
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS pearl_fts USING fts5(
            slug, title, content, tokenize='trigram'
        )
    """)
    # pearl_blocks_processed column (idempotent via PRAGMA check)
    existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(dream_cycle_runs)")}
    if "pearl_blocks_processed" not in existing_cols:
        conn.execute(
            "ALTER TABLE dream_cycle_runs ADD COLUMN pearl_blocks_processed TEXT DEFAULT '[]'"
        )
    conn.commit()


# ── Phase 2: DB helpers ───────────────────────────────────────────────────────

def update_pearl_fts_index(slug: str, title: str, content: str) -> None:
    """Upsert into pearl_fts: DELETE then INSERT."""
    try:
        conn = sqlite3.connect(str(MEMORY_DB_PATH))
        try:
            conn.execute("DELETE FROM pearl_fts WHERE slug = ?", (slug,))
            conn.execute(
                "INSERT INTO pearl_fts (slug, title, content) VALUES (?, ?, ?)",
                (slug, title, content),
            )
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        logger.warning("update_pearl_fts_index: failed for %s: %s", slug, e)


def fts5_search_pearl(query: str, scope: str = "all", limit: int = 3) -> list:
    """
    Search pearl_fts. scope = "drafts" | "published" | "all".
    Returns [{slug, title, content (first 500 chars), scope, path}].
    Resolves file path: check DRAFTS_DIR/{slug}.md and PEARL_DIR/{slug}.md.
    Skip items where neither file exists.
    """
    try:
        conn = sqlite3.connect(str(MEMORY_DB_PATH))
        try:
            # Escape FTS5 query: wrap in double-quotes to avoid special char issues
            safe_query = query.replace('"', '""')
            rows = conn.execute(
                'SELECT slug, title, content FROM pearl_fts WHERE pearl_fts MATCH ? LIMIT ?',
                (f'"{safe_query}"', limit * 4),  # fetch more, filter by scope
            ).fetchall()
        finally:
            conn.close()
    except Exception as e:
        logger.warning("fts5_search_pearl: query failed: %s", e)
        return []

    results = []
    for row in rows:
        slug, title, content = row[0], row[1], row[2]
        draft_path = DRAFTS_DIR / f"{slug}.md"
        published_path = PEARL_DIR / f"{slug}.md"

        if draft_path.exists():
            item_scope = "drafts"
            item_path = str(draft_path)
        elif published_path.exists():
            item_scope = "published"
            item_path = str(published_path)
        else:
            continue  # file not found on disk — skip

        if scope != "all" and item_scope != scope:
            continue

        results.append({
            "slug": slug,
            "title": title,
            "content": content[:500],
            "scope": item_scope,
            "path": item_path,
        })
        if len(results) >= limit:
            break

    return results


def get_processed_block_hashes(run_date: str) -> set:
    """Read pearl_blocks_processed from dream_cycle_runs for run_date."""
    try:
        conn = sqlite3.connect(str(MEMORY_DB_PATH))
        try:
            row = conn.execute(
                "SELECT pearl_blocks_processed FROM dream_cycle_runs "
                "WHERE started_at LIKE ? AND status = 'complete' "
                "ORDER BY started_at DESC LIMIT 1",
                (f"{run_date}%",),
            ).fetchone()
        finally:
            conn.close()
        if row and row[0]:
            hashes = json.loads(row[0])
            return set(hashes) if isinstance(hashes, list) else set()
    except Exception as e:
        logger.warning("get_processed_block_hashes: %s", e)
    return set()


def record_processed_blocks(conn: sqlite3.Connection, run_date: str, blocks: list) -> None:
    """Merge new content_hashes into pearl_blocks_processed column."""
    try:
        row = conn.execute(
            "SELECT run_id, pearl_blocks_processed FROM dream_cycle_runs "
            "WHERE started_at LIKE ? ORDER BY started_at DESC LIMIT 1",
            (f"{run_date}%",),
        ).fetchone()
        if not row:
            return
        run_id = row[0]
        existing_raw = row[1] or "[]"
        existing = set(json.loads(existing_raw))
        new_hashes = {b.get("content_hash", "") for b in blocks if b.get("content_hash")}
        merged = list(existing | new_hashes)
        conn.execute(
            "UPDATE dream_cycle_runs SET pearl_blocks_processed = ? WHERE run_id = ?",
            (json.dumps(merged), run_id),
        )
        conn.commit()
    except Exception as e:
        logger.warning("record_processed_blocks: %s", e)


# ── Phase 2: Text helpers ─────────────────────────────────────────────────────

def slugify(title: str) -> str:
    """
    Convert title to slug: lowercase, keep [a-zA-Z0-9\\u4e00-\\u9fff],
    replace rest with hyphens, deduplicate hyphens, strip leading/trailing.
    """
    result = []
    for ch in title.lower():
        if re.match(r'[a-z0-9\u4e00-\u9fff]', ch):
            result.append(ch)
        else:
            result.append('-')
    slug = ''.join(result)
    # Deduplicate consecutive hyphens
    slug = re.sub(r'-{2,}', '-', slug)
    slug = slug.strip('-')
    return slug or "untitled"


def parse_pearl_sections(content: str) -> tuple:
    """
    Parse Pearl card into (frontmatter, current_understanding, links, evolution_log).

    - frontmatter: --- ... ---
    - Detect evolution marker: '\\n---\\n演化記錄：\\n'
    - Detect links marker: '\\n---\\n連結：\\n' (within main body)
    - Old format (no 演化記錄): entire body = current_understanding, evolution_log = ""
    - Missing frontmatter: generate default
    Returns 4 strings, all stripped.
    """
    today = datetime.now().strftime("%Y-%m-%d")

    # 1. Extract frontmatter
    fm_match = re.match(r'^---\n(.*?\n)---\n', content, re.DOTALL)
    if fm_match:
        frontmatter = f"---\n{fm_match.group(1)}---\n"
        body = content[fm_match.end():]
    else:
        frontmatter = (
            "---\n"
            "type: card\n"
            f"source_bot: unknown\n"
            f"created: {today}\n"
            "source: Dream Cycle\n"
            "status: draft\n"
            "---\n"
        )
        body = content

    # 2. Ensure required fields exist (insert before closing ---)
    required_fields = {"type": "card", "status": "draft", "source": "Dream Cycle"}
    for field, default in required_fields.items():
        if f"{field}:" not in frontmatter:
            frontmatter = frontmatter[:-4] + f"{field}: {default}\n---\n"

    # 3. Split out evolution log
    evolution_marker = re.search(r'\n---\n演化記錄：\n', body)
    if evolution_marker:
        main_body = body[:evolution_marker.start()]
        evolution_log = body[evolution_marker.end() - len("演化記錄：\n"):]
    else:
        main_body = body
        evolution_log = ""

    # 4. Split out links section
    links_marker = re.search(r'\n---\n連結：\n', main_body)
    if links_marker:
        current_understanding = main_body[:links_marker.start()]
        links = main_body[links_marker.end() - len("連結：\n"):]
    else:
        current_understanding = main_body
        links = ""

    return frontmatter, current_understanding.strip(), links.strip(), evolution_log.strip()


# ── Phase 2: Haiku calls ──────────────────────────────────────────────────────

def call_haiku_extract_insights(blob: str) -> list:
    """
    Prompt Haiku to extract insights from conversation blob.
    Returns list of {title, insight_text, source_quote} dicts.
    If no API key or error: return [].
    """
    client = _get_anthropic_client()
    if not client:
        return []

    prompt = (
        "以下是今天的對話記錄。找出含有「判斷/洞見/模式/原則」的段落"
        "（排除純事實、操作步驟、待辦事項、單純的技術 debug）。\n\n"
        "對每個洞見，輸出 JSON：\n"
        '{"insights": [{"title": "一句話標題", "insight_text": "核心想法，2-5 句話，< 300 字",'
        ' "source_quote": "原文中最能支撐此洞見的一段話（≤100 字）"}]}\n\n'
        '如果沒有值得記錄的洞見，回覆：{"insights": []}\n\n'
        f"對話記錄：\n{blob}"
    )

    try:
        msg = client.messages.create(
            model=HAIKU_MODEL,
            max_tokens=1000,
            temperature=0,
            timeout=10,
            messages=[{"role": "user", "content": prompt}],
        )
        result_text = msg.content[0].text.strip()
        result_text = re.sub(r'^```(?:json)?\s*|\s*```$', '', result_text, flags=re.DOTALL)
        data = json.loads(result_text)
        return data.get("insights", [])
    except Exception as e:
        logger.warning("call_haiku_extract_insights: %s", e)
        return []


def call_haiku_judge_evolution(existing_card: str, new_insight: str) -> str:
    """
    Returns "EVOLVE" | "SKIP" | "NEW".
    On error: return "SKIP" (safe default).
    """
    client = _get_anthropic_client()
    if not client:
        return "SKIP"

    prompt = (
        "以下是一張現有的 Pearl card 和一個新洞見。判斷新洞見與現有 card 的關係：\n\n"
        f"現有 card：\n{existing_card}\n\n"
        f"新洞見：\n{new_insight}\n\n"
        "回覆一個 JSON：\n"
        '{"decision": "EVOLVE" | "SKIP" | "NEW", "reason": "一句話解釋"}\n\n'
        "判斷標準：\n"
        "- EVOLVE：新洞見深化、更新、或推翻了現有觀點（要改寫 card）\n"
        "- SKIP：新洞見跟現有 card 說的是同一件事，沒有新資訊\n"
        "- NEW：主題相關但切角不同，值得獨立成一張新 card"
    )

    try:
        msg = client.messages.create(
            model=HAIKU_MODEL,
            max_tokens=200,
            temperature=0,
            timeout=10,
            messages=[{"role": "user", "content": prompt}],
        )
        result_text = msg.content[0].text.strip()
        result_text = re.sub(r'^```(?:json)?\s*|\s*```$', '', result_text, flags=re.DOTALL)
        data = json.loads(result_text)
        decision = data.get("decision", "SKIP").upper()
        if decision not in ("EVOLVE", "SKIP", "NEW"):
            return "SKIP"
        return decision
    except Exception as e:
        logger.warning("call_haiku_judge_evolution: %s", e)
        return "SKIP"


def call_haiku_rewrite_understanding(old_understanding: str, new_insight: str) -> str:
    """
    Rewrite the 'current understanding' section incorporating new_insight.
    Returns new understanding text (max 300 chars body).
    On error: return old_understanding unchanged.
    """
    client = _get_anthropic_client()
    if not client:
        return old_understanding

    prompt = (
        "以下是一張 Pearl card 的當前理解和一個新洞見。\n"
        "請整合新洞見，重寫「當前最佳理解」（2-5 句話，≤ 300 字，保留核心觀點）。\n"
        "只輸出重寫後的正文，不要 frontmatter 或標題。\n\n"
        f"當前理解：{old_understanding}\n新洞見：{new_insight}"
    )

    try:
        msg = client.messages.create(
            model=HAIKU_MODEL,
            max_tokens=400,
            temperature=0,
            timeout=10,
            messages=[{"role": "user", "content": prompt}],
        )
        result_text = msg.content[0].text.strip()
        return result_text
    except Exception as e:
        logger.warning("call_haiku_rewrite_understanding: %s", e)
        return old_understanding


# ── Phase 2: Wikilink helper ──────────────────────────────────────────────────

def find_related_wikilinks(text: str, limit: int = 3) -> list:
    """
    Use radar_fts (via FTS on memory.db) to find related slugs.
    Returns list of "[[slug]]" strings.
    Falls back to [] if radar_fts table not available.
    """
    try:
        conn = sqlite3.connect(str(MEMORY_DB_PATH))
        try:
            # Check table exists
            tables = {r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' OR type='shadow'"
            )}
            # FTS5 virtual tables show up as the table name itself
            table_check = conn.execute(
                "SELECT name FROM sqlite_master WHERE name='radar_fts'"
            ).fetchone()
            if not table_check:
                return []

            safe_query = text[:200].replace('"', '""')
            rows = conn.execute(
                "SELECT slug FROM radar_fts WHERE radar_fts MATCH ? LIMIT ?",
                (f'"{safe_query}"', limit),
            ).fetchall()
            return [f"[[{row[0]}]]" for row in rows]
        finally:
            conn.close()
    except Exception as e:
        logger.debug("find_related_wikilinks: %s", e)
        return []


# ── Phase 2: Pearl write functions ────────────────────────────────────────────

def create_pearl_draft(candidate: dict, evolves_from: str = None) -> str:
    """
    Create new Pearl draft in DRAFTS_DIR.
    Filename: {today}-{slug}.md (with counter suffix if exists).
    Returns str(filepath).
    """
    today = datetime.now().strftime("%Y-%m-%d")
    title = candidate.get("title", "Untitled")
    insight_text = candidate.get("insight_text", "")

    slug = slugify(title)

    # Find non-colliding filename
    base_name = f"{today}-{slug}"
    candidate_path = DRAFTS_DIR / f"{base_name}.md"
    counter = 1
    while candidate_path.exists():
        candidate_path = DRAFTS_DIR / f"{base_name}-{counter}.md"
        counter += 1

    # Find wikilinks (need >= 2)
    wikilinks = find_related_wikilinks(insight_text, limit=3)
    if len(wikilinks) < 2:
        # retry with title
        extra = find_related_wikilinks(title, limit=3)
        combined = list(dict.fromkeys(wikilinks + extra))
        wikilinks = combined

    # Build frontmatter
    fm_lines = [
        "---",
        "type: card",
        f"source_bot: dream-cycle",
        f"created: {today}",
        "source: Dream Cycle",
        "status: draft",
    ]
    if evolves_from:
        fm_lines.append(f"evolves_from: [[{evolves_from}]]")
    fm_lines.append("---")
    frontmatter = "\n".join(fm_lines) + "\n"

    # Build body
    links_section = "\n---\n連結：\n" + "\n".join(wikilinks[:5]) if wikilinks else ""
    evolution_entry = f"- {today}：初始建立，來源：Dream Cycle 對話萃取"
    evolution_section = f"\n---\n演化記錄：\n{evolution_entry}\n"

    content = (
        f"{frontmatter}\n"
        f"# {title}\n\n"
        f"{insight_text}\n"
        f"{links_section}\n"
        f"{evolution_section}"
    )

    DRAFTS_DIR.mkdir(parents=True, exist_ok=True)
    candidate_path.write_text(content, encoding="utf-8")

    # Update FTS index
    update_pearl_fts_index(candidate_path.stem, title, insight_text)

    logger.info("create_pearl_draft: created %s", candidate_path)
    return str(candidate_path)


def update_existing_pearl(card_path: str, candidate: dict) -> None:
    """
    Update existing Pearl draft.
    ⚠️ Safety: raises ValueError if '_drafts' not in card_path.
    """
    if "_drafts" not in card_path:
        raise ValueError(
            f"EVOLVE 安全邊界：不允許直接更新正式 card: {card_path}。"
            "請改用 create_pearl_draft(evolves_from=...) 降級為 CREATE。"
        )

    today = datetime.now().strftime("%Y-%m-%d")
    content = Path(card_path).read_text(encoding="utf-8")
    frontmatter, current_understanding, links, evolution_log = parse_pearl_sections(content)

    old_summary = current_understanding.strip()[:80]

    # Rewrite understanding
    new_understanding = call_haiku_rewrite_understanding(
        old_understanding=current_understanding,
        new_insight=candidate.get("insight_text", ""),
    )

    # Refresh wikilinks (merge with existing, dedup, max 5)
    existing_links = re.findall(r'\[\[(.+?)\]\]', links)
    new_link_strs = find_related_wikilinks(new_understanding, limit=3)
    new_link_slugs = [l.strip('[]') for l in new_link_strs]
    all_links = list(dict.fromkeys(existing_links + new_link_slugs))[:5]

    # Append evolution entry
    source_desc = candidate.get("source_quote", "Dream Cycle 對話萃取")[:60]
    evolution_entry = f"- {today}：因 [{source_desc}] 更新，舊觀點：{old_summary}"

    # Update frontmatter updated field
    if re.search(r'updated: .+', frontmatter):
        frontmatter = re.sub(r'updated: .+', f'updated: {today}', frontmatter)
    else:
        frontmatter = frontmatter.rstrip('\n') + f'\nupdated: {today}\n---\n'
        # fix double ---
        frontmatter = re.sub(r'---\n---\n', '---\n', frontmatter)

    # Reassemble
    links_section = "\n---\n連結：\n" + "\n".join(f"- [[{l}]]" for l in all_links)
    if evolution_log:
        evolution_section = evolution_log.rstrip('\n') + "\n" + evolution_entry
    else:
        evolution_section = "演化記錄：\n" + evolution_entry

    final_content = (
        f"{frontmatter}\n"
        f"{new_understanding}\n"
        f"{links_section}\n\n"
        f"---\n{evolution_section}\n"
    )

    Path(card_path).write_text(final_content, encoding="utf-8")

    # Update FTS index
    slug = Path(card_path).stem
    update_pearl_fts_index(slug, candidate.get("title", slug), new_understanding)
    logger.info("update_existing_pearl: updated %s", card_path)


_FLAG_MODEL_CACHE: "object | None" = None


def _get_flag_model() -> "object | None":
    """Return cached FlagModel instance, loading it once per process."""
    global _FLAG_MODEL_CACHE
    if _FLAG_MODEL_CACHE is not None:
        return _FLAG_MODEL_CACHE
    try:
        venv_site = Path.home() / ".claude-bots" / "shared" / "venv" / "lib"
        for p in venv_site.glob("python*/site-packages"):
            if str(p) not in sys.path:
                sys.path.insert(0, str(p))
        from FlagEmbedding import FlagModel
        _FLAG_MODEL_CACHE = FlagModel("BAAI/bge-m3", use_fp16=True)
        logger.info("compute_pearl_embedding: FlagModel loaded and cached")
        return _FLAG_MODEL_CACHE
    except Exception as e:
        logger.debug("_get_flag_model: FlagEmbedding unavailable — %s", e)
        return None


def compute_pearl_embedding(text: str) -> "list[float] | None":
    """Compute 1024-dim BGE-m3 embedding for Pearl dedup.

    Returns list[float] or None if FlagEmbedding unavailable (graceful degradation).
    Model is cached at module level to avoid repeated 400MB+ loads per cycle.
    """
    model = _get_flag_model()
    if model is None:
        return None
    try:
        embedding = model.encode([text[:512]], batch_size=1)
        return embedding[0].tolist()
    except Exception as e:
        logger.debug("compute_pearl_embedding: encode failed — %s", e)
        return None


def get_existing_pearl_embeddings(conn: sqlite3.Connection) -> "list[dict]":
    """Fetch existing Pearl embeddings from radar_vec (sqlite-vec virtual table).

    Returns list of {slug, embedding: list[float], path} for all Pearl entries in radar_vec.
    Falls back to empty list on any error.
    """
    try:
        import struct
        rows = conn.execute(
            "SELECT slug, embedding FROM radar_vec"
        ).fetchall()
        results = []
        for slug, emb_bytes in rows:
            if not slug.startswith("pearl-"):
                continue
            if isinstance(emb_bytes, bytes):
                n = len(emb_bytes) // 4
                emb = list(struct.unpack(f"{n}f", emb_bytes))
            elif isinstance(emb_bytes, (list, tuple)):
                emb = list(emb_bytes)
            else:
                continue
            # Reconstruct path from slug
            path = str(DRAFTS_DIR / f"{slug}.md")
            if not Path(path).exists():
                path = str(DRAFTS_DIR.parent / f"{slug}.md")
            results.append({"slug": slug, "embedding": emb, "path": path})
        return results
    except Exception as e:
        logger.debug("get_existing_pearl_embeddings: error — %s", e)
        return []


def cosine_similarity(a: "list[float]", b: "list[float]") -> float:
    """Compute cosine similarity between two vectors using numpy."""
    import numpy as np
    a_arr = np.array(a, dtype=np.float32)
    b_arr = np.array(b, dtype=np.float32)
    dot = np.dot(a_arr, b_arr)
    norm_a = np.linalg.norm(a_arr)
    norm_b = np.linalg.norm(b_arr)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(dot / (norm_a * norm_b))


def find_duplicate_pearl(
    candidate_embedding: "list[float]",
    existing_embeddings: "list[dict]",
    threshold: float = 0.85,
) -> "dict | None":
    """Find the most similar existing Pearl above threshold.

    Returns the best-match dict {slug, embedding, path, similarity} or None.
    """
    best = None
    best_sim = -1.0
    for entry in existing_embeddings:
        sim = cosine_similarity(candidate_embedding, entry["embedding"])
        if sim > best_sim:
            best_sim = sim
            best = entry
    if best is not None and best_sim >= threshold:
        return {**best, "similarity": best_sim}
    return None


def generate_dedup_report(dedup_stats: dict) -> str:
    """Generate dedup sensor summary line for TG report.

    dedup_stats keys: embedding_checked, embedding_merged, embedding_new, embedding_unavailable
    Returns formatted string like '🔬 Dedup Sensor: 2 merged, 3 new (threshold=0.85)'
    """
    merged = dedup_stats.get("embedding_merged", 0)
    new = dedup_stats.get("embedding_new", 0)
    unavailable = dedup_stats.get("embedding_unavailable", 0)
    suffix = " [embedding unavailable]" if unavailable else ""
    return f"🔬 Dedup Sensor: {merged} merged, {new} new (threshold=0.85){suffix}"


# ── Phase 2: Main Step 5.5 ────────────────────────────────────────────────────

def step_5_5_pearl_generation(
    conversation_blocks: list,
    run_date: str,
    conn: sqlite3.Connection,
    mode: str = "dry-run",
) -> dict:
    """
    Step 5.5: Extract insights → dedup → create/update Pearl drafts.

    Returns {pearls_created, pearls_updated, pearls_skipped, pearl_details: [...]}

    In dry-run mode: log what would happen but don't write files or update DB.
    In live mode: write files + update pearl_blocks_processed.
    """
    result = {
        "pearls_created": 0,
        "pearls_updated": 0,
        "pearls_skipped": 0,
        "pearl_details": [],
        "dedup_sensor": {
            "embedding_checked": 0,
            "embedding_merged": 0,
            "embedding_new": 0,
            "embedding_unavailable": 0,
        },
    }

    if not conversation_blocks:
        logger.info("Step 5.5: no conversation blocks — skipping")
        return result

    # ── 0. Idempotency: filter already processed blocks ─────────────────────
    processed_hashes = get_processed_block_hashes(run_date)
    new_blocks = [
        b for b in conversation_blocks
        if b.get("content_hash", "") not in processed_hashes
    ]
    if not new_blocks:
        logger.info("Step 5.5: all blocks already processed — skipping")
        return result

    # ── 1. Merge blocks into blob (max 5000 chars) ───────────────────────────
    blob = "\n\n".join(b.get("text", "") for b in new_blocks)[:5000]

    # ── 2. Extract insights from Haiku ───────────────────────────────────────
    candidates = call_haiku_extract_insights(blob)
    logger.info("Step 5.5: Haiku returned %d insight candidates", len(candidates))

    if not candidates:
        if mode == "live":
            record_processed_blocks(conn, run_date, new_blocks)
        return result

    created, updated, skipped = 0, 0, 0
    dedup_stats = result["dedup_sensor"]
    existing_embeddings = get_existing_pearl_embeddings(conn)

    for candidate in candidates[:5]:
        if created + updated >= 3:
            break

        title = candidate.get("title", "")
        insight_text = candidate.get("insight_text", "")

        if not title or not insight_text:
            continue

        # ── FTS dedup search ─────────────────────────────────────────────────
        draft_matches = fts5_search_pearl(title, scope="drafts", limit=3)
        published_matches = fts5_search_pearl(title, scope="published", limit=3)
        all_matches = draft_matches + published_matches

        if all_matches:
            best_match = all_matches[0]
            evolution_decision = call_haiku_judge_evolution(
                existing_card=best_match["content"],
                new_insight=insight_text,
            )
            logger.info(
                "Step 5.5: candidate '%s' → decision=%s (scope=%s)",
                title, evolution_decision, best_match["scope"],
            )

            if evolution_decision == "EVOLVE":
                if best_match["scope"] == "drafts":
                    if mode == "live":
                        update_existing_pearl(best_match["path"], candidate)
                    else:
                        logger.info("Step 5.5: dry-run — would update %s", best_match["path"])
                    updated += 1
                    result["pearl_details"].append({
                        "action": "update",
                        "title": title,
                        "path": best_match["path"],
                        "old_summary": best_match["content"][:80],
                    })
                else:
                    # Published card → downgrade to CREATE
                    if mode == "live":
                        path = create_pearl_draft(candidate, evolves_from=best_match["slug"])
                    else:
                        path = str(DRAFTS_DIR / f"dry-run-{slugify(title)}.md")
                        logger.info("Step 5.5: dry-run — would create (evolves_from) %s", path)
                    created += 1
                    result["pearl_details"].append({
                        "action": "create",
                        "title": title,
                        "path": path,
                    })
            elif evolution_decision == "NEW":
                if mode == "live":
                    path = create_pearl_draft(candidate)
                else:
                    path = str(DRAFTS_DIR / f"dry-run-{slugify(title)}.md")
                    logger.info("Step 5.5: dry-run — would create new %s", path)
                created += 1
                result["pearl_details"].append({
                    "action": "create",
                    "title": title,
                    "path": path,
                })
            else:  # SKIP
                skipped += 1
                result["pearl_details"].append({
                    "action": "skip",
                    "title": title,
                    "reason": "SKIP",
                })
        else:
            # No FTS match — run embedding dedup
            candidate_emb = compute_pearl_embedding(insight_text)
            if candidate_emb is not None:
                dedup_stats["embedding_checked"] += 1
                dup = find_duplicate_pearl(candidate_emb, existing_embeddings, threshold=0.85)
                if dup is not None:
                    # Semantic duplicate found → merge
                    logger.info(
                        "Step 5.5: embedding dedup hit for '%s' → similarity=%.3f, merging into %s",
                        title, dup["similarity"], dup["path"],
                    )
                    if mode == "live":
                        update_existing_pearl(dup["path"], candidate)
                    else:
                        logger.info("Step 5.5: dry-run — would merge into %s", dup["path"])
                    dedup_stats["embedding_merged"] += 1
                    updated += 1
                    result["pearl_details"].append({
                        "action": "update",
                        "title": title,
                        "path": dup["path"],
                        "merge_reason": "embedding_dedup",
                        "similarity": round(dup["similarity"], 3),
                    })
                else:
                    # Not a duplicate → create new
                    dedup_stats["embedding_new"] += 1
                    if mode == "live":
                        path = create_pearl_draft(candidate)
                    else:
                        path = str(DRAFTS_DIR / f"dry-run-{slugify(title)}.md")
                        logger.info("Step 5.5: dry-run — would create new %s", path)
                    created += 1
                    result["pearl_details"].append({
                        "action": "create",
                        "title": title,
                        "path": path,
                    })
            else:
                # FlagEmbedding unavailable — graceful degradation
                dedup_stats["embedding_unavailable"] += 1
                if mode == "live":
                    path = create_pearl_draft(candidate)
                else:
                    path = str(DRAFTS_DIR / f"dry-run-{slugify(title)}.md")
                    logger.info("Step 5.5: dry-run — would create new %s", path)
                created += 1
                result["pearl_details"].append({
                    "action": "create",
                    "title": title,
                    "path": path,
                })

    result["pearls_created"] = created
    result["pearls_updated"] = updated
    result["pearls_skipped"] = skipped

    # ── Record processed blocks (live only) ──────────────────────────────────
    if mode == "live":
        record_processed_blocks(conn, run_date, new_blocks)

    logger.info(
        "Step 5.5: pearls created=%d updated=%d skipped=%d",
        created, updated, skipped,
    )
    return result


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
    """Send report summary to owner's Telegram chat."""
    tg_token = _load_tg_token()
    if not tg_token:
        logger.warning("Step 6: TELEGRAM_BOT_TOKEN not set, skipping TG notification")
        return

    s = report["summary"]
    mode_tag = "DRY-RUN" if report["mode"] == "dry-run" else "LIVE"
    content_hash_line = ""
    if report.get("content_hash"):
        content_hash_line = f"\nhash: {report['content_hash'][:12]}..."
    stale_line = f"\nStale pending: {s['stale_pending']}" if s.get('stale_pending', 0) > 0 else ""
    triage_issues = report.get("triage_issues", [])
    if triage_issues:
        issue_types = ", ".join(t["issue_type"] for t in triage_issues)
        triage_line = f"\n⚠️ {len(triage_issues)} open triage issues: [{issue_types}]"
    else:
        triage_line = "\n✅ No open triage issues"
    pearls_line = ""
    p_created = s.get("pearls_created", 0)
    p_updated = s.get("pearls_updated", 0)
    p_skipped = s.get("pearls_skipped", 0)
    if p_created + p_updated + p_skipped > 0:
        pearls_line = f"\nPearls: +{p_created} ~{p_updated} skip {p_skipped}"
    dedup_sensor = s.get("dedup_sensor", {})
    dedup_line = ""
    if any(dedup_sensor.values()):
        dedup_line = "\n" + generate_dedup_report(dedup_sensor)
    kg_line = ""
    kg_scan = report.get("kg_invalidation")
    if kg_scan and not kg_scan.get("skipped"):
        active = kg_scan.get("active_count", "?")
        kg_line = f"\n🗂 KG Scan: {kg_scan.get('decayed', 0)} decayed, {kg_scan.get('invalidated', 0)} invalidated, {kg_scan.get('archived', 0)} archived (active: {active})"
    text = (
        f"Dream Cycle complete — {mode_tag}\n"
        f"Messages scanned: {s['messages_scanned']}\n"
        f"Triples extracted: {s['triples_extracted_raw']} -> normalized: {s['triples_after_normalization']}\n"
        f"New KG facts: {s['triples_new']} written: {s['kg_written']}\n"
        f"Duplicates: {s['triples_duplicate']} | Conflicts: {s['triples_conflict']}\n"
        f"Radar refreshed: {s['radar_refreshed']} | Stitched: {s['references_stitched']}"
        f"{pearls_line}"
        f"{dedup_line}"
        f"{kg_line}"
        f"{stale_line}"
        f"{triage_line}"
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
    open_triages: list = None,
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
            radar_refreshed = step4_refresh_radar(diff, alias_entities, blocks, mode)
            update_run_status(run_id, "running_step5", conn)
        else:
            logger.info("Skipping step 4 (already done)")
            kg_written = 0
            radar_refreshed = 0

        # ── Step 5 ──────────────────────────────────────────────────────────
        if should_run(5):
            stitched = step5_stitch_references(diff, mode)
            update_run_status(run_id, "running_step55", conn)
        else:
            logger.info("Skipping step 5 (already done)")
            stitched = 0

        # ── Step 5.5 ─────────────────────────────────────────────────────────
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if should_run(5):
            # Add content_hash to blocks for idempotency tracking
            blocks_with_hash = []
            for b in blocks:
                bh = dict(b)
                if "content_hash" not in bh:
                    bh["content_hash"] = hashlib.sha256(
                        bh.get("text", "").encode()
                    ).hexdigest()
                blocks_with_hash.append(bh)
            pearl_result = step_5_5_pearl_generation(
                conversation_blocks=blocks_with_hash,
                run_date=today,
                conn=conn,
                mode=mode,
            )
            logger.info(
                "Step 5.5: pearls created=%d updated=%d skipped=%d",
                pearl_result["pearls_created"],
                pearl_result["pearls_updated"],
                pearl_result["pearls_skipped"],
            )
            update_run_status(run_id, "running_step6", conn)
        else:
            logger.info("Skipping step 5.5 (already done)")
            pearl_result = {"pearls_created": 0, "pearls_updated": 0, "pearls_skipped": 0, "pearl_details": [], "dedup_sensor": {}}

        # ── Step 5.8: KG Temporal Scan (weekly) ─────────────────────────────────
        kg_scan_result = None
        if should_run(5):
            try:
                kg_db_path = Path.home() / ".claude-bots" / "kg.db"
                if kg_db_path.exists():
                    # Weekly gate: check last kg_scan_at in dream_cycle_runs
                    should_scan = True
                    if mode != "dry-run":
                        last_scan_row = conn.execute(
                            "SELECT MAX(finished_at) FROM dream_cycle_runs WHERE status='complete' AND report_json LIKE '%kg_scan%'"
                        ).fetchone()
                        if last_scan_row and last_scan_row[0]:
                            try:
                                last_scan_dt = datetime.fromisoformat(last_scan_row[0].replace('Z', '+00:00'))
                                if (datetime.now(timezone.utc) - last_scan_dt).days < 7:
                                    logger.info("Step 5.8: KG temporal scan skipped (< 7 days since last scan)")
                                    should_scan = False
                            except Exception:
                                pass
                    if should_scan:
                        kg_conn = sqlite3.connect(str(kg_db_path))
                        try:
                            kg_scan_result = step_kg_temporal_scan(kg_conn, conn, mode)
                            logger.info("Step 5.8: KG scan — %s", kg_scan_result)
                        finally:
                            kg_conn.close()
                else:
                    logger.info("Step 5.8: kg.db not found, skipping KG temporal scan")
            except Exception as e:
                logger.warning("Step 5.8: KG temporal scan failed (non-fatal): %s", e)

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
            radar_refreshed=radar_refreshed,
            stitched=stitched,
            started_at=started_at_str,
            content_hash=content_hash,
            pearls_created=pearl_result.get("pearls_created", 0),
            pearls_updated=pearl_result.get("pearls_updated", 0),
            pearls_skipped=pearl_result.get("pearls_skipped", 0),
            pearl_details=pearl_result.get("pearl_details", []),
            open_triages=open_triages,
            kg_scan=kg_scan_result,
            dedup_sensor=pearl_result.get("dedup_sensor", {}),
        )

        # Mark run as finished
        finished_at = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "UPDATE dream_cycle_runs SET finished_at=?, status=?, report_json=? WHERE run_id=?",
            (finished_at, "complete", json.dumps(report), run_id),
        )
        conn.commit()

        step6_send_tg_report(report)

        # Post-report: lightweight FTS gap check (radar vs radar_fts)
        _check_fts_gap(conn)

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
        # ── Triage scan (pre-flight) ──────────────────────────────────────────
        open_triages = scan_pending_triage_tasks()
        if open_triages:
            logger.warning("Found %d open triage issue(s): %s", len(open_triages),
                           [t["issue_type"] for t in open_triages])
        else:
            logger.info("Triage check: no open issues")

        # Schema migration
        ensure_schema(conn)
        _migrate_phase2_schema(conn)

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
            return _run_steps(run_id, messages, blocks, conn, mode, start_from_step=2, open_triages=open_triages)
        except Exception:
            return 1

    except Exception as e:
        logger.exception("Pipeline setup failed: %s", e)
        return 1
    finally:
        conn.close()


# ── FATQ triage helpers ───────────────────────────────────────────────────────

def create_triage_task(
    issue_type: str,
    component: str,
    description: str,
    severity: str,
    log_snippet: str = "",
) -> str:
    """Create a triage-*.json file in tasks/pending/. Returns the file path."""
    try:
        pending_dir = TASKS_DIR / "pending"
        pending_dir.mkdir(parents=True, exist_ok=True)
        now = datetime.now(timezone.utc)
        ts_str = now.strftime("%Y%m%d-%H%M%S")
        hex_suffix = uuid.uuid4().hex[:4]
        task_id = f"triage-{issue_type}-{ts_str}-{hex_suffix}"
        filename = f"triage-{issue_type}-{ts_str}-{hex_suffix}.json"
        task = {
            "type": "triage",
            "id": task_id,
            "issue_type": issue_type,
            "component": component,
            "description": description,
            "severity": severity,
            "log_snippet": log_snippet[:500],
            "created_at": now.isoformat(),
            "status": "pending",
            "resolved_at": None,
        }
        tmp_path = pending_dir / f"{filename}.tmp"
        final_path = pending_dir / filename
        tmp_path.write_text(json.dumps(task, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_path.rename(final_path)
        logger.info("Triage task created: %s", final_path)
        return str(final_path)
    except Exception as e:
        logger.warning("create_triage_task failed (non-fatal): %s", e)
        return ""


def scan_pending_triage_tasks() -> list:
    """Read all triage-*.json from tasks/pending/. Returns list of open issues."""
    try:
        pending_dir = TASKS_DIR / "pending"
        if not pending_dir.exists():
            return []
        issues = []
        for fpath in sorted(pending_dir.glob("triage-*.json")):
            try:
                data = json.loads(fpath.read_text(encoding="utf-8"))
                issues.append({
                    "id": data.get("id", fpath.stem),
                    "issue_type": data.get("issue_type", "unknown"),
                    "severity": data.get("severity", "medium"),
                    "description": data.get("description", ""),
                    "created_at": data.get("created_at", ""),
                })
            except Exception as parse_err:
                logger.warning("scan_pending_triage_tasks: failed to parse %s: %s", fpath, parse_err)
        return issues
    except Exception as e:
        logger.warning("scan_pending_triage_tasks failed (non-fatal): %s", e)
        return []


# ── KG Temporal Invalidation Sensor ──────────────────────────────────────────

def ensure_archive_table(kg_conn: sqlite3.Connection) -> None:
    """CREATE TABLE IF NOT EXISTS triples_archive (same schema as triples + archived_at TEXT)."""
    try:
        kg_conn.execute("""
            CREATE TABLE IF NOT EXISTS triples_archive (
                id INTEGER PRIMARY KEY,
                subject TEXT,
                predicate TEXT,
                object TEXT,
                confidence REAL,
                source TEXT,
                extracted_at TEXT,
                valid_until TEXT,
                confidence_decay REAL,
                status TEXT,
                invalidated_at TEXT,
                last_referenced_at TEXT,
                archived_at TEXT
            )
        """)
        kg_conn.commit()
    except Exception as e:
        logger.warning("ensure_archive_table: %s", e)


def ensure_kg_schema(kg_conn: sqlite3.Connection) -> None:
    """Idempotently add new columns to triples table in kg.db.
    New columns: valid_until, confidence_decay, status, invalidated_at, last_referenced_at.
    Uses PRAGMA table_info to check before ALTER TABLE."""
    try:
        col_info = kg_conn.execute("PRAGMA table_info(triples)").fetchall()
        existing_cols = {row[1] for row in col_info}
        new_columns = [
            ("valid_until", "TEXT"),
            ("confidence_decay", "REAL DEFAULT 1.0"),
            ("status", "TEXT DEFAULT 'active'"),
            ("invalidated_at", "TEXT"),
            ("last_referenced_at", "TEXT"),
        ]
        for col_name, col_def in new_columns:
            if col_name not in existing_cols:
                try:
                    kg_conn.execute(f"ALTER TABLE triples ADD COLUMN {col_name} {col_def}")
                    logger.info("ensure_kg_schema: added column %s", col_name)
                except Exception as e:
                    logger.warning("ensure_kg_schema: failed to add %s: %s", col_name, e)
        kg_conn.commit()
    except Exception as e:
        logger.warning("ensure_kg_schema: %s", e)


def decay_unreferenced_triples(kg_conn: sqlite3.Connection, days_threshold: int = 90, decay_step: float = 0.1, mode: str = "dry-run") -> int:
    """超過 days_threshold 天未引用（last_referenced_at IS NULL 或 < threshold）的 active triple：
    confidence_decay -= decay_step（最低 0.0），status 改為 'decayed'。
    dry-run 只計數不寫入。返回受影響筆數。"""
    try:
        threshold = (datetime.now(timezone.utc) - timedelta(days=days_threshold)).isoformat()
        rows = kg_conn.execute(
            "SELECT id, confidence_decay FROM triples "
            "WHERE (status IS NULL OR status = 'active') "
            "AND (last_referenced_at IS NULL OR last_referenced_at < ?)",
            (threshold,),
        ).fetchall()
        count = len(rows)
        if mode != "dry-run" and count > 0:
            now_str = datetime.now(timezone.utc).isoformat()
            for row in rows:
                triple_id = row[0]
                current_decay = row[1] if row[1] is not None else 1.0
                new_decay = max(0.0, current_decay - decay_step)
                kg_conn.execute(
                    "UPDATE triples SET confidence_decay = ?, status = 'decayed' WHERE id = ?",
                    (new_decay, triple_id),
                )
            kg_conn.commit()
            logger.info("decay_unreferenced_triples: decayed %d triples", count)
        else:
            logger.info("decay_unreferenced_triples: %d triples would be decayed (dry-run=%s)", count, mode == "dry-run")
        return count
    except Exception as e:
        logger.warning("decay_unreferenced_triples: %s", e)
        return 0


def invalidate_contradicted_triples(kg_conn: sqlite3.Connection, memory_conn: sqlite3.Connection, mode: str = "dry-run") -> int:
    """掃描 active triples，用 Haiku LLM 判斷是否與 radar/Pearl 內容矛盾。
    矛盾 triple status='invalidated'，設 invalidated_at=now。
    若 ANTHROPIC_API_KEY 不可用則跳過，返回 0。
    dry-run 只計數不寫入。返回受影響筆數。"""
    if not ANTHROPIC_AVAILABLE:
        logger.info("invalidate_contradicted_triples: anthropic not available, skipping")
        return 0
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        logger.info("invalidate_contradicted_triples: ANTHROPIC_API_KEY not set, skipping")
        return 0

    try:
        rows = kg_conn.execute(
            "SELECT id, subject, predicate, object FROM triples "
            "WHERE (status IS NULL OR status = 'active') "
            "ORDER BY extracted_at DESC LIMIT 50"
        ).fetchall()
    except Exception as e:
        logger.warning("invalidate_contradicted_triples: failed to fetch triples: %s", e)
        return 0

    client = _anthropic_module.Anthropic(api_key=api_key)
    invalidated_ids = []
    now_str = datetime.now(timezone.utc).isoformat()

    for row in rows:
        triple_id, subject, predicate, obj = row[0], row[1], row[2], row[3]
        # Look up radar content for the subject
        radar_content = None
        try:
            radar_row = memory_conn.execute(
                "SELECT content FROM radar WHERE slug LIKE ? LIMIT 1",
                (f"%{subject}%",),
            ).fetchone()
            if radar_row:
                radar_content = radar_row[0]
        except Exception:
            pass

        if not radar_content:
            continue

        # Ask Haiku if this triple contradicts the radar content
        try:
            prompt = (
                f"Triple: [{subject}] --[{predicate}]--> [{obj}]\n"
                f"Context: {radar_content[:500]}\n"
                "Does the triple CONTRADICT the context? Reply ONLY: CONTRADICTS or OK"
            )
            msg = client.messages.create(
                model=HAIKU_MODEL,
                max_tokens=10,
                temperature=0,
                messages=[{"role": "user", "content": prompt}],
            )
            answer = msg.content[0].text.strip().upper()
            if "CONTRADICTS" in answer:
                invalidated_ids.append(triple_id)
        except Exception as e:
            logger.warning("invalidate_contradicted_triples: Haiku call failed for id=%s: %s", triple_id, e)
            continue

    count = len(invalidated_ids)
    if mode != "dry-run" and count > 0:
        for triple_id in invalidated_ids:
            try:
                kg_conn.execute(
                    "UPDATE triples SET status = 'invalidated', invalidated_at = ? WHERE id = ?",
                    (now_str, triple_id),
                )
            except Exception as e:
                logger.warning("invalidate_contradicted_triples: update failed for id=%s: %s", triple_id, e)
        kg_conn.commit()
        logger.info("invalidate_contradicted_triples: invalidated %d triples", count)
    else:
        logger.info("invalidate_contradicted_triples: %d triples would be invalidated (dry-run=%s)", count, mode == "dry-run")
    return count


def archive_old_invalidated_triples(kg_conn: sqlite3.Connection, days_since_invalidation: int = 30, mode: str = "dry-run") -> int:
    """將 status='invalidated' 且 invalidated_at 超過 days_since_invalidation 天的 triple
    搬移到 triples_archive（INSERT + DELETE 在同一 transaction）。
    dry-run 只計數不寫入。返回搬移筆數。"""
    try:
        threshold = (datetime.now(timezone.utc) - timedelta(days=days_since_invalidation)).isoformat()
        rows = kg_conn.execute(
            "SELECT id FROM triples WHERE status = 'invalidated' AND invalidated_at < ?",
            (threshold,),
        ).fetchall()
        count = len(rows)
        if mode != "dry-run" and count > 0:
            now_str = datetime.now(timezone.utc).isoformat()
            ids_to_archive = [row[0] for row in rows]
            placeholders = ",".join("?" * len(ids_to_archive))
            try:
                kg_conn.execute("BEGIN")
                kg_conn.execute(
                    f"INSERT INTO triples_archive "
                    f"SELECT id, subject, predicate, object, confidence, source, extracted_at, "
                    f"valid_until, confidence_decay, status, invalidated_at, last_referenced_at, ? "
                    f"FROM triples WHERE id IN ({placeholders})",
                    [now_str] + ids_to_archive,
                )
                kg_conn.execute(
                    f"DELETE FROM triples WHERE id IN ({placeholders})",
                    ids_to_archive,
                )
                kg_conn.execute("COMMIT")
                logger.info("archive_old_invalidated_triples: archived %d triples", count)
            except Exception as e:
                kg_conn.execute("ROLLBACK")
                logger.warning("archive_old_invalidated_triples: transaction failed: %s", e)
                return 0
        else:
            logger.info("archive_old_invalidated_triples: %d triples would be archived (dry-run=%s)", count, mode == "dry-run")
        return count
    except Exception as e:
        logger.warning("archive_old_invalidated_triples: %s", e)
        return 0


def step_kg_temporal_scan(kg_conn: sqlite3.Connection, memory_conn: sqlite3.Connection, mode: str = "dry-run") -> dict:
    """主掃描函數。呼叫 ensure_kg_schema/ensure_archive_table 後執行三個子函數，返回統計 dict：
    {decayed: int, invalidated: int, archived: int, skipped: bool, active_count: int}"""
    result = {"decayed": 0, "invalidated": 0, "archived": 0, "skipped": False, "active_count": 0}
    try:
        ensure_kg_schema(kg_conn)
        ensure_archive_table(kg_conn)
        # Count active triples
        try:
            active_row = kg_conn.execute(
                "SELECT COUNT(*) FROM triples WHERE (status IS NULL OR status = 'active')"
            ).fetchone()
            result["active_count"] = active_row[0] if active_row else 0
        except Exception as e:
            logger.warning("step_kg_temporal_scan: active count failed: %s", e)

        result["decayed"] = decay_unreferenced_triples(kg_conn, mode=mode)
        result["invalidated"] = invalidate_contradicted_triples(kg_conn, memory_conn, mode=mode)
        result["archived"] = archive_old_invalidated_triples(kg_conn, mode=mode)
    except Exception as e:
        logger.warning("step_kg_temporal_scan: %s", e)
        result["skipped"] = True
    return result


# ── FTS gap check (runs after Step 6) ────────────────────────────────────────

def _check_fts_gap(conn: sqlite3.Connection) -> None:
    """Compare radar vs radar_fts row counts; backfill if any gap is found."""
    try:
        radar_count = conn.execute("SELECT COUNT(*) FROM radar").fetchone()[0]
        fts_count_row = conn.execute(
            "SELECT COUNT(*) FROM radar_fts"
        ).fetchone()
        fts_count = fts_count_row[0] if fts_count_row else 0
        gap = radar_count - fts_count
        if gap > 0:
            logger.warning("FTS gap detected: radar=%d radar_fts=%d gap=%d — backfilling", radar_count, fts_count, gap)
            # Inline backfill: insert missing slugs into radar_fts
            try:
                missing = conn.execute(
                    "SELECT slug, clsc FROM radar WHERE slug NOT IN (SELECT slug FROM radar_fts)"
                ).fetchall()
                failed_count = 0
                for slug, clsc in missing:
                    try:
                        conn.execute("INSERT INTO radar_fts(slug, clsc) VALUES (?, ?)", (slug, clsc or ""))
                    except Exception:
                        failed_count += 1
                conn.commit()
                if failed_count > 0:
                    logger.warning("FTS gap backfill partial: %d/%d failed", failed_count, len(missing))
                    create_triage_task(
                        issue_type="fts_gap_backfill_failed",
                        component="radar_fts",
                        description=f"FTS backfill failed: {failed_count}/{len(missing)} entries could not be inserted",
                        severity="medium",
                        log_snippet=f"radar={radar_count} fts={fts_count} gap={gap} failed={failed_count}",
                    )
                else:
                    logger.info("FTS gap backfill complete: inserted %d entries", len(missing))
            except Exception as backfill_err:
                logger.warning("FTS gap backfill exception: %s", backfill_err)
                create_triage_task(
                    issue_type="fts_gap_backfill_failed",
                    component="radar_fts",
                    description=f"FTS backfill exception: {type(backfill_err).__name__}: {str(backfill_err)[:200]}",
                    severity="high",
                    log_snippet=f"radar={radar_count} fts={fts_count} gap={gap}",
                )
        else:
            logger.info("FTS gap check OK: radar=%d radar_fts=%d", radar_count, fts_count)
    except Exception as e:
        logger.warning("FTS gap check failed (non-fatal): %s", e)


# ── Step 6: Report (updated signature) ───────────────────────────────────────

def step6_generate_report(
    run_id: str,
    mode: str,
    messages_count: int,
    triples_raw: int,
    triples_normalized: int,
    diff: dict,
    kg_written: int,
    radar_refreshed: int,
    stitched: int,
    started_at: str,
    content_hash: str = None,
    pearls_created: int = 0,
    pearls_updated: int = 0,
    pearls_skipped: int = 0,
    pearl_details: list = None,
    open_triages: list = None,
    kg_scan: dict = None,
    dedup_sensor: dict = None,
) -> dict:
    """Generate report JSON and save to logs/dream-cycle/YYYY-MM-DD.json."""
    finished_at = datetime.now(timezone.utc).isoformat()
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Count stale_candidates pending
    stale_pending = 0
    try:
        db_path_for_stale = Path.home() / ".claude-bots" / "memory.db"
        if db_path_for_stale.exists():
            import sqlite3 as _sqlite3
            _conn = _sqlite3.connect(str(db_path_for_stale))
            _tables = {r[0] for r in _conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "stale_candidates" in _tables:
                stale_pending = _conn.execute(
                    "SELECT COUNT(*) FROM stale_candidates WHERE status='pending'"
                ).fetchone()[0]
            _conn.close()
    except Exception:
        pass

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
            "radar_refreshed": radar_refreshed,
            "references_stitched": stitched,
            "stale_pending": stale_pending,
            "pearls_created": pearls_created,
            "pearls_updated": pearls_updated,
            "pearls_skipped": pearls_skipped,
            "dedup_sensor": dedup_sensor or {},
        },
        "conflicts": [
            {
                "new": c["new"][:3] if isinstance(c.get("new"), (list, tuple)) else str(c.get("new", "")),
                "existing_count": len(c.get("existing", [])),
            }
            for c in diff.get("conflict", [])[:5]  # top 5 conflicts
        ],
        "pearl_details": pearl_details or [],
        "triage_issues": open_triages or [],
        "kg_invalidation": kg_scan or {},
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

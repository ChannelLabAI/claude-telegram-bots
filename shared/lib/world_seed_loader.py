#!/usr/bin/env python3
"""
world_seed_loader.py — Load world-seed.yml into jieba dict + memocean entity_registry.

Replaces /tmp/mempalace/mempalace/onboarding.py (interactive CLI, headless-hostile).

Behaviour:
  1. Locate world-seed.yml (vault canonical > shared/lib fallback).
  2. Parse people / projects / brands / aliases sections.
  3. For each entry (canonical + aliases): jieba.add_word(word, freq, tag).
  4. UPSERT into memocean memory.db entity_registry table.
  5. Idempotent — re-running replaces rows (DELETE by source + INSERT).

Usage:
    # one-off load
    python3 -m world_seed_loader        # from ~/.claude-bots/shared/lib/

    # or as a module
    from world_seed_loader import load_world_seed
    stats = load_world_seed()
    # {"people": 15, "projects": 11, "brands": 5, "aliases_total": 72}

    # inject into a running jieba session (e.g. in han_ner.py)
    from world_seed_loader import apply_to_jieba
    apply_to_jieba()
"""

from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # PyYAML
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


# ─── paths ────────────────────────────────────────────────────────────────────

SHARED_LIB = Path(__file__).resolve().parent
VAULT_SEED = Path.home() / "Documents" / "Obsidian Vault" / "Wiki" / "Concepts" / "world-seed.yml"
SHARED_SEED = SHARED_LIB / "world-seed.yml"

DEFAULT_DB = Path.home() / ".claude-bots" / "memory.db"


# ─── schema ───────────────────────────────────────────────────────────────────

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS entity_registry (
    id           TEXT PRIMARY KEY,           -- "<category>:<entity_id>:<surface>"
    entity_id    TEXT NOT NULL,              -- canonical id from YAML
    category     TEXT NOT NULL,              -- people | projects | brands
    canonical    TEXT NOT NULL,              -- canonical name (displayed)
    surface      TEXT NOT NULL,              -- the actual word (canonical or alias)
    is_alias     INTEGER NOT NULL DEFAULT 0, -- 0 = canonical, 1 = alias
    tag          TEXT NOT NULL,              -- jieba POS tag (nr / nz / ns / nt)
    freq         INTEGER NOT NULL DEFAULT 10000,
    card         TEXT,                       -- optional [[wikilink]]
    note         TEXT,
    source       TEXT NOT NULL DEFAULT 'world-seed.yml',
    updated_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_entity_registry_surface ON entity_registry(surface);
CREATE INDEX IF NOT EXISTS idx_entity_registry_category ON entity_registry(category);
CREATE INDEX IF NOT EXISTS idx_entity_registry_entity_id ON entity_registry(entity_id);
"""


# ─── loading ──────────────────────────────────────────────────────────────────


def find_seed_file(explicit: str | None = None) -> Path:
    """Prefer vault canonical location, fall back to shared/lib."""
    if explicit:
        p = Path(explicit).expanduser()
        if not p.exists():
            raise FileNotFoundError(f"world-seed.yml not found at: {p}")
        return p
    if VAULT_SEED.exists():
        return VAULT_SEED
    if SHARED_SEED.exists():
        return SHARED_SEED
    raise FileNotFoundError(
        f"world-seed.yml not found. Tried:\n  {VAULT_SEED}\n  {SHARED_SEED}"
    )


def parse_seed(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise ValueError(f"world-seed.yml root must be a mapping, got {type(data).__name__}")
    return data


def _iter_entries(data: dict[str, Any]):
    """Yield (category, entry_dict) for each entry in people/projects/brands."""
    for category in ("people", "projects", "brands"):
        for entry in data.get(category) or []:
            if not isinstance(entry, dict):
                continue
            yield category, entry


def expand_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten YAML entries into entity_registry rows (canonical + each alias)."""
    rows: list[dict[str, Any]] = []
    default_freq = 10000

    for category, entry in _iter_entries(data):
        entity_id = str(entry.get("id") or "").strip()
        name = str(entry.get("name") or "").strip()
        if not entity_id or not name:
            continue
        tag = str(entry.get("tag") or ("nr" if category == "people" else "nz"))
        freq = int(entry.get("freq") or default_freq)
        card = entry.get("card")
        note = entry.get("note")

        # canonical
        rows.append({
            "id": f"{category}:{entity_id}:{name}",
            "entity_id": entity_id,
            "category": category,
            "canonical": name,
            "surface": name,
            "is_alias": 0,
            "tag": tag,
            "freq": freq,
            "card": card,
            "note": note,
        })

        # aliases
        for alias in entry.get("aliases") or []:
            alias_s = str(alias).strip()
            if not alias_s or alias_s == name:
                continue
            rows.append({
                "id": f"{category}:{entity_id}:{alias_s}",
                "entity_id": entity_id,
                "category": category,
                "canonical": name,
                "surface": alias_s,
                "is_alias": 1,
                "tag": tag,
                "freq": freq,
                "card": card,
                "note": note,
            })

    # manual alias overrides — map `from` -> existing canonical via `to` (entity_id)
    canonical_by_id: dict[str, dict[str, Any]] = {}
    for category, entry in _iter_entries(data):
        eid = str(entry.get("id") or "").strip()
        if eid:
            canonical_by_id[eid] = {"category": category, "entry": entry}

    for override in data.get("aliases") or []:
        if not isinstance(override, dict):
            continue
        surface = str(override.get("from") or "").strip()
        target_id = str(override.get("to") or "").strip()
        if not surface or not target_id or target_id not in canonical_by_id:
            continue
        ref = canonical_by_id[target_id]
        entry = ref["entry"]
        category = ref["category"]
        name = str(entry.get("name") or "").strip()
        tag = str(entry.get("tag") or ("nr" if category == "people" else "nz"))
        freq = int(entry.get("freq") or default_freq)
        rows.append({
            "id": f"{category}:{target_id}:{surface}",
            "entity_id": target_id,
            "category": category,
            "canonical": name,
            "surface": surface,
            "is_alias": 1,
            "tag": tag,
            "freq": freq,
            "card": entry.get("card"),
            "note": entry.get("note"),
        })

    return rows


# ─── jieba integration ────────────────────────────────────────────────────────


def apply_to_jieba(rows: list[dict[str, Any]] | None = None) -> int:
    """jieba.add_word for every surface form. Returns number of words added."""
    import jieba  # local import so the loader can be used without jieba installed
    import logging
    logging.getLogger("jieba").setLevel(logging.ERROR)

    if rows is None:
        data = parse_seed(find_seed_file())
        rows = expand_rows(data)

    count = 0
    for row in rows:
        try:
            jieba.add_word(row["surface"], freq=int(row["freq"]), tag=row["tag"])
            count += 1
        except Exception as e:  # pragma: no cover
            print(f"jieba.add_word failed for {row['surface']}: {e}", file=sys.stderr)
    return count


# ─── sqlite upsert ────────────────────────────────────────────────────────────


def upsert_rows(rows: list[dict[str, Any]], db_path: Path = DEFAULT_DB, source: str = "world-seed.yml") -> int:
    """
    Idempotent upsert: DELETE WHERE source=? then INSERT all rows.
    This makes re-runs after YAML edits cleanly replace registry state.
    """
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    try:
        conn.executescript(SCHEMA_SQL)
        conn.execute("DELETE FROM entity_registry WHERE source = ?", (source,))
        conn.executemany(
            """
            INSERT OR REPLACE INTO entity_registry
                (id, entity_id, category, canonical, surface, is_alias, tag, freq, card, note, source)
            VALUES
                (:id, :entity_id, :category, :canonical, :surface, :is_alias, :tag, :freq, :card, :note, :source)
            """,
            [{**r, "source": source} for r in rows],
        )
        conn.commit()
    finally:
        conn.close()
    return len(rows)


# ─── top-level API ────────────────────────────────────────────────────────────


def load_world_seed(
    seed_path: str | None = None,
    db_path: Path = DEFAULT_DB,
    apply_jieba: bool = True,
    upsert_db: bool = True,
) -> dict[str, Any]:
    path = find_seed_file(seed_path)
    data = parse_seed(path)
    rows = expand_rows(data)

    stats = {
        "seed_path": str(path),
        "rows": len(rows),
        "people": sum(1 for r in rows if r["category"] == "people"),
        "projects": sum(1 for r in rows if r["category"] == "projects"),
        "brands": sum(1 for r in rows if r["category"] == "brands"),
        "canonical": sum(1 for r in rows if r["is_alias"] == 0),
        "aliases": sum(1 for r in rows if r["is_alias"] == 1),
    }

    if apply_jieba:
        stats["jieba_added"] = apply_to_jieba(rows)
    if upsert_db:
        stats["db_rows_upserted"] = upsert_rows(rows, db_path=db_path)
        stats["db_path"] = str(db_path)

    return stats


# ─── CLI ──────────────────────────────────────────────────────────────────────


def _main(argv: list[str]) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Load world-seed.yml into jieba + memocean")
    ap.add_argument("--seed", help="Path to world-seed.yml (default: auto-detect)")
    ap.add_argument("--db", default=str(DEFAULT_DB), help="SQLite db path")
    ap.add_argument("--no-jieba", action="store_true", help="Skip jieba.add_word step")
    ap.add_argument("--no-db", action="store_true", help="Skip sqlite upsert step")
    args = ap.parse_args(argv)

    stats = load_world_seed(
        seed_path=args.seed,
        db_path=Path(args.db),
        apply_jieba=not args.no_jieba,
        upsert_db=not args.no_db,
    )
    for k, v in stats.items():
        print(f"  {k}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

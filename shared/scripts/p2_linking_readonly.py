#!/usr/bin/env python3
"""
p2_linking_readonly.py — MemOcean P2 連結引擎【唯讀階段】

雙路候選（radar_vec KNN + entity_registry KG fallback）→ Haiku judge →
建議連結清單。⚠️ 全程唯讀：不寫 memory.db / vault / KG / dream_cycle。

Usage:
  python3 p2_linking_readonly.py --dry-run    # 只統計候選，不跑 Haiku
  python3 p2_linking_readonly.py              # 完整跑，輸出 p2-link-suggestions-<date>.json
  python3 p2_linking_readonly.py --output /path/to/out.json
"""
import json
import logging
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

DB_PATH = Path.home() / ".claude-bots" / "memory.db"
OUTPUT_DIR = Path(__file__).parent.parent.parent / "bots" / "anya" / "work"
CONFIDENCE_THRESHOLD = 0.75
KNN_FETCH = 50          # over-fetch from radar_vec, post-filter to Pearl cards
CANDIDATES_PER_CARD = 8 # max candidates per source card (vec + kg merged)

log = logging.getLogger(__name__)


# ── DB helpers ────────────────────────────────────────────────────────────────

def _load_sqlite_vec(conn: sqlite3.Connection) -> bool:
    """Load sqlite-vec extension so radar_vec (vec0) is queryable."""
    try:
        import sqlite_vec
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)
        return True
    except Exception as e:
        log.warning("sqlite_vec unavailable — vec path disabled: %s", e)
        return False


def get_db_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


# ── Candidate engines ─────────────────────────────────────────────────────────

def get_pearl_cards(conn: sqlite3.Connection) -> list[dict]:
    """Return all Pearl cards using drawer_path filter (NOT slug LIKE 'Pearl-%').

    59 Pearl cards use bare-title slugs (e.g. 'CLI-API', 'Cards-AI');
    only 2 have 'Pearl-' prefix in radar_vec — slug filter would miss 57.
    """
    rows = conn.execute(
        "SELECT slug, drawer_path FROM radar WHERE drawer_path LIKE '%珍珠卡%'"
    ).fetchall()
    return [{"slug": r["slug"], "drawer_path": r["drawer_path"]} for r in rows]


def get_vec_candidates(
    conn: sqlite3.Connection,
    slug: str,
    pearl_slugs: set[str],
    top_k: int = CANDIDATES_PER_CARD,
) -> list[str]:
    """KNN search using the card's pre-stored embedding. Post-filter to Pearl slugs."""
    try:
        row = conn.execute(
            "SELECT embedding FROM radar_vec WHERE slug = ?", (slug,)
        ).fetchone()
        if row is None:
            log.debug("vec_candidates: no embedding stored for %s", slug)
            return []
        emb_blob = row["embedding"]
        rows = conn.execute(
            "SELECT slug, distance FROM radar_vec WHERE embedding MATCH ? AND k = ?",
            (emb_blob, KNN_FETCH),
        ).fetchall()
        return [
            r["slug"]
            for r in rows
            if r["slug"] != slug and r["slug"] in pearl_slugs
        ][:top_k]
    except Exception as e:
        log.warning("vec_candidates failed for %s: %s", slug, e)
        return []


def get_kg_candidates(
    conn: sqlite3.Connection,
    slug: str,
    pearl_slugs: set[str],
    top_k: int = 3,
) -> list[str]:
    """Optional KG fallback: shared entities via entity_registry.

    Coverage is narrow (51 canonical, mostly people) — used as supplement only.
    """
    try:
        card_ref = f"[[{slug}]]"
        ents = conn.execute(
            "SELECT canonical FROM entity_registry WHERE card = ? AND is_alias = 0",
            (card_ref,),
        ).fetchall()
        if not ents:
            return []
        candidates: set[str] = set()
        for e in ents:
            rows = conn.execute(
                "SELECT card FROM entity_registry "
                "WHERE canonical = ? AND is_alias = 0 AND card != ?",
                (e["canonical"], card_ref),
            ).fetchall()
            for r in rows:
                m = re.match(r"^\[\[(.+)\]\]$", r["card"])
                if m and m.group(1) in pearl_slugs and m.group(1) != slug:
                    candidates.add(m.group(1))
        return list(candidates)[:top_k]
    except Exception as e:
        log.debug("kg_candidates failed for %s: %s", slug, e)
        return []


# ── Judge layer ───────────────────────────────────────────────────────────────

def parse_judge_response(text: str, slug_a: str, slug_b: str) -> dict:
    """Extract JSON from Haiku reply.

    Haiku often returns ```json fence + explanation text. Strategy:
    1. Try fenced block via regex
    2. Try bare JSON object anywhere in text
    3. Log on failure — NEVER silently swallow as link=false (that was the 0% bug).
    """
    # Try fenced JSON block
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass  # fall through to bare search

    # Try bare JSON object
    m = re.search(r"\{[^{}]*\}", text, re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError as e:
            log.warning(
                "parse_judge_response: JSON decode failed %s↔%s: %s | raw=%.300s",
                slug_a, slug_b, e, text,
            )
    else:
        log.warning(
            "parse_judge_response: no JSON found %s↔%s | raw=%.300s",
            slug_a, slug_b, text,
        )

    return {"link": False, "relation": None, "confidence": 0.0}


def judge_link(
    client,
    content_a: str,
    content_b: str,
    slug_a: str,
    slug_b: str,
) -> dict:
    """Ask Haiku whether two Pearl cards should be linked."""
    prompt = (
        f"You are a knowledge graph linker. Decide if two cards should be linked.\n\n"
        f"Card A ({slug_a}):\n{content_a[:1500]}\n\n"
        f"Card B ({slug_b}):\n{content_b[:1500]}\n\n"
        "Reply with ONLY a single JSON object on one line, no explanation:\n"
        '{"link": true/false, "relation": "延伸|導致|反例|並列|引用|null", "confidence": 0.0-1.0}\n\n'
        "Rules: link=true only for clear conceptual relationship. "
        "Confidence≥0.75 = strong link. '並列' = same-topic only (weakest)."
    )
    resp = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=60,
        messages=[{"role": "user", "content": prompt}],
    )
    raw = resp.content[0].text
    return parse_judge_response(raw, slug_a, slug_b)


def read_card_content(drawer_path: str) -> Optional[str]:
    """Read vault .md full text (not clsc). Returns None if file not found."""
    path = Path(drawer_path)
    if not path.exists():
        log.warning("read_card_content: file not found: %s", drawer_path)
        return None
    return path.read_text(encoding="utf-8")


# ── Main pipeline ─────────────────────────────────────────────────────────────

def run_p2_readonly(dry_run: bool = False) -> dict:
    """Run full P2 read-only pipeline. Returns summary dict."""
    conn = get_db_conn()
    vec_ok = _load_sqlite_vec(conn)

    pearl_cards = get_pearl_cards(conn)
    if not pearl_cards:
        log.error("No Pearl cards found — check drawer_path filter")
        conn.close()
        return {"error": "no_pearl_cards"}

    pearl_slugs = {c["slug"] for c in pearl_cards}
    slug_to_path = {c["slug"]: c["drawer_path"] for c in pearl_cards}
    log.info("Pearl cards: %d | vec available: %s", len(pearl_cards), vec_ok)

    # Build candidate pairs (order-independent dedup via frozenset)
    seen_pairs: set[frozenset] = set()
    pairs: list[tuple[str, str]] = []

    for card in pearl_cards:
        slug = card["slug"]
        vec_cands = get_vec_candidates(conn, slug, pearl_slugs) if vec_ok else []
        kg_cands = get_kg_candidates(conn, slug, pearl_slugs)
        # Merge: vec primary, kg supplement; dedupe preserving order
        merged: list[str] = []
        seen: set[str] = set()
        for c in vec_cands + kg_cands:
            if c not in seen:
                seen.add(c)
                merged.append(c)

        for cand in merged[:CANDIDATES_PER_CARD]:
            pair = frozenset([slug, cand])
            if pair not in seen_pairs:
                seen_pairs.add(pair)
                pairs.append((slug, cand))

    log.info("Candidate pairs: %d", len(pairs))
    conn.close()

    if dry_run:
        return {
            "mode": "dry-run",
            "pearl_count": len(pearl_cards),
            "candidate_pairs": len(pairs),
            "suggestions": [],
        }

    # Judge phase
    import anthropic
    client = anthropic.Anthropic()
    suggestions: list[dict] = []
    judged = 0
    errors = 0

    for slug_a, slug_b in pairs:
        content_a = read_card_content(slug_to_path[slug_a])
        content_b = read_card_content(slug_to_path[slug_b])
        if content_a is None or content_b is None:
            errors += 1
            continue

        result = judge_link(client, content_a, content_b, slug_a, slug_b)
        judged += 1

        if result.get("link") and result.get("confidence", 0.0) >= CONFIDENCE_THRESHOLD:
            suggestions.append({
                "card_a": slug_a,
                "card_b": slug_b,
                "path_a": slug_to_path[slug_a],
                "path_b": slug_to_path[slug_b],
                "relation": result.get("relation"),
                "confidence": result.get("confidence"),
            })

    link_rate = len(suggestions) / judged if judged else 0.0
    return {
        "mode": "full",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "pearl_count": len(pearl_cards),
        "candidate_pairs": len(pairs),
        "judged": judged,
        "errors": errors,
        "suggestions_count": len(suggestions),
        "link_rate": round(link_rate, 3),
        "threshold": CONFIDENCE_THRESHOLD,
        "suggestions": suggestions,
    }


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    import argparse

    parser = argparse.ArgumentParser(description="P2 Linking Engine (read-only)")
    parser.add_argument("--dry-run", action="store_true", help="Skip Haiku calls")
    parser.add_argument("--output", default=None, help="Output JSON path")
    args = parser.parse_args()

    result = run_p2_readonly(dry_run=args.dry_run)

    date_str = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M")
    out_path = (
        Path(args.output)
        if args.output
        else OUTPUT_DIR / f"p2-link-suggestions-{date_str}.json"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n=== P2 Linking Engine (read-only) ===")
    print(f"Pearl cards      : {result.get('pearl_count', '?')}")
    print(f"Candidate pairs  : {result.get('candidate_pairs', '?')}")
    if not args.dry_run and "judged" in result:
        print(f"Judged           : {result['judged']}")
        print(f"Suggestions      : {result['suggestions_count']} (link rate: {result['link_rate']:.1%})")
    print(f"Output           : {out_path}")


if __name__ == "__main__":
    main()

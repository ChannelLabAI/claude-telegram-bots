#!/usr/bin/env python3
"""Benchmark slug updater — fixes stale expected_slugs in work-scenario-200.json.

Round 2: bulk update stale slugs by re-matching query_terms against current radar table.
"""

import json
import sqlite3
import shutil
from pathlib import Path

DB_PATH = "/home/oldrabbit/.claude-bots/memory.db"
BENCHMARK_PATH = "/home/oldrabbit/.claude-bots/benchmarks/work-scenario-200.json"
BACKUP_PATH = "/home/oldrabbit/.claude-bots/benchmarks/work-scenario-200.json.bak-20260414"


def load_radar(db_path: str) -> list[tuple[str, str]]:
    """Load all (slug, clsc) from radar table."""
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("SELECT slug, clsc FROM radar")
    rows = cur.fetchall()
    conn.close()
    return rows


def find_best_slugs(query_terms: str, radar: list[tuple[str, str]], top_n: int = 10) -> list[tuple[str, int]]:
    """OR-match: count how many query terms appear in clsc. Return top_n (slug, count)."""
    terms = query_terms.lower().split()
    terms = [t for t in terms if len(t) > 0]
    if not terms:
        return []

    scored = []
    for slug, clsc in radar:
        clsc_lower = (clsc or "").lower()
        count = sum(1 for t in terms if t in clsc_lower)
        if count > 0:
            scored.append((slug, count))

    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[:top_n]


def main():
    # Load radar
    radar = load_radar(DB_PATH)
    all_slugs = {slug for slug, _ in radar}
    print(f"Radar: {len(radar)} entries, {len(all_slugs)} unique slugs")

    # Backup benchmark
    shutil.copy2(BENCHMARK_PATH, BACKUP_PATH)
    print(f"Backed up to {BACKUP_PATH}")

    # Load benchmark
    with open(BENCHMARK_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    questions = data["questions"]
    seabed_qs = [q for q in questions if q.get("search_api") == "seabed_search"]
    print(f"Total questions: {len(questions)}, seabed: {len(seabed_qs)}")

    # Stats
    full_replace = 0
    partial_replace = 0
    skipped_valid = 0
    skipped_no_match = 0
    zero_match_ids = []

    for q in seabed_qs:
        # Skip no_match_expected questions
        if q.get("no_match_expected"):
            skipped_no_match += 1
            continue

        expected = q.get("expected_slugs", [])
        if not expected:
            continue

        # Check which expected slugs still exist
        valid = [s for s in expected if s in all_slugs]
        stale = [s for s in expected if s not in all_slugs]

        if len(stale) == 0:
            # All valid
            skipped_valid += 1
            continue

        # Find best matching slugs
        matches = find_best_slugs(q["query_terms"], radar, top_n=10)

        if not matches:
            zero_match_ids.append(q["id"])
            continue

        # Pick top 3-5 replacements (excluding already-valid ones)
        valid_set = set(valid)
        replacement_candidates = [slug for slug, _ in matches if slug not in valid_set]

        if len(valid) == 0:
            # ALL stale — full replace with top 3-5
            n_pick = min(5, max(3, len(replacement_candidates)))
            new_slugs = replacement_candidates[:n_pick]
            q["expected_slugs"] = new_slugs
            q["slugs_updated"] = "round2"
            full_replace += 1
        else:
            # SOME stale — keep valid, add replacements for stale count
            n_replace = min(len(stale), len(replacement_candidates))
            new_slugs = valid + replacement_candidates[:n_replace]
            q["expected_slugs"] = new_slugs
            q["slugs_updated"] = "round2-partial"
            partial_replace += 1

    # Write back
    with open(BENCHMARK_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    print(f"\n=== Results ===")
    print(f"Full replace (all stale):    {full_replace}")
    print(f"Partial replace (some stale): {partial_replace}")
    print(f"Skipped (all valid):         {skipped_valid}")
    print(f"Skipped (no_match_expected): {skipped_no_match}")
    print(f"Zero matches (need manual):  {len(zero_match_ids)}")
    if zero_match_ids:
        print(f"  IDs: {zero_match_ids}")
    print(f"\nUpdated JSON written to {BENCHMARK_PATH}")


if __name__ == "__main__":
    main()

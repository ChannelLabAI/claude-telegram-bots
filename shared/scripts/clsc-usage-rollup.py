#!/usr/bin/env python3
"""
clsc-usage-rollup.py — Weekly summary of closet_search / closet_get_verbatim usage.

Usage:
    python3 clsc-usage-rollup.py [--since YYYY-MM-DD] [--json]

Options:
    --since YYYY-MM-DD   Only include entries from this date onward (UTC)
    --json               Output raw JSON instead of human-readable text
"""
import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone


LOG_PATH = os.path.expanduser('~/.claude-bots/logs/clsc-usage.jsonl')


def load_entries(since: str | None) -> list[dict]:
    """Load and optionally filter log entries."""
    if not os.path.exists(LOG_PATH):
        return []

    since_dt = None
    if since:
        since_dt = datetime.fromisoformat(since).replace(tzinfo=timezone.utc)

    entries = []
    with open(LOG_PATH, 'r', encoding='utf-8') as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                print(f"[warn] skipping malformed JSON at line {lineno}", file=sys.stderr)
                continue

            if since_dt:
                ts_str = entry.get('ts', '')
                try:
                    # Support both with and without milliseconds
                    ts_str_clean = ts_str.rstrip('Z')
                    if '.' in ts_str_clean:
                        entry_dt = datetime.fromisoformat(ts_str_clean).replace(tzinfo=timezone.utc)
                    else:
                        entry_dt = datetime.fromisoformat(ts_str_clean).replace(tzinfo=timezone.utc)
                    if entry_dt < since_dt:
                        continue
                except (ValueError, AttributeError):
                    pass  # include entries with unparseable timestamps

            entries.append(entry)

    return entries


def compute_summary(entries: list[dict]) -> dict:
    """Compute overall and per-bot statistics."""
    search_entries = [e for e in entries if e.get('event') == 'closet_search']
    verbatim_entries = [e for e in entries if e.get('event') == 'closet_get_verbatim']

    # Overall stats
    total_queries = len(search_entries)
    total_hits = sum(e.get('hits', 0) for e in search_entries)
    total_skeleton_tokens = sum(e.get('skeleton_tokens', 0) for e in search_entries)
    total_est_verbatim_tokens = sum(e.get('estimated_verbatim_tokens', 0) for e in search_entries)
    total_saved_tokens = sum(e.get('saved_tokens', 0) for e in search_entries)

    overall_saving_pct = (
        round(total_saved_tokens / total_est_verbatim_tokens * 100, 1)
        if total_est_verbatim_tokens > 0 else None
    )
    hit_rate = round(total_hits / total_queries, 2) if total_queries > 0 else None

    # Verbatim fallback rate
    verbatim_count = len(verbatim_entries)
    verbatim_fallback_rate = (
        round(verbatim_count / total_queries * 100, 1) if total_queries > 0 else None
    )

    # Per-bot breakdown
    bots: dict[str, dict] = defaultdict(lambda: {
        'queries': 0, 'hits': 0,
        'skeleton_tokens': 0, 'estimated_verbatim_tokens': 0,
        'saved_tokens': 0, 'verbatim_fetches': 0,
    })

    for e in search_entries:
        bot = e.get('bot', 'unknown')
        bots[bot]['queries'] += 1
        bots[bot]['hits'] += e.get('hits', 0)
        bots[bot]['skeleton_tokens'] += e.get('skeleton_tokens', 0)
        bots[bot]['estimated_verbatim_tokens'] += e.get('estimated_verbatim_tokens', 0)
        bots[bot]['saved_tokens'] += e.get('saved_tokens', 0)

    for e in verbatim_entries:
        bot = e.get('bot', 'unknown')
        bots[bot]['verbatim_fetches'] += 1

    per_bot = {}
    for bot, stats in sorted(bots.items()):
        evt = stats['estimated_verbatim_tokens']
        svd = stats['saved_tokens']
        per_bot[bot] = {
            'queries': stats['queries'],
            'hits': stats['hits'],
            'hit_rate': round(stats['hits'] / stats['queries'], 2) if stats['queries'] > 0 else None,
            'skeleton_tokens': stats['skeleton_tokens'],
            'estimated_verbatim_tokens': evt,
            'saved_tokens': svd,
            'saving_pct': round(svd / evt * 100, 1) if evt > 0 else None,
            'verbatim_fetches': stats['verbatim_fetches'],
        }

    # Top 10 query keywords
    word_counts: dict[str, int] = defaultdict(int)
    for e in search_entries:
        query = e.get('query', '') or ''
        for word in query.split():
            word_lower = word.lower()
            if word_lower:
                word_counts[word_lower] += 1

    top_keywords = sorted(word_counts.items(), key=lambda x: x[1], reverse=True)[:10]

    return {
        'total_queries': total_queries,
        'total_hits': total_hits,
        'hit_rate': hit_rate,
        'total_skeleton_tokens': total_skeleton_tokens,
        'total_estimated_verbatim_tokens': total_est_verbatim_tokens,
        'total_saved_tokens': total_saved_tokens,
        'overall_saving_pct': overall_saving_pct,
        'verbatim_fallback_count': verbatim_count,
        'verbatim_fallback_rate_pct': verbatim_fallback_rate,
        'per_bot': per_bot,
        'top_keywords': [{'word': w, 'count': c} for w, c in top_keywords],
    }


def print_human(summary: dict) -> None:
    """Print human-readable summary."""
    print("=" * 60)
    print("  CLSC Usage Rollup")
    print("=" * 60)

    print(f"\n[Overall]")
    print(f"  Total queries:               {summary['total_queries']}")
    print(f"  Total hits:                  {summary['total_hits']}")
    print(f"  Hit rate (hits/queries):     {summary['hit_rate'] if summary['hit_rate'] is not None else 'N/A'}")
    print(f"  Skeleton tokens served:      {summary['total_skeleton_tokens']:,}")
    print(f"  Est. verbatim tokens:        {summary['total_estimated_verbatim_tokens']:,}")
    print(f"  Saved tokens:                {summary['total_saved_tokens']:,}")
    pct = summary['overall_saving_pct']
    print(f"  Overall saving %:            {pct}%" if pct is not None else "  Overall saving %:            N/A")
    vfr = summary['verbatim_fallback_rate_pct']
    print(f"  Verbatim fallback count:     {summary['verbatim_fallback_count']}")
    print(f"  Verbatim fallback rate:      {vfr}%" if vfr is not None else "  Verbatim fallback rate:      N/A")

    print(f"\n[Per-Bot Breakdown]")
    if not summary['per_bot']:
        print("  (no data)")
    for bot, stats in summary['per_bot'].items():
        print(f"\n  Bot: {bot}")
        print(f"    queries:          {stats['queries']}")
        print(f"    hits:             {stats['hits']}")
        print(f"    hit_rate:         {stats['hit_rate'] if stats['hit_rate'] is not None else 'N/A'}")
        print(f"    skeleton_tokens:  {stats['skeleton_tokens']:,}")
        print(f"    est_verbatim:     {stats['estimated_verbatim_tokens']:,}")
        print(f"    saved_tokens:     {stats['saved_tokens']:,}")
        sp = stats['saving_pct']
        print(f"    saving_pct:       {sp}%" if sp is not None else "    saving_pct:       N/A")
        print(f"    verbatim_fetches: {stats['verbatim_fetches']}")

    print(f"\n[Top 10 Query Keywords]")
    if not summary['top_keywords']:
        print("  (no data)")
    for i, kw in enumerate(summary['top_keywords'], 1):
        print(f"  {i:2d}. {kw['word']:<30} {kw['count']} occurrence(s)")

    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description='Weekly rollup of closet_search / closet_get_verbatim usage.'
    )
    parser.add_argument('--since', metavar='YYYY-MM-DD', default=None,
                        help='Only include entries from this date onward (UTC)')
    parser.add_argument('--json', action='store_true', dest='json_output',
                        help='Output raw JSON instead of human-readable text')
    args = parser.parse_args()

    entries = load_entries(args.since)
    summary = compute_summary(entries)

    if args.json_output:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        if args.since:
            print(f"[Filter: since {args.since}]")
        print_human(summary)


if __name__ == '__main__':
    main()

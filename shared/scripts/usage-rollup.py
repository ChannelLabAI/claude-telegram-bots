#!/usr/bin/env python3
"""
usage-rollup.py — Read-only rollup of logs/usage.jsonl
Outputs: token concentration per bot/model, latency p50/p95, rate_limit events.
D3: proxy metrics for subscription usage / rate-limit risk (NOT real $ spend).

⚠️ approx_cost_usd is API-equivalent concept only — internal subscription = flat fee.
   Real constraint = token concentration (who eats how much of shared quota).
"""
import json, sys, os, statistics, argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone

USAGE_LOG = os.path.expanduser("~/.claude-bots/logs/usage.jsonl")
ALERT_THRESHOLD_PCT = 80.0  # single bot > 80% of fleet tokens = rate-limit risk

def load_entries(days: int = 7) -> list[dict]:
    if not os.path.exists(USAGE_LOG):
        print(f"[rollup] {USAGE_LOG} not found — no data yet", file=sys.stderr)
        return []
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    entries = []
    with open(USAGE_LOG, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if e.get('date', '') >= cutoff:
                    entries.append(e)
            except Exception:
                continue
    return entries

def rollup(entries: list[dict]) -> dict:
    by_bot: dict = defaultdict(lambda: {
        'input': 0, 'output': 0, 'cache_read': 0, 'cache_write': 0,
        'sessions': 0, 'rate_limit': 0, 'latencies': [], 'model': set()
    })

    for e in entries:
        bot = e.get('bot', 'unknown')
        b = by_bot[bot]
        b['input']      += e.get('input_tokens', 0) or 0
        b['output']     += e.get('output_tokens', 0) or 0
        b['cache_read'] += e.get('cache_read_tokens', 0) or 0
        b['cache_write'] += e.get('cache_write_tokens', 0) or 0
        b['sessions']   += 1
        b['rate_limit'] += e.get('rate_limit_events', 0) or 0
        lat_p50 = e.get('latency_ms_p50')
        if lat_p50 is not None:
            b['latencies'].append(lat_p50)
        if model := e.get('model'):
            b['model'].add(model)

    # Fleet totals
    fleet_total_tokens = sum(
        b['input'] + b['output'] for b in by_bot.values()
    )

    result = {
        'fleet_total_tokens': fleet_total_tokens,
        'sessions_total': sum(b['sessions'] for b in by_bot.values()),
        'rate_limit_events_total': sum(b['rate_limit'] for b in by_bot.values()),
        'bots': {},
        'alerts': [],
    }

    for bot, b in sorted(by_bot.items()):
        tokens = b['input'] + b['output']
        pct = (tokens / fleet_total_tokens * 100) if fleet_total_tokens > 0 else 0
        lats = b['latencies']
        result['bots'][bot] = {
            'model': list(b['model']),
            'sessions': b['sessions'],
            'tokens_total': tokens,
            'tokens_pct_fleet': round(pct, 1),
            'rate_limit_events': b['rate_limit'],
            'latency_p50': round(statistics.median(lats), 1) if lats else None,
            'latency_p95': round(sorted(lats)[int(len(lats)*0.95)], 1) if len(lats) >= 2 else None,
        }
        if pct >= ALERT_THRESHOLD_PCT:
            result['alerts'].append(
                f"⚠️ RATE-LIMIT RISK: {bot} consumed {pct:.1f}% of fleet tokens "
                f"(threshold: {ALERT_THRESHOLD_PCT}%) — may exhaust shared quota"
            )

    return result

def main():
    parser = argparse.ArgumentParser(description='usage-rollup: token concentration + latency')
    parser.add_argument('--days', type=int, default=7, help='Days to look back (default: 7)')
    parser.add_argument('--json', action='store_true', help='Output raw JSON')
    args = parser.parse_args()

    entries = load_entries(args.days)
    if not entries:
        print(json.dumps({'error': 'no data', 'usage_log': USAGE_LOG}))
        return

    r = rollup(entries)

    if args.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
        return

    print(f"\n=== Usage Rollup (last {args.days} days) ===")
    print(f"Fleet total tokens: {r['fleet_total_tokens']:,}")
    print(f"Sessions: {r['sessions_total']} | Rate-limit events: {r['rate_limit_events_total']}")
    print()
    print(f"{'Bot':<22} {'Model':<25} {'Sessions':>8} {'Tokens':>10} {'Fleet%':>7} {'P50ms':>7} {'P95ms':>7} {'RL':>4}")
    print("-" * 98)
    for bot, b in sorted(r['bots'].items(), key=lambda x: -x[1]['tokens_total']):
        model = ', '.join(b['model']) or '?'
        p50 = f"{b['latency_p50']:.0f}" if b['latency_p50'] else '-'
        p95 = f"{b['latency_p95']:.0f}" if b['latency_p95'] else '-'
        print(f"{bot:<22} {model:<25} {b['sessions']:>8} {b['tokens_total']:>10,} "
              f"{b['tokens_pct_fleet']:>6.1f}% {p50:>7} {p95:>7} {b['rate_limit_events']:>4}")

    if r['alerts']:
        print()
        for a in r['alerts']:
            print(a)

if __name__ == '__main__':
    main()

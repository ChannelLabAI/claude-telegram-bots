#!/usr/bin/env bash
# gbrain-divergence-report.sh — AC7: Generate Markdown divergence report
# from divergence-log-{date}.jsonl files.
#
# Reports: top-1 agreement rate, top-3/top-5 Jaccard medians, breaking cases,
# top-10 worst divergence examples.
#
# Usage:
#   bash gbrain-divergence-report.sh [--log-dir /path] [--days N] [--output file.md]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/benchmarks"
DAYS=7
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

python3 - <<PYEOF
import glob
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOG_DIR = "${LOG_DIR}"
DAYS = int("${DAYS}")
OUTPUT_FILE = "${OUTPUT_FILE}"

# Thresholds from spec §9 AC7
TOP1_AGREEMENT_GATE = 0.60
TOP3_JACCARD_GATE = 0.30

# Collect log files from past N days
cutoff = datetime.now(timezone.utc) - timedelta(days=DAYS)
entries = []
for log_path in sorted(glob.glob(os.path.join(LOG_DIR, "divergence-log-*.jsonl"))):
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
                if ts >= cutoff:
                    entries.append(entry)
            except Exception:
                pass

total = len(entries)
if total == 0:
    report = f"# GBrain Divergence Report\n\nNo divergence log entries found in the past {DAYS} days.\n"
else:
    top1_agreements = [e["top1_agreement"] for e in entries]
    top3_jaccards = [e["top3_jaccard"] for e in entries]
    top5_jaccards = [e["top5_jaccard"] for e in entries]
    gb_empty_cases = [e for e in entries if e.get("gbrain_empty")]

    top1_rate = sum(top1_agreements) / total
    top3_median = sorted(top3_jaccards)[total // 2]
    top5_median = sorted(top5_jaccards)[total // 2]

    # Breaking cases: GBrain empty AND BM25 has results
    breaking = [e for e in gb_empty_cases if e.get("bm25_top5")]

    # Top-10 worst divergence by lowest top5_jaccard
    worst = sorted(entries, key=lambda e: e["top5_jaccard"])[:10]

    top1_status = "✅ PASS" if top1_rate >= TOP1_AGREEMENT_GATE else "❌ FAIL"
    top3_status = "✅ PASS" if top3_median >= TOP3_JACCARD_GATE else "❌ FAIL"
    breaking_status = "✅ PASS" if len(breaking) == 0 else f"❌ FAIL ({len(breaking)} cases)"

    lines = [
        "# GBrain × BM25 Divergence Report",
        "",
        f"> Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S UTC')}  ",
        f"> Period: last {DAYS} days  ",
        f"> Total queries analysed: {total}",
        "",
        "## Summary",
        "",
        f"| Metric | Value | Gate | Status |",
        f"|---|---|---|---|",
        f"| Top-1 agreement | {top1_rate:.1%} | ≥ 60% | {top1_status} |",
        f"| Top-3 Jaccard (median) | {top3_median:.3f} | ≥ 0.30 | {top3_status} |",
        f"| Top-5 Jaccard (median) | {top5_median:.3f} | — | — |",
        f"| Breaking cases (GBrain∅ + BM25 hit) | {len(breaking)} | 0 | {breaking_status} |",
        "",
    ]

    if breaking:
        lines += [
            "## Breaking Cases",
            "",
            "GBrain returned empty results while BM25 found relevant content:",
            "",
        ]
        for e in breaking[:5]:
            lines.append(f"- `{e['query']}` — BM25 top1: `{e['bm25_top5'][0] if e['bm25_top5'] else 'n/a'}`")
        lines.append("")

    lines += [
        "## Top-10 Worst Divergence",
        "",
        "| Query | Top-5 Jaccard | GBrain top1 | BM25 top1 | Latency G/B ms |",
        "|---|---|---|---|---|",
    ]
    for e in worst:
        gb1 = e["gbrain_top5"][0] if e["gbrain_top5"] else "EMPTY"
        bm1 = e["bm25_top5"][0] if e["bm25_top5"] else "EMPTY"
        q = e["query"][:50].replace("|", "\\|")
        lines.append(
            f"| {q} | {e['top5_jaccard']:.3f} | `{gb1[:40]}` | `{bm1[:40]}` | {e['latency_gbrain_ms']}/{e['latency_bm25_ms']} |"
        )
    lines.append("")

    report = "\n".join(lines)

if OUTPUT_FILE:
    with open(OUTPUT_FILE, "w") as f:
        f.write(report)
    print(f"Report written to {OUTPUT_FILE}")
else:
    print(report)

# Exit code 1 if any gate fails
if total > 0:
    if top1_rate < TOP1_AGREEMENT_GATE or top3_median < TOP3_JACCARD_GATE or len(breaking) > 0:
        sys.exit(1)
PYEOF

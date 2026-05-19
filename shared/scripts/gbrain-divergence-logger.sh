#!/usr/bin/env bash
# gbrain-divergence-logger.sh — AC7 dual-log: run a query against both GBrain
# and BM25 and append a divergence-log-schema.json entry to the daily JSONL.
#
# Called at Stage 1.3 for every ocean_search query (via MemOcean MCP hook or
# standalone testing).
#
# Usage:
#   bash gbrain-divergence-logger.sh --query "some search terms"
#   bash gbrain-divergence-logger.sh --query "terms" --source "live" --log-dir /path/to/dir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GBRAIN="${HOME}/.bun/bin/gbrain"
MEMOCEAN_MCP_DIR="${REPO_ROOT}/shared/memocean-mcp"
LOG_DIR="${REPO_ROOT}/benchmarks"
SOURCE_TAG="live"
LIMIT=5
QUERY=""

# ── Arg parsing ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --source) SOURCE_TAG="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${QUERY}" ]]; then
  echo "ERROR: --query is required" >&2
  exit 1
fi

DATE=$(date -u +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/divergence-log-${DATE}.jsonl"
mkdir -p "${LOG_DIR}"

# ── Dual query (Python) ──────────────────────────────────────────────────────

python3 - <<PYEOF
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

GBRAIN = "${GBRAIN}"
MEMOCEAN_MCP_DIR = "${MEMOCEAN_MCP_DIR}"
QUERY = ${QUERY@Q}
LIMIT = int("${LIMIT}")
SOURCE = "${SOURCE_TAG}"
LOG_FILE = "${LOG_FILE}"

def jaccard(a, b):
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    return len(sa & sb) / len(sa | sb) if (sa | sb) else 0.0

def parse_gbrain_output(stdout):
    """Parse multi-line gbrain output, deduplicate slugs."""
    results = []
    current = None
    header_re = re.compile(r'^\[([0-9.]+)\]\s+(\S+)\s+--\s*(.*)')
    for line in stdout.splitlines():
        m = header_re.match(line)
        if m:
            if current:
                results.append(current)
            current = {"slug": m.group(2), "score": float(m.group(1))}
        # continuation lines ignored for divergence (slug is enough)
    if current:
        results.append(current)
    seen = set()
    deduped = []
    for r in results:
        if r["slug"] not in seen:
            seen.add(r["slug"])
            deduped.append(r)
    return deduped

def run_gbrain(query, limit):
    t0 = time.time()
    try:
        r = subprocess.run([GBRAIN, "query", query, "--limit", str(limit)],
                           capture_output=True, text=True, timeout=10.0, check=False)
        ms = int((time.time() - t0) * 1000)
        if r.returncode != 0:
            return [], ms
        return parse_gbrain_output(r.stdout), ms
    except subprocess.TimeoutExpired:
        return [], int((time.time() - t0) * 1000)
    except Exception:
        return [], int((time.time() - t0) * 1000)

def run_bm25(query, limit):
    env = os.environ.copy()
    env["MEMOCEAN_USE_GBRAIN"] = "false"
    t0 = time.time()
    try:
        r = subprocess.run(
            [sys.executable, "-c", f"""
import sys; sys.path.insert(0, '{MEMOCEAN_MCP_DIR}')
from memocean_mcp.tools.ocean_search import _legacy_bm25_search
import json
results = _legacy_bm25_search({json.dumps(query)}, {limit})
print(json.dumps([{{"slug": x.get("slug",""), "score": x.get("score",0)}} for x in results]))
"""],
            capture_output=True, text=True, timeout=15.0, env=env, check=False,
        )
        ms = int((time.time() - t0) * 1000)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout.strip()), ms
        return [], ms
    except Exception:
        return [], int((time.time() - t0) * 1000)

gb_results, gb_ms = run_gbrain(QUERY, LIMIT)
bm_results, bm_ms = run_bm25(QUERY, LIMIT)

gb_slugs = [r["slug"] for r in gb_results[:5]]
bm_slugs = [r["slug"] for r in bm_results[:5]]

entry = {
    "query": QUERY,
    "ts": datetime.now(timezone.utc).isoformat(),
    "gbrain_top5": gb_slugs,
    "bm25_top5": bm_slugs,
    "top1_agreement": (gb_slugs[0] == bm_slugs[0]) if (gb_slugs and bm_slugs) else False,
    "top3_jaccard": jaccard(gb_slugs[:3], bm_slugs[:3]),
    "top5_jaccard": jaccard(gb_slugs[:5], bm_slugs[:5]),
    "latency_gbrain_ms": gb_ms,
    "latency_bm25_ms": bm_ms,
    "gbrain_empty": len(gb_slugs) == 0,
    "source": SOURCE,
}

with open(LOG_FILE, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

print(f"Logged to {LOG_FILE}")
print(f"  GBrain top1: {gb_slugs[0] if gb_slugs else 'EMPTY'} ({gb_ms}ms)")
print(f"  BM25   top1: {bm_slugs[0] if bm_slugs else 'EMPTY'} ({bm_ms}ms)")
print(f"  Top-1 agreement: {entry['top1_agreement']}")
print(f"  Top-5 Jaccard:   {entry['top5_jaccard']:.3f}")
PYEOF

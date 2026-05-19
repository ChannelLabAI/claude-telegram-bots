#!/usr/bin/env bash
# gbrain-benchmark-runner.sh — AC5: Hit@5 benchmark against internal-200-gold.json.
#
# Runs both MemOcean BM25 and GBrain delegate paths, computes Hit@5,
# and writes results to benchmarks/results-phase1-{timestamp}.json.
#
# Hit@5 scoring (Strict): ≥2 gold keywords must appear in top-5 result content.
# Gate: GBrain Hit@5 ≥ 90.9% (baseline 92.9% − 2pp tolerance).
#
# Usage:
#   bash gbrain-benchmark-runner.sh [--gold /path/to/gold.json] [--limit N]
#   bash gbrain-benchmark-runner.sh --gbrain-only   # skip BM25
#   bash gbrain-benchmark-runner.sh --bm25-only     # skip GBrain

set -euo pipefail

# Load LLM API keys so gbrain subprocesses can use OpenAI/Gemini embeddings
KEYS_FILE="${HOME}/.claude-bots/shared/secrets/llm-keys.env"
if [[ -f "${KEYS_FILE}" ]]; then
  # shellcheck source=/dev/null
  set +u; source "${KEYS_FILE}"; set -u
  export OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_API_KEY 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GBRAIN="${HOME}/.bun/bin/gbrain"
GOLD_FILE="${REPO_ROOT}/benchmarks/internal-200-gold.json"
RESULTS_DIR="${REPO_ROOT}/benchmarks"
MEMOCEAN_MCP_DIR="${REPO_ROOT}/shared/memocean-mcp"
HIT5_GATE="90.9"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUTPUT_FILE="${RESULTS_DIR}/results-phase1-${TIMESTAMP}.json"

# ── Arg parsing ──────────────────────────────────────────────────────────────

RUN_GBRAIN=true
RUN_BM25=true
LIMIT=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gold) GOLD_FILE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --gbrain-only) RUN_BM25=false; shift ;;
    --bm25-only) RUN_GBRAIN=false; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Pre-flight ───────────────────────────────────────────────────────────────

echo "=== GBrain × MemOcean Hit@5 Benchmark ==="
echo "Gold file: ${GOLD_FILE}"
echo "Output:    ${OUTPUT_FILE}"
echo ""

if [[ ! -f "${GOLD_FILE}" ]]; then
  echo "ERROR: gold file not found: ${GOLD_FILE}" >&2
  exit 1
fi

if $RUN_GBRAIN && [[ ! -x "${GBRAIN}" ]]; then
  echo "ERROR: gbrain not found at ${GBRAIN}" >&2
  exit 1
fi

# ── Scoring helper (Python) ──────────────────────────────────────────────────

python3 - <<PYEOF
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

GOLD_FILE = "${GOLD_FILE}"
OUTPUT_FILE = "${OUTPUT_FILE}"
GBRAIN = "${GBRAIN}"
MEMOCEAN_MCP_DIR = "${MEMOCEAN_MCP_DIR}"
LIMIT = int("${LIMIT}")
RUN_GBRAIN = "${RUN_GBRAIN}" == "true"
RUN_BM25 = "${RUN_BM25}" == "true"
HIT5_GATE = float("${HIT5_GATE}")

with open(GOLD_FILE) as f:
    gold_data = json.load(f)

questions = gold_data["questions"]
print(f"Loaded {len(questions)} questions from gold file")
print()

def keywords_from_titles(expected_titles):
    """Extract searchable keywords from expected_titles list."""
    keywords = set()
    for title in expected_titles:
        # Split on common delimiters, lowercase
        parts = re.split(r'[-_\s]+', title.lower())
        keywords.update(p for p in parts if len(p) > 2)
    return keywords

def score_hit5(results, expected_titles, query_terms):
    """
    Strict Hit@5: ≥2 gold keywords must appear in combined top-5 content.
    Returns True if hit, False otherwise.
    """
    if not results:
        return False
    gold_kw = keywords_from_titles(expected_titles)
    # Also include query terms as secondary signal
    query_kw = set(re.split(r'\s+', query_terms.lower()))
    all_kw = gold_kw | query_kw

    top5_content = " ".join(
        (r.get("content") or r.get("excerpt") or r.get("title") or "").lower()
        for r in results[:5]
    )
    top5_slugs = " ".join(
        (r.get("slug") or r.get("wikilink") or "").lower()
        for r in results[:5]
    )
    combined = top5_content + " " + top5_slugs

    hits = sum(1 for kw in gold_kw if kw in combined)
    return hits >= 2

def parse_gbrain_multiline(stdout):
    """
    Parse gbrain query output which can be multi-line per result.
    Format: [score] slug -- first-line-content
            continuation-lines...
    [score] next-slug -- content
    """
    results = []
    current = None
    header_re = re.compile(r'^\[([0-9.]+)\]\s+(\S+)\s+--\s*(.*)')
    for line in stdout.splitlines():
        m = header_re.match(line)
        if m:
            if current:
                results.append(current)
            current = {
                "slug": m.group(2),
                "content": m.group(3),
                "score": float(m.group(1)),
                "path": m.group(2),
                "source": "gbrain",
            }
        elif current and line.strip():
            current["content"] += " " + line.strip()
    if current:
        results.append(current)
    # Deduplicate by slug, keeping first occurrence (highest score first from gbrain)
    seen = set()
    deduped = []
    for r in results:
        if r["slug"] not in seen:
            seen.add(r["slug"])
            deduped.append(r)
    return deduped

def run_gbrain_query(query, limit):
    """Call gbrain CLI, parse plain-text output (handles multi-line chunks)."""
    try:
        result = subprocess.run(
            [GBRAIN, "query", query, "--limit", str(limit)],
            capture_output=True, text=True, timeout=30.0, check=False,
        )
        if result.returncode != 0:
            return [], "exit_nonzero"
        if not result.stdout.strip() or result.stdout.strip() == "No results.":
            return [], "ok"
        parsed = parse_gbrain_multiline(result.stdout)
        return parsed, "ok"
    except subprocess.TimeoutExpired:
        return [], "timeout"
    except Exception as e:
        return [], f"error:{e}"

def run_bm25_query(query, limit):
    """Use MemOcean BM25 directly (env: MEMOCEAN_USE_GBRAIN=false)."""
    env = os.environ.copy()
    env["MEMOCEAN_USE_GBRAIN"] = "false"
    env["PYTHONPATH"] = MEMOCEAN_MCP_DIR
    try:
        result = subprocess.run(
            [sys.executable, "-c", f"""
import sys; sys.path.insert(0, '{MEMOCEAN_MCP_DIR}')
from memocean_mcp.tools.ocean_search import _legacy_bm25_search
import json
results = _legacy_bm25_search({json.dumps(query)}, {limit})
print(json.dumps(results))
"""],
            capture_output=True, text=True, timeout=15.0, env=env, check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip()), "ok"
        return [], "error"
    except Exception as e:
        return [], f"error:{e}"

gbrain_hits = 0
bm25_hits = 0
total = len(questions)
results_log = []

for i, q in enumerate(questions):
    qid = q["id"]
    query = q.get("query_terms") or q["question"]
    expected = q.get("expected_titles", [])
    query_terms = q.get("query_terms", "")

    row = {"id": qid, "question": q["question"], "query": query, "expected_titles": expected}

    if RUN_GBRAIN:
        t0 = time.time()
        gb_results, gb_status = run_gbrain_query(query, LIMIT)
        gb_ms = int((time.time() - t0) * 1000)
        gb_hit = score_hit5(gb_results, expected, query_terms)
        if gb_hit:
            gbrain_hits += 1
        row["gbrain"] = {
            "status": gb_status,
            "latency_ms": gb_ms,
            "hit5": gb_hit,
            "top3_slugs": [r.get("slug","") for r in gb_results[:3]],
        }

    if RUN_BM25:
        t0 = time.time()
        bm_results, bm_status = run_bm25_query(query, LIMIT)
        bm_ms = int((time.time() - t0) * 1000)
        bm_hit = score_hit5(bm_results, expected, query_terms)
        if bm_hit:
            bm25_hits += 1
        row["bm25"] = {
            "status": bm_status,
            "latency_ms": bm_ms,
            "hit5": bm_hit,
            "top3_slugs": [r.get("slug","") for r in bm_results[:3]],
        }

    results_log.append(row)

    # Progress every 20
    if (i + 1) % 20 == 0:
        print(f"  {i+1}/{total} done...")

print()

gbrain_pct = (gbrain_hits / total * 100) if RUN_GBRAIN else None
bm25_pct = (bm25_hits / total * 100) if RUN_BM25 else None
gbrain_pass = (gbrain_pct is not None and gbrain_pct >= HIT5_GATE)

summary = {
    "meta": {
        "timestamp": "${TIMESTAMP}",
        "gold_file": GOLD_FILE,
        "question_count": total,
        "hit5_gate": HIT5_GATE,
        "scoring": "strict: >=2 gold keywords in top-5 content",
    },
    "gbrain": {"hit5_count": gbrain_hits, "hit5_pct": gbrain_pct, "pass": gbrain_pass} if RUN_GBRAIN else None,
    "bm25": {"hit5_count": bm25_hits, "hit5_pct": bm25_pct} if RUN_BM25 else None,
    "questions": results_log,
}

with open(OUTPUT_FILE, "w") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)

print("=== Benchmark Results ===")
if RUN_BM25:
    print(f"BM25 Hit@5:   {bm25_pct:.1f}% ({bm25_hits}/{total})")
if RUN_GBRAIN:
    status = "PASS" if gbrain_pass else "FAIL"
    print(f"GBrain Hit@5: {gbrain_pct:.1f}% ({gbrain_hits}/{total})  [{status}] (gate: {HIT5_GATE}%)")
print()
print(f"Results written to: {OUTPUT_FILE}")

if RUN_GBRAIN and not gbrain_pass:
    print()
    print(f"GATE FAIL: GBrain Hit@5 {gbrain_pct:.1f}% < {HIT5_GATE}%")
    sys.exit(1)
PYEOF

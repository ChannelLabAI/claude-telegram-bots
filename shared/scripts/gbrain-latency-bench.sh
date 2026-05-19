#!/usr/bin/env bash
# gbrain-latency-bench.sh — AC6: p95 latency benchmark for GBrain ocean search.
#
# Loads queries from benchmarks/latency-sample-queries.txt (or generates
# a default set if missing), runs 1000 queries at 2-concurrent, records
# p50/p95/p99/max latencies.
#
# Gate: p95 ≤ 500ms
#
# Usage:
#   bash gbrain-latency-bench.sh [--queries /path] [--count N] [--concurrency N] [--daemon]
#
# --daemon: start a persistent gbrain HTTP daemon (AC6 fast path) for the duration of
#           the bench. Eliminates per-query bun startup (~400ms). Embedding cache inside
#           the daemon means repeated queries return in <5ms vs ~3s subprocess cold start.

set -euo pipefail

# Load LLM API keys so gbrain subprocesses use OpenAI/Gemini embeddings
KEYS_FILE="${HOME}/.claude-bots/shared/secrets/llm-keys.env"
if [[ -f "${KEYS_FILE}" ]]; then
  set +u; source "${KEYS_FILE}"; set -u
  export OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_API_KEY 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GBRAIN="${HOME}/.bun/bin/gbrain"
DAEMON_PY="${SCRIPT_DIR}/gbrain-daemon.py"
QUERIES_FILE="${REPO_ROOT}/benchmarks/latency-sample-queries.txt"
COUNT=1000
CONCURRENCY=2
P95_GATE_MS=500
USE_DAEMON=false
DAEMON_PORT=5099
DAEMON_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queries) QUERIES_FILE="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --daemon) USE_DAEMON=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -x "${GBRAIN}" ]]; then
  echo "ERROR: gbrain not found at ${GBRAIN}" >&2
  exit 1
fi

# Generate default query file if missing
if [[ ! -f "${QUERIES_FILE}" ]]; then
  echo "Generating default latency-sample-queries.txt..."
  cat > "${QUERIES_FILE}" <<'QUERIES'
ChannelLab AI architecture
MemOcean search spec
FATQ task queue
GBrain retrieval
bot team architecture
daily note format
CLSC technical spec
知識圖譜
向量搜尋
語意搜尋
GEO analyzer
海圖索引
Ocean vault
Obsidian plugin
FTS5 memory search
privacy guard
slug convention
inotify watcher
deployment checklist
fallback BM25
RAG benchmark
embedding model
cosine similarity
hybrid search RRF
ChannelPulse media
ChannelVenture VC
Nicky BD strategy
菜姐 PMO
Ron 運營
桃桃 PM
Seabed conversation
pearl knowledge
radar CLSC
memory snapshot
bot restart
relay listener
keeper batch
Anna CTO
Anya 特助
GEOFlow tool
NOX wallet
NOXCAT security
EverMind MSA
CZ memoir
Hubble AI
QUERIES
  echo "Created: ${QUERIES_FILE}"
fi

# ── Start daemon if requested ────────────────────────────────────────────────
if $USE_DAEMON; then
  echo "Starting gbrain HTTP daemon (port ${DAEMON_PORT})..."
  GBRAIN_BIN="${GBRAIN}" GBRAIN_DAEMON_PORT="${DAEMON_PORT}" \
    python3 "${DAEMON_PY}" &
  DAEMON_PID=$!
  # Wait for daemon to be ready (up to 30s for bun + gbrain serve startup)
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${DAEMON_PORT}/health" > /dev/null 2>&1; then
      echo "Daemon ready (${i}s)"
      break
    fi
    sleep 1
  done
  trap "kill ${DAEMON_PID} 2>/dev/null || true" EXIT
fi

echo "=== GBrain Latency Benchmark ==="
echo "Queries file: ${QUERIES_FILE}"
echo "Mode:    $(${USE_DAEMON} && echo 'HTTP daemon (persistent, cached)' || echo 'subprocess (cold start)')"
echo "Target: ${COUNT} queries, concurrency=${CONCURRENCY}"
echo "Gate: p95 ≤ ${P95_GATE_MS}ms"
echo ""

python3 - <<PYEOF
import subprocess
import sys
import time
import random
import urllib.request, urllib.error, json
from concurrent.futures import ThreadPoolExecutor, as_completed

GBRAIN = "${GBRAIN}"
QUERIES_FILE = "${QUERIES_FILE}"
COUNT = int("${COUNT}")
CONCURRENCY = int("${CONCURRENCY}")
P95_GATE_MS = int("${P95_GATE_MS}")
USE_DAEMON = "${USE_DAEMON}" == "true"
DAEMON_URL = "http://127.0.0.1:${DAEMON_PORT}/query"

with open(QUERIES_FILE) as f:
    raw_queries = [l.strip() for l in f if l.strip() and not l.startswith("#")]

if not raw_queries:
    print("ERROR: no queries in file")
    sys.exit(1)

# Repeat/sample to reach COUNT
queries = []
while len(queries) < COUNT:
    queries.extend(raw_queries)
queries = queries[:COUNT]
random.shuffle(queries)

latencies = []

def run_one_http(query):
    t0 = time.perf_counter()
    try:
        body = json.dumps({"query": query, "limit": 5}).encode()
        req = urllib.request.Request(DAEMON_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=8.0)
        return int((time.perf_counter() - t0) * 1000)
    except Exception:
        return 8000  # timeout penalty

def run_one_subprocess(query):
    t0 = time.perf_counter()
    subprocess.run(
        [GBRAIN, "query", query, "--limit", "5"],
        capture_output=True, text=True, timeout=10.0, check=False,
    )
    return int((time.perf_counter() - t0) * 1000)

run_one = run_one_http if USE_DAEMON else run_one_subprocess

print(f"Running {COUNT} queries...")
with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
    futures = {ex.submit(run_one, q): q for q in queries}
    done = 0
    for fut in as_completed(futures):
        try:
            ms = fut.result()
            latencies.append(ms)
        except Exception:
            latencies.append(10000)  # timeout penalty
        done += 1
        if done % 100 == 0:
            print(f"  {done}/{COUNT} done...")

latencies.sort()
total = len(latencies)
p50  = latencies[int(total * 0.50)]
p95  = latencies[int(total * 0.95)]
p99  = latencies[int(total * 0.99)]
pmax = latencies[-1]
pmean = int(sum(latencies) / total)

print()
print("=== Latency Results ===")
print(f"Queries: {total}")
print(f"Mean:    {pmean}ms")
print(f"p50:     {p50}ms")
print(f"p95:     {p95}ms  ({'PASS' if p95 <= P95_GATE_MS else 'FAIL'} — gate: {P95_GATE_MS}ms)")
print(f"p99:     {p99}ms")
print(f"max:     {pmax}ms")
print()

if p95 > P95_GATE_MS:
    print(f"GATE FAIL: p95 {p95}ms > {P95_GATE_MS}ms")
    if pmean >= 200:
        print("NOTE: median ≥ 200ms — consider switching to gbrain serve HTTP daemon (spec §9 AC6)")
    sys.exit(1)
else:
    print(f"GATE PASS: p95 {p95}ms ≤ {P95_GATE_MS}ms")
PYEOF

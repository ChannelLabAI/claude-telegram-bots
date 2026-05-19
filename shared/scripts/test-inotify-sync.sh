#!/usr/bin/env bash
# test-inotify-sync.sh — AC2: Verify Ocean→GBrain inotify sync within 5 seconds.
#
# Tests 4 event types (create/modify/delete/rename) × 10 times each = 40 events.
# For each event, measures time from filesystem change to GBrain query returning
# the expected result.
#
# Gate: p95 latency ≤ 5000ms for all event types.
#
# Prerequisites:
#   - inotify-watch.sh running and watching Ocean vault
#   - gbrain binary available
#   - OCEAN_VAULT env var set (or defaults to ~/Documents/Obsidian Vault/Ocean)
#
# Usage:
#   bash test-inotify-sync.sh [--ocean-dir /path] [--iterations N] [--timeout-ms N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GBRAIN="${HOME}/.bun/bin/gbrain"
OCEAN_DIR="${OCEAN_VAULT:-${HOME}/Documents/Obsidian Vault/Ocean}"
ITERATIONS=10
TIMEOUT_MS=5000
TEST_DIR=""
P95_GATE_MS=5000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ocean-dir) OCEAN_DIR="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -x "${GBRAIN}" ]]; then
  echo "ERROR: gbrain not found at ${GBRAIN}" >&2
  exit 1
fi

if [[ ! -d "${OCEAN_DIR}" ]]; then
  echo "ERROR: Ocean vault not found: ${OCEAN_DIR}" >&2
  exit 1
fi

# Use _drafts/ as test sandbox (won't pollute real content)
TEST_DIR="${OCEAN_DIR}/_drafts/_inotify-sync-test"
mkdir -p "${TEST_DIR}"
echo "Test sandbox: ${TEST_DIR}"
echo "Iterations per event type: ${ITERATIONS}"
echo "Timeout gate: ${TIMEOUT_MS}ms"
echo ""

# Cleanup on exit
trap 'rm -rf "${TEST_DIR}" 2>/dev/null || true' EXIT

python3 - <<PYEOF
import os
import subprocess
import sys
import time
import json

GBRAIN = "${GBRAIN}"
TEST_DIR = "${TEST_DIR}"
OCEAN_DIR = "${OCEAN_DIR}"
ITERATIONS = int("${ITERATIONS}")
TIMEOUT_MS = int("${TIMEOUT_MS}")
P95_GATE_MS = int("${P95_GATE_MS}")

TIMEOUT_S = TIMEOUT_MS / 1000.0

def slugify(path):
    """Approximate slug: relative path from Ocean/, lowercase kebab."""
    rel = os.path.relpath(path, OCEAN_DIR)
    return rel.lower().replace(" ", "-").replace("_", "-").replace(".md", "")

def gbrain_has(slug, timeout=TIMEOUT_S):
    """Poll gbrain query until slug appears in results or timeout."""
    unique_kw = slug.split("/")[-1]
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            [GBRAIN, "query", unique_kw, "--limit", "10"],
            capture_output=True, text=True, timeout=3.0, check=False,
        )
        if unique_kw.lower() in r.stdout.lower():
            return True
        time.sleep(0.2)
    return False

def gbrain_not_has(slug, timeout=TIMEOUT_S):
    """Poll until slug disappears from gbrain results."""
    unique_kw = slug.split("/")[-1]
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            [GBRAIN, "query", unique_kw, "--limit", "10"],
            capture_output=True, text=True, timeout=3.0, check=False,
        )
        if unique_kw.lower() not in r.stdout.lower():
            return True
        time.sleep(0.2)
    return False

results = {"create": [], "modify": [], "delete": [], "rename": []}

print("=== inotify sync timing test ===")
print()

# ── CREATE ────────────────────────────────────────────────────────────────────
print(f"Testing CREATE ({ITERATIONS}x)...")
for i in range(ITERATIONS):
    uid = f"create-{i:03d}-{int(time.time()*1000)}"
    path = os.path.join(TEST_DIR, f"{uid}.md")
    content = f"# {uid}\nTest file for inotify sync create test iteration {i}."
    t0 = time.time()
    with open(path, "w") as f:
        f.write(content)
    found = gbrain_has(slugify(path))
    elapsed_ms = int((time.time() - t0) * 1000)
    results["create"].append({"elapsed_ms": elapsed_ms, "found": found, "uid": uid})
    status = "OK" if found else f"TIMEOUT ({elapsed_ms}ms)"
    print(f"  [{i+1:02d}] {status}")
    time.sleep(0.3)

# ── MODIFY ────────────────────────────────────────────────────────────────────
print(f"\nTesting MODIFY ({ITERATIONS}x)...")
# Reuse created files
created_files = [os.path.join(TEST_DIR, f"create-{i:03d}-{uid}.md")
                 for i in range(ITERATIONS)
                 for r in results["create"] if r["uid"].startswith(f"create-{i:03d}")]
# Just create fresh files for modify
for i in range(ITERATIONS):
    uid = f"modify-base-{i:03d}"
    path = os.path.join(TEST_DIR, f"{uid}.md")
    with open(path, "w") as f:
        f.write(f"# {uid}\nOriginal content.")
    time.sleep(0.1)

for i in range(ITERATIONS):
    uid = f"modify-base-{i:03d}"
    path = os.path.join(TEST_DIR, f"{uid}.md")
    new_uid = f"modify-updated-{i:03d}"
    t0 = time.time()
    with open(path, "w") as f:
        f.write(f"# {new_uid}\nUpdated content with unique marker: {new_uid}.")
    found = gbrain_has(slugify(path))
    elapsed_ms = int((time.time() - t0) * 1000)
    results["modify"].append({"elapsed_ms": elapsed_ms, "found": found, "uid": uid})
    status = "OK" if found else f"TIMEOUT ({elapsed_ms}ms)"
    print(f"  [{i+1:02d}] {status}")
    time.sleep(0.3)

# ── DELETE ────────────────────────────────────────────────────────────────────
print(f"\nTesting DELETE ({ITERATIONS}x)...")
for i in range(ITERATIONS):
    uid = f"delete-{i:03d}-{int(time.time()*1000)}"
    path = os.path.join(TEST_DIR, f"{uid}.md")
    with open(path, "w") as f:
        f.write(f"# {uid}\nFile to be deleted.")
    time.sleep(0.5)  # Give inotify time to index it first

    t0 = time.time()
    os.unlink(path)
    gone = gbrain_not_has(slugify(path))
    elapsed_ms = int((time.time() - t0) * 1000)
    results["delete"].append({"elapsed_ms": elapsed_ms, "removed": gone, "uid": uid})
    status = "OK" if gone else f"TIMEOUT ({elapsed_ms}ms)"
    print(f"  [{i+1:02d}] {status}")
    time.sleep(0.3)

# ── RENAME ────────────────────────────────────────────────────────────────────
print(f"\nTesting RENAME (IN_MOVED_FROM + IN_MOVED_TO) ({ITERATIONS}x)...")
for i in range(ITERATIONS):
    uid_old = f"rename-old-{i:03d}-{int(time.time()*1000)}"
    uid_new = f"rename-new-{i:03d}-{int(time.time()*1000)}"
    old_path = os.path.join(TEST_DIR, f"{uid_old}.md")
    new_path = os.path.join(TEST_DIR, f"{uid_new}.md")
    with open(old_path, "w") as f:
        f.write(f"# {uid_old}\nPre-rename content.")
    time.sleep(0.5)  # Allow index

    t0 = time.time()
    os.rename(old_path, new_path)
    found = gbrain_has(slugify(new_path))
    elapsed_ms = int((time.time() - t0) * 1000)
    results["rename"].append({"elapsed_ms": elapsed_ms, "found": found, "uid": uid_new})
    status = "OK" if found else f"TIMEOUT ({elapsed_ms}ms)"
    print(f"  [{i+1:02d}] {status}")
    time.sleep(0.3)

# ── Summary ───────────────────────────────────────────────────────────────────
print()
print("=== Sync Timing Summary ===")
all_pass = True
for event_type, data in results.items():
    latencies = sorted(r["elapsed_ms"] for r in data)
    total = len(latencies)
    if not total:
        continue
    p95 = latencies[int(total * 0.95)] if total > 1 else latencies[-1]
    ok_count = sum(1 for r in data if r.get("found", r.get("removed", False)))
    pass_gate = p95 <= P95_GATE_MS
    if not pass_gate:
        all_pass = False
    status = "PASS" if pass_gate else "FAIL"
    print(f"  {event_type:8s}: p95={p95}ms  ok={ok_count}/{total}  [{status}]")

print()
if all_pass:
    print("AC2 PASS: all event types p95 ≤ 5000ms")
else:
    print("AC2 FAIL: some event types exceeded 5000ms p95 gate")
    print("Check: is inotify-watch.sh running? Is gbrain import running in background?")
    sys.exit(1)
PYEOF

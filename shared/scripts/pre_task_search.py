#!/usr/bin/env python3
"""
pre_task_search.py — Pre-task Radar search enrichment (MEMO-014).

Called by inotify-watch.sh when a task file is moved to in_progress/.
Reads the task JSON, runs memocean_search(source='radar'), and writes
the results into pre_search_context (upsert: skips if already present).

Usage:
    python3 pre_task_search.py <task_json_path>

Exit codes:
    0 — always (failures are silent to not block notification pipeline)

Log: ~/.claude-bots/logs/pre-task-search.log (one line per run)
"""

import json
import os
import sys
import time
from pathlib import Path

LOG_PATH = Path.home() / ".claude-bots" / "logs" / "pre-task-search.log"
MEMOCEAN_MCP_ROOT = Path.home() / ".claude-bots" / "shared" / "memocean-mcp"


def _log(task_id: str, hits: int, elapsed_ms: int, note: str = "") -> None:
    """Append one line to the pre-task-search log. Swallows all exceptions."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = json.dumps(
            {"ts": ts, "task_id": task_id, "hits": hits, "elapsed_ms": elapsed_ms, "note": note},
            ensure_ascii=False,
        )
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _build_query(task: dict) -> str:
    """
    Extract search keywords from the task.
    Priority: title + spec.goal (truncated) or description.
    Returns a space-joined keyword string (≤ 100 chars to keep query tight).
    """
    parts = []
    title = task.get("title", "").strip()
    if title:
        parts.append(title)

    spec = task.get("spec", {})
    if isinstance(spec, dict):
        goal = spec.get("goal", "").strip()
        if goal:
            # Take first 80 chars to avoid giant query
            parts.append(goal[:80])
    else:
        description = task.get("description", "").strip()
        if description:
            parts.append(description[:80])

    return " ".join(parts)[:200]  # hard cap


def main() -> None:
    t0 = time.time()
    task_id = "unknown"

    if len(sys.argv) < 2:
        _log(task_id, 0, 0, "no task_json_path arg")
        sys.exit(0)

    task_json_path = Path(sys.argv[1])

    # --- Read task JSON ---
    try:
        with open(task_json_path, encoding="utf-8") as f:
            task = json.load(f)
    except Exception as e:
        _log(task_id, 0, 0, f"json_read_error: {e}")
        sys.exit(0)

    task_id = task.get("id", task.get("task_id", str(task_json_path.stem)))

    # --- AC3: idempotent — skip if pre_search_context already present ---
    if task.get("pre_search_context"):
        elapsed_ms = int((time.time() - t0) * 1000)
        _log(task_id, len(task["pre_search_context"]), elapsed_ms, "already_present_skipped")
        sys.exit(0)

    # --- Build query ---
    query = _build_query(task)
    if not query.strip():
        elapsed_ms = int((time.time() - t0) * 1000)
        _log(task_id, 0, elapsed_ms, "empty_query_skipped")
        sys.exit(0)

    # --- Import memocean_search ---
    try:
        if str(MEMOCEAN_MCP_ROOT) not in sys.path:
            sys.path.insert(0, str(MEMOCEAN_MCP_ROOT))
        from memocean_mcp.tools.unified_search import memocean_search
    except Exception as e:
        elapsed_ms = int((time.time() - t0) * 1000)
        _log(task_id, 0, elapsed_ms, f"import_error: {e}")
        sys.exit(0)

    # --- Run search (source='radar', limit=5) ---
    try:
        results = memocean_search(query, source="radar", limit=5)
    except Exception as e:
        elapsed_ms = int((time.time() - t0) * 1000)
        _log(task_id, 0, elapsed_ms, f"search_error: {e}")
        sys.exit(0)

    # --- Upsert pre_search_context into task JSON ---
    try:
        task["pre_search_context"] = {
            "query": query,
            "source": "radar",
            "hits": results,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        # Write atomically via tmp file
        tmp_path = task_json_path.with_suffix(".tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(task, f, ensure_ascii=False, indent=2)
        tmp_path.rename(task_json_path)
    except Exception as e:
        elapsed_ms = int((time.time() - t0) * 1000)
        _log(task_id, len(results), elapsed_ms, f"write_error: {e}")
        sys.exit(0)

    elapsed_ms = int((time.time() - t0) * 1000)
    _log(task_id, len(results), elapsed_ms)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Top-level safety net: never let this script block the notification pipeline
        sys.exit(0)

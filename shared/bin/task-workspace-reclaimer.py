#!/usr/bin/env python3
"""Conservatively reclaim completed FATQ task workspaces.

Dry-run is the default.  ``--apply`` is the only deletion path and is
deliberately limited to direct children of ``tasks/work`` and
``tasks/worktrees``.  A container is reclaimable only when its exact task ID
maps to a ``done`` or ``cancelled`` task and every contained Git worktree is
classified safe by clone-reclaim-safety.py.  That helper proves local-only
commits are present in a configured production source and refuses opaque or
unique working-tree content.
"""

from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone


COMPLETED = {"done", "cancelled"}
SCOPES = ("tasks/work", "tasks/worktrees")


def load_safety(helper: Path):
    spec = importlib.util.spec_from_file_location("clone_reclaim_safety", helper)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load safety helper: {helper}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_tasks(tasks_root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for task_file in tasks_root.glob("*/*.json"):
        try:
            task = json.loads(task_file.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        task_id = str(task.get("task_id") or "")
        if task_id:
            result[task_id] = str(task.get("status") or task_file.parent.name)
    return result


def repos_under(container: Path) -> list[Path]:
    repos: list[Path] = []
    for current, directories, files in os.walk(container):
        if ".git" in directories or ".git" in files:
            repos.append(Path(current).resolve())
            directories[:] = []
    return sorted(set(repos))


def size_kb(path: Path) -> int | None:
    result = subprocess.run(["du", "-sk", str(path)], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, check=False)
    try:
        return int(result.stdout.split()[0]) if result.returncode == 0 else None
    except (IndexError, ValueError):
        return None


def held_by_process(container: Path) -> bool:
    """Fail closed when a process cwd or FD resolves within this container."""
    target = container.resolve()
    prefix = str(target) + os.sep
    for proc in Path("/proc").glob("[0-9]*"):
        for ref in (proc / "cwd", *(proc / "fd").glob("*")):
            try:
                resolved = ref.resolve(strict=True)
            except OSError:
                continue
            if resolved == target or str(resolved).startswith(prefix):
                return True
    return False


def record(scope: str, container: Path, tasks: dict[str, str], safety, sources: list[Path]) -> dict:
    task_id = container.name
    status = tasks.get(task_id, "unknown")
    result = {"scope": scope, "path": str(container), "task_id": task_id,
              "task_status": status, "size_kb": size_kb(container)}
    if status not in COMPLETED:
        result.update(action="needs_review", reason="task_not_done_or_cancelled")
        return result
    if held_by_process(container):
        result.update(action="needs_review", reason="cwd_or_fd_held")
        return result
    repos = repos_under(container)
    if not repos:
        result.update(action="needs_review", reason="no_git_repository")
        return result
    evidence = [safety.classify(repo, sources) for repo in repos]
    unsafe = next((item for item in evidence if not item.get("eligible")), None)
    result["repos"] = evidence
    if unsafe:
        result.update(action="needs_review", reason=str(unsafe.get("reason") or "inspection_error"))
        return result
    result.update(action="reclaimable", reason="completed_task_and_content_confirmed")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="/home/oldrabbit/.claude-bots")
    parser.add_argument("--apply", action="store_true", help="actually delete reclaimable directories")
    parser.add_argument("--log-file")
    parser.add_argument("--source", action="append", dest="sources")
    parser.add_argument("--safety-helper")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    tasks_root = root / "tasks"
    helper = Path(args.safety_helper or root / "shared/bin/clone-reclaim-safety.py").resolve()
    if not helper.is_file():
        parser.error(f"missing safety helper: {helper}")
    safety = load_safety(helper)
    sources = [Path(item).resolve() for item in (args.sources or [str(root)])]
    tasks = load_tasks(tasks_root)
    log_path = Path(args.log_file or root / "logs/task-workspace-reclaimer.jsonl")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    for scope in SCOPES:
        scope_path = root / scope
        if not scope_path.is_dir():
            continue
        for container in sorted(item for item in scope_path.iterdir() if item.is_dir() and not item.is_symlink()):
            item = record(scope, container, tasks, safety, sources)
            if args.apply and item["action"] == "reclaimable":
                # Re-resolve immediately before deletion to defeat replacement races.
                expected_parent = scope_path.resolve()
                current = container.resolve()
                if current.parent != expected_parent:
                    item.update(action="needs_review", reason="path_changed_before_remove")
                else:
                    shutil.rmtree(current)
                    item.update(action="removed", removal="shutil_rmtree")
            records.append(item)
    reasons = collections.Counter(item["reason"] for item in records if item["action"] == "needs_review")
    reclaimable = [item for item in records if item["action"] in {"reclaimable", "removed"}]
    summary = {"ts": datetime.now(timezone.utc).isoformat(), "mode": "apply" if args.apply else "dry-run",
               "candidates": len(records), "reclaimable": len(reclaimable),
               "estimated_reclaim_kb": sum(item["size_kb"] or 0 for item in reclaimable),
               "removed": sum(item["action"] == "removed" for item in records),
               "needs_review": sum(item["action"] == "needs_review" for item in records),
               "needs_review_reasons": dict(sorted(reasons.items()))}
    with log_path.open("a") as log:
        for item in records:
            print(json.dumps(item, ensure_ascii=False, sort_keys=True))
            log.write(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n")
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        log.write(json.dumps({"summary": summary}, ensure_ascii=False, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

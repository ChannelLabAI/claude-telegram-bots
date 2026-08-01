#!/usr/bin/env python3
"""Reproducible, read-only census for FATQ a7e2."""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import json
import os
from pathlib import Path
import re
import importlib.util
import subprocess
import sys

HELPER = Path(__file__).with_name("clone-reclaim-safety.py")
SPEC = importlib.util.spec_from_file_location("clone_reclaim_safety", HELPER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {HELPER}")
SAFETY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SAFETY)
DEFAULT_SOURCES = SAFETY.DEFAULT_SOURCES
classify = SAFETY.classify


ACTIVE = {"pending", "in_progress", "review"}
SCOPE_NAMES = {"work", "scratch", "review-tmp", "tmp-verify"}


def load_tasks(root: Path) -> tuple[dict[str, str], dict[str, str]]:
    tasks: dict[str, str] = {}
    short: dict[str, list[str]] = collections.defaultdict(list)
    for path in sorted((root / "tasks").glob("*/*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        task_id = str(data.get("task_id") or "")
        status = str(data.get("status") or path.parent.name)
        if not task_id:
            continue
        tasks[task_id] = status
        match = re.match(r"^\d{8}-\d{4,6}-([0-9a-f]{4})-", task_id)
        if match:
            short[match.group(1)].append(task_id)
    unique = {key: values[0] for key, values in short.items() if len(values) == 1}
    return tasks, unique


def task_for(container: Path, tasks: dict[str, str], short: dict[str, str]) -> tuple[str | None, str]:
    text = str(container)
    exact = [task_id for task_id in tasks if task_id in text]
    if len(exact) == 1:
        return exact[0], tasks[exact[0]]
    tokens = re.findall(r"(?<![0-9a-f])([0-9a-f]{4})(?![0-9a-f])", container.name.lower())
    matched = {short[token] for token in tokens if token in short}
    if len(matched) == 1:
        task_id = matched.pop()
        return task_id, tasks[task_id]
    return None, "unknown"


def repo_roots(container: Path, max_depth: int = 5) -> list[Path]:
    roots = []
    base_depth = len(container.parts)
    for current, directories, files in os.walk(container):
        current_path = Path(current)
        depth = len(current_path.parts) - base_depth
        if depth >= max_depth:
            directories[:] = []
        if ".git" in files or ".git" in directories:
            roots.append(current_path.resolve())
            directories[:] = [name for name in directories if name != ".git"]
    return sorted(set(roots))


def containers(root: Path) -> dict[str, list[Path]]:
    groups = {
        "tasks/work": sorted(path for path in (root / "tasks/work").iterdir() if path.is_dir()),
        "tasks/worktrees": sorted(path for path in (root / "tasks/worktrees").iterdir() if path.is_dir()),
        "bots/scoped": [],
    }
    for path in sorted((root / "bots").glob("*/*")):
        if path.is_dir() and path.name in SCOPE_NAMES:
            groups["bots/scoped"].extend(sorted(child for child in path.iterdir() if child.is_dir()))
    return groups


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="/home/oldrabbit/.claude-bots")
    parser.add_argument("--details", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    tasks, short = load_tasks(root)
    sources = [Path(value).resolve() for value in DEFAULT_SOURCES]
    summary = {}
    detail_path = Path(args.details)
    with detail_path.open("w") as output:
        for category, entries in containers(root).items():
            container_repos = {container: repo_roots(container) for container in entries}
            unique_repos = sorted({repo for repos in container_repos.values() for repo in repos})
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                classified = dict(zip(unique_repos, executor.map(lambda repo: classify(repo, sources), unique_repos)))
            state_counts: collections.Counter[str] = collections.Counter()
            reason_counts: collections.Counter[str] = collections.Counter()
            repo_count = 0
            eligible_repos = 0
            eligible_containers = 0
            for container in entries:
                task_id, state = task_for(container, tasks, short)
                state_counts[state] += 1
                repos = container_repos[container]
                repo_results = [classified[repo] for repo in repos]
                for result in repo_results:
                    repo_count += 1
                    reason_counts[str(result.get("reason"))] += 1
                    eligible_repos += int(bool(result.get("eligible")))
                protected = state in ACTIVE
                reclaimable = bool(repos) and not protected and all(item.get("eligible") for item in repo_results)
                eligible_containers += int(reclaimable)
                record = {
                    "category": category,
                    "container": str(container),
                    "task_id": task_id,
                    "task_status": state,
                    "active_task_protected": protected,
                    "repo_count": len(repos),
                    "rule_reclaimable_container": reclaimable,
                    "repos": repo_results,
                }
                size = subprocess.run(
                    ["du", "-sk", str(container)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                record["size_kb"] = int(size.stdout.split()[0]) if size.returncode == 0 else None
                output.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            summary[category] = {
                "containers": len(entries),
                "task_status_distribution": dict(sorted(state_counts.items())),
                "git_copies": repo_count,
                "rule_eligible_git_copies": eligible_repos,
                "all_git_copies_safe_containers": eligible_containers,
                "repo_reason_distribution": dict(sorted(reason_counts.items())),
            }
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

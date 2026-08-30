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
REASON_MEANINGS = {
    "task_not_done_or_cancelled": "對應任務尚未 done/cancelled，工作區可能仍在使用",
    "cwd_or_fd_held": "仍有程序的工作目錄或檔案描述符指向此容器，不能安全移除",
    "no_git_repository": "容器內沒有 git repo，無法比對內容是否已落地",
    "source_ambiguous": "找不到唯一可信的來源 repo，無法確認容器內容已落地",
    "unconfirmed_unpushed_commit": "存在尚未在可信來源確認的本機 commit",
    "added_lines_not_in_source": "工作區新增內容尚未在可信來源找到",
    "inspection_error": "檢查過程發生錯誤，無法取得足夠證據",
    "untracked_non_file": "存在無法按一般檔案內容驗證的未追蹤項目",
    "path_changed_before_remove": "刪除前路徑已改變，競態保護阻止移除",
}


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


def held_report(records: list[dict], root: Path) -> tuple[list[dict], dict]:
    held = [item for item in records if item["action"] == "needs_review"]
    reason_counts = collections.Counter(item["reason"] for item in held)
    reason_sizes = collections.Counter()
    examples: dict[str, list[str]] = collections.defaultdict(list)
    report_items: list[dict] = []
    for item in held:
        reason = item["reason"]
        reason_sizes[reason] += item["size_kb"] or 0
        if len(examples[reason]) < 3:
            examples[reason].append(item["path"])
        report_items.append({
            "action": "held",
            "scope": item["scope"],
            "path": item["path"],
            "size_kb": item["size_kb"],
            "task_id": item["task_id"],
            "task_status": item["task_status"],
            "reason": reason,
            "reason_meaning": REASON_MEANINGS.get(reason, "保守檢查未能證明可安全移除，需人工檢視"),
            "repos": item.get("repos", []),
        })

    scope_du_kb = {scope: size_kb(root / scope) for scope in SCOPES}
    measured_total_kb = sum(value or 0 for value in scope_du_kb.values())
    classified_total_kb = sum(item["size_kb"] or 0 for item in records)
    delta_kb = classified_total_kb - measured_total_kb
    reclaimable = [item for item in records if item["action"] == "reclaimable"]
    summary = {
        "mode": "held-report",
        "candidates": len(records),
        "held_count": len(held),
        "held_size_kb": sum(item["size_kb"] or 0 for item in held),
        "held_reason_counts": dict(sorted(reason_counts.items())),
        "held_reason_sizes_kb": dict(sorted(reason_sizes.items())),
        "representative_examples": dict(sorted(examples.items())),
        "reclaimable_count": len(reclaimable),
        "reclaimable_size_kb": sum(item["size_kb"] or 0 for item in reclaimable),
        "classified_total_kb": classified_total_kb,
        "scope_du_kb": scope_du_kb,
        "du_measured_total_kb": measured_total_kb,
        "accounting_delta_kb": delta_kb,
        "accounting_delta_pct": round(abs(delta_kb) * 100 / measured_total_kb, 3)
        if measured_total_kb else 0.0,
        "accounting_note": (
            "classified_total_kb is the sum of direct child du values; scope du also includes "
            "parent directory blocks, and child du may double-count shared hard-linked blocks"
        ),
    }
    return report_items, summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="/home/oldrabbit/.claude-bots")
    parser.add_argument("--apply", action="store_true", help="actually delete reclaimable directories")
    parser.add_argument("--held-report", action="store_true",
                        help="print held containers with reasons, sizes, examples, and du reconciliation")
    parser.add_argument("--log-file")
    parser.add_argument("--source", action="append", dest="sources")
    parser.add_argument("--safety-helper")
    args = parser.parse_args()
    if args.apply and args.held_report:
        parser.error("--apply and --held-report are mutually exclusive")
    root = Path(args.root).resolve()
    tasks_root = root / "tasks"
    helper = Path(args.safety_helper or root / "shared/bin/clone-reclaim-safety.py").resolve()
    if not helper.is_file():
        parser.error(f"missing safety helper: {helper}")
    safety = load_safety(helper)
    sources = [Path(item).resolve() for item in (args.sources or [str(root)])]
    tasks = load_tasks(tasks_root)
    if args.held_report:
        missing_scopes = [str(root / scope) for scope in SCOPES if not (root / scope).is_dir()]
        if missing_scopes:
            parser.error("missing scan scope(s): " + ", ".join(missing_scopes))
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
    if args.held_report:
        report_items, report_summary = held_report(records, root)
        for item in report_items:
            print(json.dumps(item, ensure_ascii=False, sort_keys=True))
        print(json.dumps({"summary": report_summary}, ensure_ascii=False, sort_keys=True))
        return 0
    log_path = Path(args.log_file or root / "logs/task-workspace-reclaimer.jsonl")
    log_path.parent.mkdir(parents=True, exist_ok=True)
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

#!/usr/bin/env python3
"""Read-only safety classifier for review clone/worktree reclamation."""

from __future__ import annotations

import argparse
import collections
import functools
import json
import os
from pathlib import Path
import subprocess
import sys


DEFAULT_SOURCES = (
    "/home/oldrabbit/.claude-bots",
    "/home/oldrabbit/.claude-bots/pod-system",
    "/home/oldrabbit/.claude-bots/mvp",
)


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


@functools.lru_cache(maxsize=None)
def resolved_git_dir(repo: Path, arg: str) -> Path:
    value = git(repo, "rev-parse", arg).strip()
    path = Path(value)
    if not path.is_absolute():
        path = repo / path
    return path.resolve()


def canonical_remote(value: str) -> str:
    value = value.strip().removesuffix("/").removesuffix("/.")
    if value.startswith("file://"):
        value = value[7:]
    try:
        path = Path(value)
        if path.is_absolute():
            return str(path.resolve())
    except OSError:
        pass
    return value.removesuffix(".git")


@functools.lru_cache(maxsize=None)
def source_remote(source: Path) -> str:
    return git(source, "remote", "get-url", "origin", check=False).strip()


def choose_source(repo: Path, sources: list[Path]) -> tuple[Path | None, str]:
    common = resolved_git_dir(repo, "--git-common-dir")
    for source in sources:
        if common == resolved_git_dir(source, "--git-common-dir"):
            return source, "shared_common_dir"

    remote = git(repo, "remote", "get-url", "origin", check=False).strip()
    if remote:
        remote_key = canonical_remote(remote)
        matches = []
        for source in sources:
            remote = source_remote(source)
            keys = {canonical_remote(str(source)), canonical_remote(str(source) + "/.")}
            if remote:
                keys.add(canonical_remote(remote))
            if remote_key in keys:
                matches.append(source)
        if len(matches) == 1:
            return matches[0], "origin_match"

    head = git(repo, "rev-parse", "HEAD").strip()
    containing = []
    for source in sources:
        if subprocess.run(
            ["git", "-C", str(source), "cat-file", "-e", f"{head}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).returncode == 0:
            containing.append(source)
    if len(containing) == 1:
        return containing[0], "unique_head_object"
    return None, "source_ambiguous"


@functools.lru_cache(maxsize=None)
def source_contains_commit(source: Path, commit: str) -> bool:
    object_type = git(source, "cat-file", "-t", commit, check=False).strip()
    if object_type != "commit":
        return False
    branches = git(source, "branch", "--contains", commit, "--format=%(refname)", check=False)
    return bool(branches.strip())


@functools.lru_cache(maxsize=None)
def source_lines(source: Path, relative: str) -> tuple[bytes, ...] | None:
    target = source / relative
    if target.is_symlink():
        return (os.readlink(target).encode(),)
    if target.is_file():
        if target.stat().st_size > 2 * 1024 * 1024:
            return None
        data = target.read_bytes()
        if b"\0" in data:
            return None
        return tuple(data.splitlines())
    if target.is_dir():
        stage = git(source, "ls-files", "-s", "--", relative, check=False).strip()
        fields = stage.split()
        if len(fields) >= 2 and fields[0] == "160000":
            return (f"Subproject commit {fields[1]}".encode(),)
    return None


def parse_diff(repo: Path) -> tuple[list[tuple[str, bytes]], list[bytes], str | None]:
    numstat = git(repo, "diff", "--numstat", "HEAD", "--")
    changed_lines = 0
    for line in numstat.splitlines():
        fields = line.split("\t", 2)
        if len(fields) >= 2 and (fields[0] == "-" or fields[1] == "-"):
            return [], [], "binary_or_opaque_diff"
        if len(fields) >= 2:
            changed_lines += int(fields[0]) + int(fields[1])
    if changed_lines > 20000:
        return [], [], "diff_too_large_for_automatic_reclaim"

    output = subprocess.run(
        ["git", "-C", str(repo), "diff", "--no-ext-diff", "--no-color", "--unified=0", "HEAD", "--"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    if output.returncode:
        return [], [], "git_diff_failed"
    additions: list[tuple[str, bytes]] = []
    deletions: list[bytes] = []
    current_path: str | None = None
    for raw in output.stdout.splitlines():
        if raw.startswith(b"+++ b/"):
            current_path = raw[6:].decode("utf-8", "surrogateescape")
        elif raw.startswith(b"+++ /dev/null"):
            current_path = None
        elif raw.startswith(b"+") and not raw.startswith(b"+++"):
            if current_path is not None and raw[1:].strip():
                additions.append((current_path, raw[1:]))
        elif raw.startswith(b"-") and not raw.startswith(b"---") and raw[1:].strip():
            deletions.append(raw[1:])

    for relative in git(repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0"):
        if not relative:
            continue
        path = repo / relative
        if path.is_symlink():
            additions.append((relative, os.readlink(path).encode()))
            continue
        if not path.is_file():
            return [], [], "untracked_non_file"
        if path.stat().st_size > 2 * 1024 * 1024:
            return [], [], "untracked_file_too_large"
        data = path.read_bytes()
        if b"\0" in data:
            return [], [], "untracked_binary"
        for line in data.splitlines():
            if line.strip():
                additions.append((relative, line))
    return additions, deletions, None


def deletion_only_fuse(additions: list[tuple[str, bytes]]) -> bool:
    """Keep an explicit mutation point for the vacuous-inclusion safeguard."""
    return not additions


def classify(repo: Path, sources: list[Path]) -> dict[str, object]:
    result: dict[str, object] = {"repo": str(repo.resolve()), "eligible": False}
    try:
        if git(repo, "rev-parse", "--is-inside-work-tree").strip() != "true":
            result["reason"] = "not_worktree"
            return result
        source, source_reason = choose_source(repo, sources)
        result["source_match"] = source_reason
        if source is None:
            result["reason"] = "source_ambiguous"
            return result
        result["source"] = str(source)

        unpublished = set(
            git(repo, "log", "--format=%H", "--branches", "--not", "--remotes").split()
        )
        commits = {
            commit
            for commit in git(repo, "for-each-ref", "--format=%(objectname)", "refs/heads").split()
            if commit in unpublished
        }
        head = git(repo, "rev-parse", "HEAD").strip()
        if not git(repo, "branch", "-r", "--contains", head, "--format=%(refname)", check=False).strip():
            commits.add(head)
        local_only_tips = [
            commit
            for commit in sorted(commits)
            if not git(repo, "branch", "-r", "--contains", commit, "--format=%(refname)", check=False).strip()
        ]
        result["unpublished_commit_count"] = len(unpublished)
        unconfirmed = [
            commit
            for commit in local_only_tips
            if not any(source_contains_commit(candidate, commit) for candidate in sources)
        ]
        result["unconfirmed_commits"] = unconfirmed
        if unconfirmed:
            result["reason"] = "unconfirmed_unpushed_commit"
            return result

        status = git(repo, "status", "--porcelain=v1", "--untracked-files=all")
        if not status:
            result.update(eligible=True, reason="clean_and_commits_confirmed")
            return result

        additions, deletions, error = parse_diff(repo)
        result["added_lines"] = len(additions)
        result["deleted_lines"] = len(deletions)
        if error:
            result["reason"] = error
            return result
        if deletion_only_fuse(additions):
            result["reason"] = "deletion_only_or_opaque"
            return result
        added_counter = collections.Counter(line for _, line in additions)
        deleted_counter = collections.Counter(deletions)
        if additions and all(deleted_counter[line] >= count for line, count in added_counter.items()):
            result["reason"] = "pure_reorder"
            return result

        cache: dict[str, list[bytes] | None] = {}
        missing: list[str] = []
        for relative, line in additions:
            if relative not in cache:
                cache[relative] = source_lines(source, relative)
            if cache[relative] is None or line not in cache[relative]:
                missing.append(relative)
        result["missing_added_lines"] = len(missing)
        if missing:
            result["missing_paths"] = sorted(set(missing))[:20]
            result["reason"] = "added_lines_not_in_source"
            return result
        result.update(eligible=True, reason="dirty_changes_line_contained")
        return result
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        result["reason"] = "inspection_error"
        result["error"] = str(exc)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?")
    parser.add_argument("--batch", nargs="+", metavar="REPO")
    parser.add_argument("--source", action="append", dest="sources")
    args = parser.parse_args()
    configured = os.environ.get("CLONE_TTL_SOURCE_REPOS", "")
    env_sources = [value for value in configured.split(":") if value]
    sources = [Path(value).resolve() for value in (args.sources or env_sources or DEFAULT_SOURCES)]
    if args.batch:
        # One process lets the read-only source and commit caches cover every
        # candidate in this cleaner pass. Each record is NUL framed so paths
        # and JSON evidence stay unambiguous to the shell caller.
        for raw_repo in args.batch:
            output = classify(Path(raw_repo).resolve(), sources)
            sys.stdout.write(raw_repo)
            sys.stdout.write("\0")
            json.dump(output, sys.stdout, ensure_ascii=False, sort_keys=True)
            sys.stdout.write("\0")
        return 0
    if not args.repo:
        parser.error("repo is required unless --batch is used")
    output = classify(Path(args.repo).resolve(), sources)
    json.dump(output, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if output.get("eligible") else 1


if __name__ == "__main__":
    raise SystemExit(main())

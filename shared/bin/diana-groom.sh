#!/usr/bin/env bash
# Diana PM truth groom queue and append-only apply guard.
set -euo pipefail

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


PM_ROOT = Path(os.environ.get("DIANA_GROOM_PM_ROOT", "/home/oldrabbit/pm-hub")).resolve()
PROJECTS = (PM_ROOT / "projects").resolve()
STATE_DIR = Path(os.environ.get(
    "DIANA_GROOM_STATE_DIR", "/home/oldrabbit/.claude-bots/state/diana-groom"
)).resolve()
RELAY_DIR = Path(os.environ.get(
    "DIANA_GROOM_RELAY_DIR", "/home/oldrabbit/.claude-bots/relay-diana"
)).resolve()
NOW = int(os.environ.get("DIANA_GROOM_NOW_EPOCH", str(int(time.time()))))
RETRY_SECONDS = int(os.environ.get("DIANA_GROOM_RETRY_SECONDS", "3600"))
STATE_PATH = STATE_DIR / "state.json"
INIT_PATH = STATE_DIR / "initialized.json"
LOCK_PATH = STATE_DIR / ".lock"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args), cwd=PM_ROOT, text=True, capture_output=True, check=check
    )


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def load_state() -> dict:
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        if data.get("schema") == "diana-groom-state-v1" and isinstance(data.get("entries"), dict):
            return data
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return {"schema": "diana-groom-state-v1", "entries": {}}


def project_path(raw: str | Path) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = PROJECTS / path
    path = path.resolve()
    if path.parent != PROJECTS or path.suffix != ".md":
        raise SystemExit(f"project must be one projects/*.md file: {path}")
    return path


def split_sections(text: str) -> tuple[list[str], dict[str, list[str]], list[str]]:
    lines = text.splitlines()
    headings = [i for i, line in enumerate(lines) if line.startswith("## ")]
    if not headings:
        return lines, {}, []
    prefix = lines[:headings[0]]
    sections: dict[str, list[str]] = {}
    order: list[str] = []
    for pos, start in enumerate(headings):
        end = headings[pos + 1] if pos + 1 < len(headings) else len(lines)
        name = lines[start][3:].strip()
        order.append(name)
        sections[name] = lines[start + 1:end]
    return prefix, sections, order


def log_entries(text: str) -> list[str]:
    _, sections, _ = split_sections(text)
    return [line for line in sections.get("日誌", []) if line.startswith("- ")]


def entry_instances(text: str) -> list[tuple[str, int]]:
    """Return each log line with its stable 1-based occurrence among equal lines."""
    seen: defaultdict[str, int] = defaultdict(int)
    instances: list[tuple[str, int]] = []
    for entry in log_entries(text):
        seen[entry] += 1
        instances.append((entry, seen[entry]))
    return instances


def fingerprint(project: Path, entry: str, occurrence: int) -> str:
    material = f"{project.name}\0{entry}\0{occurrence}".encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def require_initialized() -> None:
    if not INIT_PATH.is_file():
        raise SystemExit("diana-groom is not initialized; run init before event/sweep")


def head_sha() -> str:
    result = run("git", "rev-parse", "HEAD", check=False)
    return result.stdout.strip() if result.returncode == 0 else "working-tree"


def source_key(project: Path, entry: str, occurrence: int, commit: str | None) -> str:
    fp = fingerprint(project, entry, occurrence)
    return f"sha:{commit}:{project.name}:{fp[:16]}" if commit else f"entry:{fp}"


def relay_payload(project: Path, entry: str, occurrence: int, key: str, fp: str, track: str) -> dict:
    return {
        "from_bot": "keeper-diana",
        "recipient": "diana-chat",
        "route": "diana-chat",
        "text": (
            "diana:task\n[Diana groom] Integrate one PM truth log entry into the structural "
            "sections of its project. Do not delete or edit any historical log line. Prepare a "
            "complete candidate project file, then run:\n"
            f"/home/oldrabbit/.claude-bots/shared/bin/diana-groom.sh apply --project {project} "
            f"--source-key {key} --candidate <candidate.md>\n"
            "The candidate must preserve every existing 日誌 entry in order, append exactly one "
            f"[整理] line containing the source key, and make a structural update.\nInput: {entry}"
        ),
        "meta": {
            "source": "diana-groom",
            "track": track,
            "project": str(project),
            "project_id": project.stem,
            "source_key": key,
            "entry_fingerprint": fp,
            "entry": entry,
            "entry_occurrence": occurrence,
        },
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW)),
    }


def enqueue(project: Path, entry: str, occurrence: int, commit: str | None, track: str) -> bool:
    # [整理] is the groomer's audit output, never a new groom input.
    if "[整理]" in entry:
        return False
    fp = fingerprint(project, entry, occurrence)
    key = source_key(project, entry, occurrence, commit)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        previous = state["entries"].get(fp)
        if previous and previous.get("status") in {"baseline", "processed"}:
            return False
        if previous and previous.get("status") == "queued" and NOW - int(previous.get("queued_epoch", 0)) < RETRY_SECONDS:
            return False
        if previous and previous.get("status") == "queued" and previous.get("source_key"):
            # Preserve the first key so a delayed inbox job remains valid while
            # the safety net republishes the same fingerprint.
            key = str(previous["source_key"])

        RELAY_DIR.mkdir(parents=True, exist_ok=True)
        relay_path = RELAY_DIR / f"{NOW}-{project.stem}-{fp[:16]}-diana-groom.json"
        atomic_json(relay_path, relay_payload(project, entry, occurrence, key, fp, track))
        state["entries"][fp] = {
            "status": "queued",
            "source_key": key,
            "project": str(project),
            "entry": entry,
            "entry_occurrence": occurrence,
            "track": track,
            "queued_epoch": NOW,
            "relay_file": relay_path.name,
        }
        atomic_json(STATE_PATH, state)
    return True


def init_state() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_PATH.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        count = 0
        for project in sorted(PROJECTS.glob("*.md")):
            for entry, occurrence in entry_instances(project.read_text(encoding="utf-8")):
                fp = fingerprint(project, entry, occurrence)
                state["entries"].setdefault(fp, {
                    "status": "baseline",
                    "project": str(project),
                    "entry": entry,
                    "entry_occurrence": occurrence,
                    "baselined_epoch": NOW,
                })
                count += 1
        atomic_json(STATE_PATH, state)
        atomic_json(INIT_PATH, {"schema": "diana-groom-init-v1", "initialized_epoch": NOW, "entries": count})
    print(json.dumps({"initialized": count}))


def current_file_entries(project: Path) -> list[str]:
    return log_entries(project.read_text(encoding="utf-8"))


def event_file(project: Path, track: str = "event", commit: str | None = None) -> int:
    emitted = 0
    for entry, occurrence in entry_instances(project.read_text(encoding="utf-8")):
        if enqueue(project, entry, occurrence, commit, track):
            emitted += 1
    return emitted


def file_at(commit: str, relative: str) -> str:
    result = run("git", "show", f"{commit}:{relative}", check=False)
    return result.stdout if result.returncode == 0 else ""


def event_commit(commit: str, track: str = "event") -> int:
    check = run("git", "cat-file", "-e", f"{commit}^{{commit}}", check=False)
    if check.returncode != 0:
        raise SystemExit(f"unknown commit: {commit}")
    commit = run("git", "rev-parse", f"{commit}^{{commit}}").stdout.strip()
    changed = run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", commit, "--", "projects").stdout.splitlines()
    emitted = 0
    for relative in changed:
        if not relative.startswith("projects/") or not relative.endswith(".md"):
            continue
        project = project_path(PM_ROOT / relative)
        after = entry_instances(file_at(commit, relative))
        parent_result = run("git", "rev-parse", f"{commit}^", check=False)
        before_entries = log_entries(file_at(parent_result.stdout.strip(), relative)) if parent_result.returncode == 0 else []
        before_counts = Counter(before_entries)
        for entry, occurrence in after:
            if occurrence <= before_counts[entry]:
                continue
            if enqueue(project, entry, occurrence, commit, track):
                emitted += 1
    return emitted


def sweep(since: str) -> int:
    require_initialized()
    commits = run("git", "rev-list", f"--since={since}", "HEAD", "--", "projects").stdout.splitlines()
    emitted = sum(event_commit(commit, "safety-net") for commit in reversed(commits))
    for project in sorted(PROJECTS.glob("*.md")):
        emitted += event_file(project, "safety-net-working-tree", None)
    print(json.dumps({"track": "safety-net", "emitted": emitted}))
    return 0


def validate_candidate(old_text: str, candidate_text: str, source_entry: str, key: str) -> None:
    old_prefix, old_sections, old_order = split_sections(old_text)
    new_prefix, new_sections, new_order = split_sections(candidate_text)
    if old_order != new_order or old_order.count("日誌") != 1:
        raise SystemExit("refused: section headings/order changed or 日誌 is missing")
    old_log_section = old_sections["日誌"]
    new_log_section = new_sections["日誌"]
    old_logs = [line for line in old_log_section if line.startswith("- ")]
    if source_entry not in old_logs:
        raise SystemExit("refused: source entry is not present in the project log")
    if new_log_section[:len(old_log_section)] != old_log_section:
        raise SystemExit("refused: historical 日誌 section is not an unchanged ordered prefix")
    if len(new_log_section) != len(old_log_section) + 1:
        raise SystemExit("refused: candidate must append exactly one 日誌 line")
    整理 = new_log_section[-1]
    if "[整理]" not in 整理 or key not in 整理:
        raise SystemExit("refused: appended [整理] line must contain the source key")
    old_structural = "\n".join(old_prefix + [line for name in old_order if name != "日誌" for line in ([f"## {name}"] + old_sections[name])])
    new_structural = "\n".join(new_prefix + [line for name in new_order if name != "日誌" for line in ([f"## {name}"] + new_sections[name])])
    if old_structural == new_structural:
        raise SystemExit("refused: candidate has no structural update")


def apply_candidate(project: Path, key: str, candidate: Path) -> int:
    require_initialized()
    candidate = candidate.resolve()
    if not candidate.is_file():
        raise SystemExit(f"candidate not found: {candidate}")
    with LOCK_PATH.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        matches = [(fp, row) for fp, row in state["entries"].items() if row.get("source_key") == key]
        if len(matches) != 1:
            raise SystemExit("refused: source key is unknown or ambiguous")
        fp, row = matches[0]
        if row.get("status") == "processed":
            print(json.dumps({"status": "already-processed", "source_key": key}))
            return 0
        if Path(row.get("project", "")).resolve() != project:
            raise SystemExit("refused: source key belongs to another project")
        if run("git", "diff", "--quiet", "--", str(project.relative_to(PM_ROOT)), check=False).returncode != 0:
            raise SystemExit("refused: project has unrelated uncommitted changes")

        old_text = project.read_text(encoding="utf-8")
        candidate_text = candidate.read_text(encoding="utf-8")
        validate_candidate(old_text, candidate_text, str(row["entry"]), key)
        backup = project.with_name(f".{project.name}.diana-groom-backup-{os.getpid()}")
        shutil.copy2(project, backup)
        try:
            fd, tmp_name = tempfile.mkstemp(prefix=f".{project.name}.", dir=project.parent)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(candidate_text)
                if candidate_text and not candidate_text.endswith("\n"):
                    handle.write("\n")
            os.replace(tmp_name, project)
            result = run(
                "git", "-c", "user.name=diana", "-c", "user.email=diana@local",
                "commit", "--author=diana <diana@local>",
                "-m", f"chore(groom): integrate {project.stem} {fp[:12]}",
                "--", str(project.relative_to(PM_ROOT)), check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "git commit failed")
        except Exception:
            shutil.copy2(backup, project)
            run("git", "add", "--", str(project.relative_to(PM_ROOT)), check=False)
            run("git", "reset", "--", str(project.relative_to(PM_ROOT)), check=False)
            raise
        finally:
            backup.unlink(missing_ok=True)

        commit = head_sha()
        row.update({"status": "processed", "processed_epoch": NOW, "commit": commit})
        state["entries"][fp] = row
        atomic_json(STATE_PATH, state)
    print(json.dumps({"status": "processed", "source_key": key, "commit": commit}))
    return 0


parser = argparse.ArgumentParser(prog="diana-groom.sh")
sub = parser.add_subparsers(dest="command", required=True)
sub.add_parser("init")
event = sub.add_parser("event")
event.add_argument("--file")
event.add_argument("--commit")
safety = sub.add_parser("sweep")
safety.add_argument("--since", default="24 hours ago")
apply = sub.add_parser("apply")
apply.add_argument("--project", required=True)
apply.add_argument("--source-key", required=True)
apply.add_argument("--candidate", required=True)
args = parser.parse_args()

if args.command == "init":
    init_state()
elif args.command == "event":
    require_initialized()
    if bool(args.file) == bool(args.commit):
        raise SystemExit("event requires exactly one of --file or --commit")
    emitted = event_file(project_path(args.file), "event", None) if args.file else event_commit(args.commit, "event")
    print(json.dumps({"track": "event", "emitted": emitted}))
elif args.command == "sweep":
    sys.exit(sweep(args.since))
elif args.command == "apply":
    sys.exit(apply_candidate(project_path(args.project), args.source_key, Path(args.candidate)))
PY

#!/usr/bin/env python3
"""Fail when a canonical relay writer is absent from origin inventory.

Run against the root, pod-system, and mvp repositories that will be deployed.
Every filesystem source outside the explicit exclusion list that contains
``from_bot`` must be classified below; fixed identities must be either a
system inventory entry or a configured bot name/username.
"""
from __future__ import annotations

import json
import os
import re
import sys
from fnmatch import fnmatch
from pathlib import Path

HERE = Path(__file__).resolve()
SCAN_ROOT = Path(os.environ.get("RELAY_INVENTORY_SCAN_ROOT", HERE.parents[2]))
POD_ROOT = Path(os.environ.get("RELAY_INVENTORY_POD_ROOT", SCAN_ROOT / "pod-system"))
MVP_ROOT = Path(os.environ.get("RELAY_INVENTORY_MVP_ROOT", SCAN_ROOT / "mvp"))
INVENTORY_FILE = POD_ROOT / "relay-origin-verification.ts"
MIRROR_FILE = Path(os.environ.get("RELAY_INVENTORY_MIRROR", SCAN_ROOT / "infra" / "pod-system" / "relay-origin-verification.ts"))

SOURCE_SUFFIXES = {".sh", ".ts", ".js", ".py"}
# Explicit, reviewable exclusions for filesystem enumeration. These are
# repository metadata, generated dependencies/caches, runtime evidence, or
# separate repositories scanned in their own pass. No .gitignore rule is used.
EXCLUDED_DIR_PATTERNS = {
    ".git",
    "node_modules",
    "__pycache__",
}
ROOT_EXCLUDED_DIR_PATTERNS = EXCLUDED_DIR_PATTERNS | {
    ".worktrees",
    ".test-*",
    "_deploy-backups",
    "backups",
    "bots/*/dist",
    "bots/*/review-tmp",
    "bots/*/scratch",
    "bots/*/tmp*",
    "bots/*/work*",
    "deliverables",
    "infra",
    "logs",
    "mvp",
    "mvp-wt-*",
    "pod-system",
    "relay",
    "relay-diana",
    "seabed",
    "shared/memocean-mcp",
    "tasks",
    "work",
}

WRITERS = {
    "shared/bin/pubsub-bridge.ts": {"telegram"},
    "shared/bin/fatq-dispatch.sh": {"fatq-dispatch-cron"},
    "shared/bin/fatq-cli.sh": {"fatq-cli"},
    "shared/bin/schedule-once.sh": {"schedule-once"},
    "shared/bin/patrol-scan.sh": {"patrol-scan"},
    "shared/bin/morning-todo-all.sh": {"system"},
    "shared/bin/morning-todo.sh": {"system"},
    "shared/lib/boot-relay.sh": {"system"},
    "setup-claude-bot.sh": {"system"},
    "bots/keeper/keeper-batch.ts": {"keeper", "keeper-batch"},
    "shared/bin/fatq-closeout-sweep.sh": {"fatq-closeout-sweep"},
    "shared/bin/fatq-pending-lint.sh": {"fatq-pending-lint"},
    "shared/bin/fatq-watch.sh": {"fatq-watch"},
    "shared/loops/clean-tree-guard/clean-tree-guard.sh": {"clean-tree-guard"},
    "shared/loops/symlink-health/detector.sh": {"symlink-health-loop"},
    "shared/loops/trust-ledger/recompute.sh": {"trust-ledger"},
    "shared/scripts/heartbeat.ts": {"diana-health"},
    "shared/scripts/owner-delivery-zero-receipt-alert.ts": {"diana-health"},
    "shared/scripts/measure-bot-startup.sh": {"sancai-measure"},
    "shared/bin/mailbox-watch.sh": {"mailbox-watch"},
    "shared/bin/lark-mirror.ts": {"anna"},
    "shared/loops/roster-patrol/roster-patrol.sh": {"sancai"},
    "bots/anya/scripts/347d-naturalrun-followup.sh": {"system-cron"},
    "bots/anya/scripts/anya-pod-switch-9f0d.sh": {"system-cron"},
    "bots/anya/scripts/model-gate-48h-20260721.sh": {"system-cron"},
    "bots/anya/scripts/pods-tail-restart-e489.sh": {"system-cron"},
    "bots/anya/services/cove/inbox-write.ts": {"cove-daemon"},
    "bots/keeper/diana-analyze.ts": {"diana"},
    "bots/keeper/diana-task.ts": {"diana"},
    "bots/keeper/vault-watch.sh": {"vault-watch"},
    "scripts/inject-0254-verification.sh": {"system"},
    "scripts/inject-flight-status.sh": {"system"},
    "shared/loops/goal-graduation/invariant-scan.sh": {"goal-graduation-loop"},
    "mvp/mvp-server.ts": {"mvp-web", "<configured-bot>"},
    "pod-system/notification-turn-routing.ts": {"gateway"},
    "pod-system/relay-replies.ts": {"<configured-bot>"},
    "shared/server.patched.ts": {"<configured-bot>"},
    "shared/shared/server.patched.ts": {"<configured-bot>"},
}

IGNORE = {
    "shared/scripts/seabed_ingest_backfill.py",
    "pod-system/gateway.ts",
    "pod-system/relay-origin-verification.ts",
    "pod-system/relay-quarantine-alert.ts",
    "pod-system/scripts/archive-unregistered-relay-replies.ts",
    "bots/keeper/diana-query.ts",       # relay-diana, not canonical relay/
    "bots/keeper/trigger-batch.ts",     # relay-diana, not canonical relay/
    "shared/hooks/diana-ingest-push.sh",# relay-diana, not canonical relay/
    "bots/sancai/relay_sync.py",        # canonical relay consumer, not writer
}


def fail(message: str) -> None:
    print(f"FAIL relay-origin inventory: {message}", file=sys.stderr)
    raise SystemExit(1)


def repo_files(repo: Path, prefix: str, exclusions: set[str]) -> dict[str, Path]:
    """Return source files from a filesystem walk with explicit exclusions."""
    if not repo.is_dir():
        fail(f"missing source repository: {repo}")
    found: dict[str, Path] = {}
    for current, dirs, files in os.walk(repo, followlinks=False):
        current_path = Path(current)
        kept_dirs = []
        for name in dirs:
            rel_dir = (current_path / name).relative_to(repo).as_posix()
            if any(fnmatch(rel_dir, pattern) or fnmatch(name, pattern) for pattern in exclusions):
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            path = current_path / name
            if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
                continue
            local = path.relative_to(repo).as_posix()
            found[f"{prefix}{local}"] = path
    return found


def writer_path(rel: str) -> Path:
    if rel.startswith("pod-system/"):
        return POD_ROOT / rel.removeprefix("pod-system/")
    if rel.startswith("mvp/"):
        return MVP_ROOT / rel.removeprefix("mvp/")
    return SCAN_ROOT / rel


if not INVENTORY_FILE.is_file():
    fail(f"missing inventory source: {INVENTORY_FILE}")

inventory_text = INVENTORY_FILE.read_text()
match = re.search(r"RELAY_SYSTEM_SENDER_INVENTORY\s*=\s*\[(.*?)\]\s*as const", inventory_text, re.S)
if not match:
    fail("cannot parse RELAY_SYSTEM_SENDER_INVENTORY")
inventory = set(re.findall(r'"([^"]+)"', match.group(1)))
if MIRROR_FILE.is_file():
    mirror_text = MIRROR_FILE.read_text()
    mirror_match = re.search(r"RELAY_SYSTEM_SENDER_INVENTORY\s*=\s*\[(.*?)\]\s*as const", mirror_text, re.S)
    if not mirror_match:
        fail(f"cannot parse mirror inventory: {MIRROR_FILE}")
    mirror = set(re.findall(r'"([^"]+)"', mirror_match.group(1)))
    if mirror != inventory:
        fail(f"inventory mirror drift: {MIRROR_FILE}")

bots: set[str] = set()
for pod in (POD_ROOT / "pods").glob("*.json"):
    try:
        data = json.loads(pod.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    for bot in data.get("bots", []):
        for key in ("name", "username"):
            value = str(bot.get(key, "")).strip().lstrip("@").lower()
            if value:
                bots.add(value)

for rel, senders in WRITERS.items():
    path = writer_path(rel)
    if not path.is_file():
        fail(f"manifest writer missing: {rel}")
    text = path.read_text(errors="replace")
    for sender in senders:
        if sender == "<configured-bot>":
            continue
        if sender not in text:
            fail(f"manifest evidence disappeared: {rel} sender={sender}")
        if sender not in inventory and sender.lower() not in bots:
            fail(f"unregistered writer: {rel} sender={sender}")

    literal_senders = set(
        re.findall(r'''(?:["']?from_bot["']?)\s*:\s*["']([^"']+)["']''', text)
    )
    undeclared = literal_senders - (senders - {"<configured-bot>"})
    if undeclared:
        fail(f"undeclared fixed sender: {rel} sender={sorted(undeclared)[0]}")

sources = repo_files(SCAN_ROOT, "", ROOT_EXCLUDED_DIR_PATTERNS)
sources.update(repo_files(POD_ROOT, "pod-system/", EXCLUDED_DIR_PATTERNS))
sources.update(repo_files(MVP_ROOT, "mvp/", EXCLUDED_DIR_PATTERNS))
from_bot_sources = {
    rel for rel, path in sources.items()
    if "from_bot" in path.read_text(errors="replace")
}
for rel in sorted(from_bot_sources):
    name = Path(rel).name
    if (
        "/tests/" in f"/{rel}"
        or rel.startswith("shared/tests/")
        or rel.endswith("fixture.ts")
        or ".test." in name
        or name.startswith("test_")
    ):
        continue
    if rel.startswith("bots/") and rel.endswith("/start.sh"):
        if "system" not in inventory:
            fail(f"boot writer requires system inventory: {rel}")
        continue
    if rel not in WRITERS and rel not in IGNORE:
        fail(f"unclassified from_bot source: {rel}")

print(
    f"PASS relay-origin inventory: {len(WRITERS)} writer files; "
    f"{len(inventory)} fixed senders; {len(bots)} bot identities; "
    f"{len(from_bot_sources)} classified sources across 3 repositories"
)

#!/usr/bin/env python3
"""inbox_watcher.py — Watch personal vault Inboxes and route .md files into Ocean.

Usage:
  python3 inbox_watcher.py --backfill [vault_key] [--dry-run]
  python3 inbox_watcher.py --watch [--dry-run]
  python3 inbox_watcher.py --list-vaults

Start as daemon (no systemd unit yet — run in tmux or add a unit):
  tmux new-session -d -s inbox-watcher 'python3 ~/.claude-bots/shared/scripts/inbox_watcher.py --watch'

inotify backend: inotify_simple (preferred), falls back to polling via watchdog, then pure polling.
"""

import argparse
import json
import logging
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

HOME = Path.home()
OCEAN_BASE = HOME / "Documents" / "Obsidian Vault" / "Ocean"

VAULTS = {
    "OldRabbit": {
        "path": HOME / "Documents" / "Obsidian Vault - OldRabbit" / "Inbox",
        "owner": "老兔",
    },
    "Ron": {
        "path": HOME / "Documents" / "Obsidian Vault - Ron" / "Inbox",
        "owner": "Ron",
    },
    "Nicky": {
        "path": HOME / "Documents" / "Obsidian Vault - Nicky" / "Inbox",
        "owner": "Nicky",
    },
    "carrot": {
        "path": HOME / "Documents" / "Obsidian Vault - carrot" / "Inbox",
        "owner": "菜姐",
    },
    "桃桃": {
        "path": HOME / "Documents" / "Obsidian Vault - 桃桃" / "Inbox",
        "owner": "桃桃",
    },
    "Wes": {
        "path": HOME / "Documents" / "Obsidian Vault - Wes" / "Inbox",
        "owner": "Wes",
    },
    "Lilai": {
        "path": HOME / "Documents" / "Obsidian Vault - Lilai" / "Inbox",
        "owner": "Lilai",
    },
    "Donna": {
        "path": HOME / "Documents" / "Obsidian Vault - Donna" / "Inbox",
        "owner": "Donna",
    },
}

NOXCAT_KEYWORDS = ["NOXCAT", "NOX_Wallet", "noxcat", "nox_wallet"]
MEETING_KEYWORDS = ["會議記錄", "meeting", "MOM", "minutes"]
SKIP_EXTENSIONS = {".pdf", ".psd", ".ai"}

LOG_DIR = HOME / ".claude-bots" / "logs" / "inbox-watcher"

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("inbox_watcher")


def _log_dir() -> Path:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    return LOG_DIR


def write_log_entry(entry: dict) -> None:
    date_str = datetime.now().strftime("%Y-%m-%d")
    log_file = _log_dir() / f"{date_str}.jsonl"
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def make_entry(
    event: str,
    vault: str,
    src: str,
    dest: str = "",
    route: str = "",
    reason: str = "",
) -> dict:
    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "vault": vault,
        "src": src,
        "dest": dest,
        "route": route,
        "reason": reason,
    }


# ---------------------------------------------------------------------------
# Routing logic
# ---------------------------------------------------------------------------

def _contains_keyword(text: str, keywords: list[str]) -> bool:
    text_lower = text.lower()
    return any(kw.lower() in text_lower for kw in keywords)


def _read_head(path: Path, chars: int = 500) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(chars)
    except Exception:
        return ""


def classify_file(path: Path, vault_key: str) -> tuple[str, Path]:
    """Classify a file and return (route, dest_path).

    Routes: "noxcat" | "meeting" | "drafts"
    """
    name = path.name
    owner = VAULTS[vault_key]["owner"]

    # Meeting filename check first — beats NOXCAT to avoid routing "NOXCAT 週會記錄" as product doc
    if _contains_keyword(name, MEETING_KEYWORDS):
        dest_dir = OCEAN_BASE / "Currents" / "ChannelLab" / "Meetings" / "Seabed"
        return ("meeting", dest_dir / name)

    # NOXCAT check (filename first, then content)
    if _contains_keyword(name, NOXCAT_KEYWORDS) or _contains_keyword(
        _read_head(path), NOXCAT_KEYWORDS
    ):
        dest_dir = OCEAN_BASE / "Currents" / "NOXCAT" / "Product" / "Seabed"
        return ("noxcat", dest_dir / name)

    # Meeting content check (filename didn't match)
    if _contains_keyword(_read_head(path), MEETING_KEYWORDS):
        dest_dir = OCEAN_BASE / "Currents" / "ChannelLab" / "Meetings" / "Seabed"
        return ("meeting", dest_dir / name)

    # Default: Pearl drafts
    dest_dir = OCEAN_BASE / "Pearl" / "_drafts"
    return ("drafts", dest_dir / name)


# ---------------------------------------------------------------------------
# File processing
# ---------------------------------------------------------------------------

def process_file(path: Path, vault_key: str, dry_run: bool = False) -> dict:
    """Process a single file. Returns a log entry dict."""
    name = path.name
    vault_info = VAULTS[vault_key]
    src_str = str(path)

    # Must be a top-level file (not in subdir)
    if path.parent != vault_info["path"]:
        entry = make_entry("skip", vault_key, src_str, reason="not_top_level")
        logger.debug("skip (not top-level): %s", src_str)
        return entry

    # Must be a file, not a directory
    if not path.is_file():
        entry = make_entry("skip", vault_key, src_str, reason="not_a_file")
        return entry

    # Only process .md files
    suffix = path.suffix.lower()
    if suffix != ".md":
        reason = "skipped_extension"
        entry = make_entry("skip", vault_key, src_str, reason=reason)
        logger.debug("skip (%s): %s", reason, name)
        return entry

    route, dest_path = classify_file(path, vault_key)
    dest_str = str(dest_path)

    # Idempotency: skip if destination already exists
    if dest_path.exists():
        entry = make_entry("skip", vault_key, src_str, dest_str, route, "skipped_exists")
        logger.info("skip (exists): %s → %s", name, dest_path)
        write_log_entry(entry)
        return entry

    if dry_run:
        entry = make_entry("ingest", vault_key, src_str, dest_str, route, "dry_run")
        logger.info("[DRY-RUN] would copy: %s → %s (route=%s)", name, dest_path, route)
        return entry

    # Copy to Ocean dest, then move original to _processed/
    try:
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(path), str(dest_path))
        # Delete original — content is now in Ocean, no need to keep it
        path.unlink()
        entry = make_entry("ingest", vault_key, src_str, dest_str, route)
        logger.info("ingest: %s → %s, deleted original", name, dest_path)
        write_log_entry(entry)
        return entry
    except Exception as e:
        entry = make_entry("error", vault_key, src_str, dest_str, route, str(e))
        logger.error("error processing %s: %s", name, e)
        write_log_entry(entry)
        return entry


# ---------------------------------------------------------------------------
# Backfill
# ---------------------------------------------------------------------------

def backfill(vault_key: str, dry_run: bool = False) -> list[dict]:
    """Process all existing .md files in a vault's Inbox. Returns list of log entries."""
    if vault_key not in VAULTS:
        logger.error("Unknown vault key: %s. Valid keys: %s", vault_key, list(VAULTS.keys()))
        return []

    inbox_path = VAULTS[vault_key]["path"]
    if not inbox_path.exists():
        logger.warning("Inbox does not exist: %s", inbox_path)
        return []

    logger.info("Backfill vault=%s inbox=%s dry_run=%s", vault_key, inbox_path, dry_run)
    results = []

    for item in sorted(inbox_path.iterdir()):
        if item.is_dir():
            logger.debug("skip (directory): %s", item.name)
            continue
        entry = process_file(item, vault_key, dry_run=dry_run)
        results.append(entry)

    # Summary
    ingested = [r for r in results if r["event"] == "ingest"]
    skipped = [r for r in results if r["event"] == "skip"]
    errors = [r for r in results if r["event"] == "error"]
    logger.info(
        "Backfill done: total=%d ingested=%d skipped=%d errors=%d",
        len(results),
        len(ingested),
        len(skipped),
        len(errors),
    )
    return results


# ---------------------------------------------------------------------------
# Watch loop
# ---------------------------------------------------------------------------

def _try_inotify_simple(vaults_to_watch: list[str], dry_run: bool) -> bool:
    """Try to use inotify_simple. Returns False if not available."""
    try:
        import inotify_simple  # type: ignore
    except ImportError:
        return False

    import inotify_simple as ins

    inotify = ins.INotify()
    flags = ins.flags.CLOSE_WRITE | ins.flags.MOVED_TO

    wd_to_vault: dict[int, str] = {}
    for vault_key, info in VAULTS.items():
        inbox = info["path"]
        if not inbox.exists():
            logger.warning("Inbox missing, skipping watch: %s", inbox)
            continue
        wd = inotify.add_watch(str(inbox), flags)
        wd_to_vault[wd] = vault_key
        logger.info("Watching (inotify_simple): %s", inbox)

    logger.info("inotify_simple watch loop started.")
    while True:
        events = inotify.read(timeout=5000)
        for event in events:
            if not event.name:
                continue
            vault_key = wd_to_vault.get(event.wd)
            if vault_key is None:
                continue
            inbox = VAULTS[vault_key]["path"]
            file_path = inbox / event.name
            if file_path.is_file():
                process_file(file_path, vault_key, dry_run=dry_run)
    return True


def _polling_watch(vaults_to_watch: list[str], dry_run: bool, interval: float = 5.0) -> None:
    """Fallback: poll every interval seconds for new files."""
    seen: dict[str, set[str]] = {k: set() for k in VAULTS}

    # Initialize seen with existing files to avoid re-processing on start
    for vault_key, info in VAULTS.items():
        inbox = info["path"]
        if inbox.exists():
            for item in inbox.iterdir():
                seen[vault_key].add(item.name)

    logger.info("Polling watch loop started (interval=%.1fs).", interval)
    while True:
        for vault_key, info in VAULTS.items():
            inbox = info["path"]
            if not inbox.exists():
                continue
            current = {item.name for item in inbox.iterdir() if item.is_file()}
            new_files = current - seen[vault_key]
            for fname in new_files:
                file_path = inbox / fname
                process_file(file_path, vault_key, dry_run=dry_run)
                seen[vault_key].add(fname)
        time.sleep(interval)


def watch_loop(dry_run: bool = False) -> None:
    """Start the inotify-based watch daemon."""
    vault_keys = list(VAULTS.keys())

    # Try inotify_simple first
    if _try_inotify_simple(vault_keys, dry_run):
        return  # Never returns normally

    # Fall back to polling
    logger.warning("inotify_simple not available — using polling fallback (5s interval)")
    _polling_watch(vault_keys, dry_run)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="inbox_watcher — route personal Obsidian Inbox .md files into Ocean"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without copying any files",
    )
    parser.add_argument(
        "--backfill",
        metavar="VAULT_KEY",
        nargs="?",
        const="ALL",
        help=(
            "Backfill existing Inbox files. "
            "Specify vault key (e.g. '桃桃') or omit for ALL vaults."
        ),
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Start the inotify-based watcher daemon",
    )
    parser.add_argument(
        "--list-vaults",
        action="store_true",
        help="List configured vaults and exit",
    )
    args = parser.parse_args()

    if args.list_vaults:
        for key, info in VAULTS.items():
            exists = "✓" if info["path"].exists() else "✗"
            print(f"  [{exists}] {key:12s} owner={info['owner']:6s}  {info['path']}")
        return

    if args.backfill is not None:
        if args.backfill == "ALL":
            for vault_key in VAULTS:
                backfill(vault_key, dry_run=args.dry_run)
        else:
            results = backfill(args.backfill, dry_run=args.dry_run)
            # Print summary to stdout for easy verification
            print(f"\n{'='*60}")
            print(f"Backfill results for vault={args.backfill} (dry_run={args.dry_run})")
            print(f"{'='*60}")
            for r in results:
                if r["event"] != "skip" or r.get("reason") not in ("not_a_file", "not_top_level"):
                    print(
                        f"  [{r['event']:6s}] {Path(r['src']).name[:50]}"
                        + (f" → route={r['route']}" if r.get("route") else "")
                        + (f" ({r['reason']})" if r.get("reason") else "")
                    )
        return

    if args.watch:
        watch_loop(dry_run=args.dry_run)
        return

    parser.print_help()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
ocean_watch.py — Ocean vault .md inotify daemon for MEMO-013.

Watches ~/Documents/Obsidian Vault/Ocean/ for .md file changes,
excludes Ocean/原檔海床/, debounces 30s, then encodes + stores to Radar.

AC1: Ocean .md change → memory.db radar updated within 30s
AC2: Ocean/原檔海床/ excluded
AC3: 30s debounce per file
AC4: runs as systemd user service with auto-restart
AC5: logs to ~/.claude-bots/logs/ocean-watch.log
AC6: PID file at ~/.claude-bots/bots/anya/ocean-watch.pid

Stage 1.2 (GBrain sync):
  Set OCEAN_WATCH_USE_GBRAIN=true to also push changes to GBrain via
  `gbrain put <slug>`. Gated by privacy.assert_under_ocean(). Failures
  are logged but never interrupt Radar encode.
"""

import os
import shutil
import sys
import subprocess
import threading
import time
import logging
import signal
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
OCEAN_VAULT = Path.home() / "Documents" / "Obsidian Vault" / "Ocean"
EXCLUDE_DIR  = OCEAN_VAULT / "Seabed"
LOG_FILE     = Path.home() / ".claude-bots" / "logs" / "ocean-watch.log"
PID_FILE     = Path.home() / ".claude-bots" / "state" / "anya" / "ocean-watch.pid"
CLSC_DIR     = Path.home() / ".claude-bots" / "shared" / "memocean-mcp" / "clsc"
MEMOCEAN_PKG = Path.home() / ".claude-bots" / "shared" / "memocean-mcp"
DEBOUNCE_SEC = 30
GBRAIN_BIN   = shutil.which("gbrain") or str(Path.home() / ".bun" / "bin" / "gbrain")
_USE_GBRAIN  = os.environ.get("OCEAN_WATCH_USE_GBRAIN", "false").lower() == "true"

# ── Logging ────────────────────────────────────────────────────────────────────
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("ocean-watch")

# ── PID file ───────────────────────────────────────────────────────────────────
def write_pid():
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    log.info(f"PID {os.getpid()} written to {PID_FILE}")

def remove_pid():
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass

# ── GBrain put helper (Stage 1.2) ─────────────────────────────────────────────
def _gbrain_put(note_path: str) -> None:
    """
    Push a single Ocean .md file to GBrain using `gbrain put <slug>`.
    Privacy-gated: silently skips if path resolves outside Ocean vault.
    All failures are logged and swallowed — Radar encode is unaffected.
    """
    # Lazy-import privacy gate (avoids hard dep if pkg not on path)
    pkg_str = str(MEMOCEAN_PKG)
    if pkg_str not in sys.path:
        sys.path.insert(0, pkg_str)
    try:
        from memocean_mcp.privacy import assert_under_ocean, PrivacyViolation
        from memocean_mcp.slug_mapper import path_to_slug
    except ImportError as exc:
        log.warning(f"gbrain_put: cannot import memocean_mcp ({exc}), skipping")
        return

    try:
        safe_path = assert_under_ocean(note_path)
    except Exception as exc:
        log.warning(f"gbrain_put: privacy gate blocked {note_path!r}: {exc}")
        return

    slug = path_to_slug(safe_path)
    if not slug:
        log.warning(f"gbrain_put: empty slug for {note_path!r}, skipping")
        return

    if not os.path.isfile(GBRAIN_BIN):
        log.warning("gbrain_put: gbrain binary not found, skipping")
        return

    try:
        with open(safe_path, "rb") as fh:
            r = subprocess.run(
                [GBRAIN_BIN, "put", slug],
                stdin=fh,
                capture_output=True,
                timeout=10.0,
            )
        if r.returncode == 0:
            log.info(f"gbrain put OK slug={slug} path={note_path}")
        else:
            log.warning(
                f"gbrain put exit={r.returncode} slug={slug} "
                f"stderr={r.stderr[:200].decode('utf-8','replace')}"
            )
    except subprocess.TimeoutExpired:
        log.warning(f"gbrain put timeout (10s) slug={slug}")
    except Exception as exc:
        log.error(f"gbrain put unexpected error slug={slug}: {exc}", exc_info=True)


# ── CLSC encode helper ─────────────────────────────────────────────────────────
def encode_file(note_path: str) -> None:
    """Import clsc modules and encode+store the given note."""
    # Add clsc dir to sys.path so we can import radar + hancloset
    clsc_str = str(CLSC_DIR)
    if clsc_str not in sys.path:
        sys.path.insert(0, clsc_str)

    try:
        from hancloset import encode_and_store
        from radar import group_from_path

        t0 = time.monotonic()
        group = group_from_path(note_path)
        result = encode_and_store(note_path, group)
        elapsed = time.monotonic() - t0

        slug   = result.get("slug", Path(note_path).stem)
        tokens = result.get("raw_tokens", 0)
        log.info(f"ingested slug={slug} group={group} tokens={tokens} elapsed={elapsed:.2f}s path={note_path}")
    except Exception as exc:
        log.error(f"encode_and_store failed for {note_path}: {exc}", exc_info=True)

# ── Debounce registry ──────────────────────────────────────────────────────────
_timers: dict[str, threading.Timer] = {}
_timers_lock = threading.Lock()

def schedule_encode(note_path: str) -> None:
    """Cancel any existing debounce timer and schedule a new one."""
    with _timers_lock:
        existing = _timers.get(note_path)
        if existing is not None:
            existing.cancel()
        t = threading.Timer(DEBOUNCE_SEC, _fire_encode, args=[note_path])
        _timers[note_path] = t
        t.daemon = True
        t.start()
    log.debug(f"debounce scheduled ({DEBOUNCE_SEC}s) for {note_path}")

def _fire_encode(note_path: str) -> None:
    with _timers_lock:
        _timers.pop(note_path, None)
    if not Path(note_path).exists():
        log.debug(f"skipping deleted file: {note_path}")
        return
    encode_file(note_path)
    # Stage 1.2: also push to GBrain (gated by OCEAN_WATCH_USE_GBRAIN)
    if _USE_GBRAIN:
        _gbrain_put(note_path)

# ── Should-watch predicate ─────────────────────────────────────────────────────
def should_watch(path: str) -> bool:
    p = Path(path)
    # must be .md
    if p.suffix.lower() != ".md":
        return False
    # exclude Seabed subdir (AC2)
    try:
        p.relative_to(EXCLUDE_DIR)
        return False  # inside Seabed/
    except ValueError:
        pass
    # must be inside Ocean vault
    try:
        p.relative_to(OCEAN_VAULT)
        return True
    except ValueError:
        return False

# ── inotifywait watcher ────────────────────────────────────────────────────────
def run_inotifywait() -> None:
    """
    Run inotifywait -m -r on Ocean vault, parse output lines.
    Excludes Seabed/ via --exclude pattern.
    """
    exclude_pattern = str(EXCLUDE_DIR).replace("/", r"\/")

    cmd = [
        "inotifywait",
        "-m", "-r",
        "--format", "%w%f\t%e",
        "--event", "close_write,moved_to,create",
        "--exclude", str(EXCLUDE_DIR),
        str(OCEAN_VAULT),
    ]

    log.info(f"Starting inotifywait on {OCEAN_VAULT} (excluding {EXCLUDE_DIR})")

    while True:
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                path_str, event = parts[0], parts[1]

                if should_watch(path_str):
                    log.debug(f"event={event} path={path_str}")
                    schedule_encode(path_str)

            proc.wait()
            log.warning(f"inotifywait exited with code {proc.returncode}, restarting in 5s...")
            time.sleep(5)

        except Exception as exc:
            log.error(f"inotifywait error: {exc}, restarting in 5s...")
            time.sleep(5)

# ── Signal handling ────────────────────────────────────────────────────────────
def _shutdown(signum, frame):
    log.info(f"Received signal {signum}, shutting down...")
    remove_pid()
    # Cancel pending timers
    with _timers_lock:
        for t in _timers.values():
            t.cancel()
    sys.exit(0)

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    if not OCEAN_VAULT.exists():
        log.error(f"Ocean vault not found: {OCEAN_VAULT}")
        sys.exit(1)

    write_pid()
    gbrain_state = f"gbrain=ON ({GBRAIN_BIN})" if _USE_GBRAIN else "gbrain=OFF"
    log.info(f"ocean-watch started. vault={OCEAN_VAULT} debounce={DEBOUNCE_SEC}s {gbrain_state}")

    try:
        run_inotifywait()
    finally:
        remove_pid()

if __name__ == "__main__":
    main()

"""
closet_get.py — Closet content retrieval wrapper.
Delegates to ~/.claude-bots/shared/clsc/v0.7/decoder.py.

Modes:
  verbatim — fetch original drawer content by slug (no LLM)
  skeleton — read raw closet bundle skeleton text
"""
import re
import sys
from pathlib import Path
from typing import Literal

from ..config import SHARED_ROOT, CLOSET_ROOT

_SAFE_SLUG_RE = re.compile(r'^[A-Za-z0-9_\-]{1,100}$')


def _validate_slug(slug: str) -> None:
    """Reject slugs that could escape the sandbox via path traversal."""
    if not _SAFE_SLUG_RE.match(slug):
        raise ValueError(f"Invalid slug '{slug}': must match [A-Za-z0-9_-]{{1,100}}")

_CLSC_DIR = SHARED_ROOT / "clsc" / "v0.7"


def _import_decoder():
    """Lazy import decoder module."""
    clsc_str = str(_CLSC_DIR)
    if clsc_str not in sys.path:
        sys.path.insert(0, clsc_str)
    import importlib
    return importlib.import_module("decoder")


def verbatim_fetch(slug: str) -> str:
    """
    Mode (i): fetch original drawer content by slug.
    Searches Obsidian Wiki and fallback dirs.
    Returns file content or '[drawer not found for {slug}]'.
    """
    _validate_slug(slug)
    if not _CLSC_DIR.exists():
        return f"[clsc module not found at {_CLSC_DIR}]"
    decoder = _import_decoder()
    return decoder.verbatim_fetch(slug)


def skeleton_read(slug: str) -> str:
    """
    Mode (ii): read a raw closet bundle skeleton file directly from CLOSET_ROOT.
    Returns file content, or an error message if not found.
    """
    _validate_slug(slug)
    if not CLOSET_ROOT.exists():
        return f"[closet root not found at {CLOSET_ROOT}]"

    # Try slug.json or slug.md under CLOSET_ROOT
    for ext in (".json", ".md", ".txt", ""):
        path = CLOSET_ROOT / f"{slug}{ext}"
        # Confirm resolved path is still under CLOSET_ROOT (defense in depth)
        if path.resolve().is_relative_to(CLOSET_ROOT.resolve()) and path.exists():
            return path.read_text(encoding="utf-8")

    return f"[closet bundle not found for slug: {slug}]"


def closet_get(slug: str, mode: Literal["verbatim", "skeleton"] = "verbatim") -> str:
    """
    Unified entry point.
    mode='verbatim' → verbatim_fetch(slug)
    mode='skeleton' → skeleton_read(slug)
    """
    if mode == "verbatim":
        return verbatim_fetch(slug)
    elif mode == "skeleton":
        return skeleton_read(slug)
    else:
        return f"[unknown mode: {mode}. Use 'verbatim' or 'skeleton']"

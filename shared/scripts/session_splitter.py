#!/usr/bin/env python3
"""
session_splitter.py — Split a Claude Code JSONL transcript into session segments,
distinguishing true new sessions from context-restore continuations (post-compact
or --resume boot).

Forked from upstream mempalace/split_mega_files.py L95-112 (is_true_session_start +
find_session_boundaries). Upstream targeted plain-text transcripts and looked for
"Claude Code v" + "Ctrl+E" / "previous messages". Our transcripts live at
~/.claude/projects/<slug>/<uuid>.jsonl and use a different, structured marker set.

Header marker (our format)
--------------------------
Each Claude Code boot writes a `{"type":"permission-mode", ...}` line. That's our
analogue of "Claude Code v".

Context-restore detection
-------------------------
If within the next 6 lines we see a `compact_boundary` system event (post-/compact
or context rehydration), OR any line mentioning "Ctrl+E" / "previous messages"
(defensive — also catches any plain-text chunks), the header is a context restore,
NOT a true new session.

CLI
---
    session_splitter.py <file.jsonl>        # print boundary table
    session_splitter.py --self-test         # run the bundled unit tests

Library
-------
    find_session_boundaries(lines) -> list[(start, end, is_true_start)]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import List, Tuple

LOOKAHEAD = 6
HEADER_SUBSTR = '"type":"permission-mode"'
RESTORE_SUBSTRS = ('compact_boundary', 'Ctrl+E', 'previous messages')


def is_header(line: str) -> bool:
    """True if this line is a session-boot header."""
    return HEADER_SUBSTR in line


def is_true_session_start(lines: List[str], idx: int) -> bool:
    """
    True session start = header NOT followed by a context-restore marker within the
    next LOOKAHEAD lines. Mirrors upstream split_mega_files.py L83-89.
    """
    nearby = "".join(lines[idx + 1 : idx + 1 + LOOKAHEAD])
    return not any(marker in nearby for marker in RESTORE_SUBSTRS)


def find_session_boundaries(lines: List[str]) -> List[Tuple[int, int, bool]]:
    """
    Return [(start_line, end_line, is_true_start), ...] with 0-based inclusive
    start and exclusive end. Every header line opens a segment; its is_true_start
    flag says whether it is a brand-new session or a context-restore continuation.

    If the file has no header at all, returns a single span covering the whole file
    marked is_true_start=True (degenerate fallback).
    """
    header_idxs: List[Tuple[int, bool]] = []
    for i, line in enumerate(lines):
        if is_header(line):
            header_idxs.append((i, is_true_session_start(lines, i)))

    if not header_idxs:
        return [(0, len(lines), True)] if lines else []

    # Force first segment to start at line 0 even if header isn't on line 0.
    segments: List[Tuple[int, int, bool]] = []
    starts = [idx for idx, _ in header_idxs]
    flags = [flag for _, flag in header_idxs]
    if starts[0] != 0:
        starts.insert(0, 0)
        flags.insert(0, True)  # pre-header prelude counted as a true segment
    starts.append(len(lines))
    for i in range(len(starts) - 1):
        segments.append((starts[i], starts[i + 1], flags[i]))
    return segments


def count_true_sessions(segments) -> int:
    return sum(1 for _, _, t in segments if t)


def _load_lines(path: Path) -> List[str]:
    return path.read_text(errors="replace").splitlines(keepends=True)


def print_boundary_table(path: Path) -> None:
    lines = _load_lines(path)
    segs = find_session_boundaries(lines)
    print(f"{path}  ({len(lines)} lines, {len(segs)} segments, "
          f"{count_true_sessions(segs)} true sessions)")
    print(f"{'idx':>4}  {'start':>6}  {'end':>6}  {'len':>6}  kind")
    for i, (s, e, t) in enumerate(segs):
        kind = "NEW" if t else "restore"
        print(f"{i:>4}  {s:>6}  {e:>6}  {e - s:>6}  {kind}")


# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------

def _run_self_test() -> int:
    import unittest

    PERM = '{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"s1"}\n'
    USER = '{"type":"user","content":"hi"}\n'
    COMPACT = '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n'
    ASSIST = '{"type":"assistant","content":"ok"}\n'

    class TestBoundaries(unittest.TestCase):
        def test_single_true_session(self):
            lines = [PERM] + [USER, ASSIST] * 20
            segs = find_session_boundaries(lines)
            self.assertEqual(len(segs), 1)
            self.assertTrue(segs[0][2])

        def test_two_true_sessions(self):
            lines = [PERM] + [USER, ASSIST] * 10 + [PERM] + [USER, ASSIST] * 10
            segs = find_session_boundaries(lines)
            self.assertEqual(len(segs), 2)
            self.assertTrue(all(t for _, _, t in segs))
            self.assertEqual(count_true_sessions(segs), 2)

        def test_three_true_sessions(self):
            lines = ([PERM] + [USER, ASSIST] * 5) * 3
            segs = find_session_boundaries(lines)
            self.assertEqual(count_true_sessions(segs), 3)

        def test_context_restore_after_compact(self):
            # header followed by compact_boundary within 6 lines = restore
            lines = [PERM] + [USER, ASSIST] * 5 + [PERM, COMPACT] + [USER, ASSIST] * 5
            segs = find_session_boundaries(lines)
            self.assertEqual(len(segs), 2)
            self.assertTrue(segs[0][2])       # first boot is new
            self.assertFalse(segs[1][2])      # second boot is a restore
            self.assertEqual(count_true_sessions(segs), 1)

        def test_context_restore_plaintext_marker(self):
            # Defensive: plain-text "Ctrl+E" marker inside next 6 lines also counts.
            lines = [PERM, USER, 'Ctrl+E to show 42 previous messages\n', ASSIST] + [USER] * 10
            segs = find_session_boundaries(lines)
            self.assertEqual(len(segs), 1)
            self.assertFalse(segs[0][2])
            self.assertEqual(count_true_sessions(segs), 0)

    loader = unittest.TestLoader()
    suite = loader.loadTestsFromTestCase(TestBoundaries)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def main(argv: List[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[1] == "--self-test":
        return _run_self_test()
    path = Path(argv[1]).expanduser()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 2
    print_boundary_table(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

"""
test_skip_variants.py — Fixture-based tests for _should_skip / _is_numbered_duplicate.

Creates real files in a temp directory so filesystem-check logic works correctly.
Run:  python3 tests/test_skip_variants.py
Exit: 0 = all pass, 1 = failure
"""
import sys
import tempfile
import traceback
from pathlib import Path

# Add v0.7 to path
sys.path.insert(0, str(Path(__file__).parent.parent))
import backfill_closet as b

_should_skip = b._should_skip
_is_numbered_duplicate = b._is_numbered_duplicate

passed = 0
failed = 0


def check(label: str, got: bool, expected: bool) -> None:
    global passed, failed
    if got == expected:
        print(f"  ✅ {label}")
        passed += 1
    else:
        print(f"  ❌ {label} — expected {expected}, got {got}")
        failed += 1


def run_tests() -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        # --- Fixtures: conflict copies (SHOULD be skipped) ---
        (tmp / "note.md").write_text("original")
        (tmp / "note 2.md").write_text("conflict copy")   # skip: original exists
        (tmp / "note 3.md").write_text("another copy")    # skip: original exists

        # Multi-word base name conflict
        (tmp / "meeting notes.md").write_text("original")
        (tmp / "meeting notes 2.md").write_text("conflict")  # skip

        # .stversions directory
        stver = tmp / ".stversions"
        stver.mkdir()
        (stver / "archived.md").write_text("version")      # skip: inside .stversions

        # sync-conflict files
        (tmp / "foo.sync-conflict-20260101-120000-ABC.md").write_text("conflict")  # skip

        # Hidden file
        (tmp / ".hidden.md").write_text("hidden")           # skip: starts with .

        # --- Fixtures: legitimate files (MUST NOT be skipped) ---
        (tmp / "GCP Phase 2.md").write_text("legit: no 'GCP Phase.md' exists")
        (tmp / "Q4 2026.md").write_text("legit: ends with year, not ' N'")
        (tmp / "2026 計畫.md").write_text("legit: starts with number")
        (tmp / "Phase 3 設計.md").write_text("legit: number mid-stem")
        (tmp / "NOXCAT_OTC_PRD_v2.md").write_text("legit: version suffix no space")

        # note.md itself must not be skipped (it's the original)
        # (already written above)

        print("\n=== conflict copies (must be skipped) ===")
        check("note 2.md — skip (original note.md exists)",
              _should_skip(tmp / "note 2.md"), True)
        check("note 3.md — skip (original note.md exists)",
              _should_skip(tmp / "note 3.md"), True)
        check("meeting notes 2.md — skip (original exists)",
              _should_skip(tmp / "meeting notes 2.md"), True)
        check(".stversions/archived.md — skip (in ignored dir)",
              _should_skip(stver / "archived.md"), True)
        check("foo.sync-conflict-*.md — skip",
              _should_skip(tmp / "foo.sync-conflict-20260101-120000-ABC.md"), True)
        check(".hidden.md — skip (dot-file)",
              _should_skip(tmp / ".hidden.md"), True)

        print("\n=== legitimate files (must NOT be skipped) ===")
        check("note.md — not skipped (original)",
              _should_skip(tmp / "note.md"), False)
        check("GCP Phase 2.md — not skipped (no GCP Phase.md nearby)",
              _should_skip(tmp / "GCP Phase 2.md"), False)
        check("Q4 2026.md — not skipped (stem doesn't end with ' N')",
              _should_skip(tmp / "Q4 2026.md"), False)
        check("2026 計畫.md — not skipped",
              _should_skip(tmp / "2026 計畫.md"), False)
        check("Phase 3 設計.md — not skipped",
              _should_skip(tmp / "Phase 3 設計.md"), False)
        check("NOXCAT_OTC_PRD_v2.md — not skipped (no space before digit)",
              _should_skip(tmp / "NOXCAT_OTC_PRD_v2.md"), False)

        # Edge: numbered file with no original → not a conflict copy
        (tmp / "standalone 5.md").write_text("legit: no standalone.md")
        check("standalone 5.md — not skipped (standalone.md does not exist)",
              _should_skip(tmp / "standalone 5.md"), False)

    print(f"\n{'='*40}")
    print(f"RESULT: {passed} pass, {failed} fail")
    if failed:
        print("FAILED ❌")
        return 1
    print("ALL PASSED ✅")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_tests())
    except Exception:
        traceback.print_exc()
        sys.exit(1)

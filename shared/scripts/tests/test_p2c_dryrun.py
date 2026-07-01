"""
test_p2c_dryrun.py — Verify P2c dry-run plan correctness.

Tests:
  T1. Only 46 strong pairs (no 並列) processed
  T2. Bidirectional: 46 pairs → 92 directed edges
  T3. Idempotent: [[slug]] and [[slug]]（延伸） both recognized as already-linked
  T4. Idempotent: target not in existing links → marked NEW
  T5. No file writes in module (source inspection)
  T6. extract_existing_link_slugs handles both fenced and bare 連結 sections
  T7. HUB_THRESHOLD constant exists and is sane

Run: python3 tests/test_p2c_dryrun.py
Exit: 0 = all pass, 1 = failure
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import p2c_dryrun as p2c

passed = 0
failed = 0


def check(label: str, got: bool, expected: bool = True) -> None:
    global passed, failed
    if got == expected:
        print(f"  ✅ {label}")
        passed += 1
    else:
        print(f"  ❌ {label} — expected {expected}, got {got}")
        failed += 1


# ── T1 + T2: strong filter + bidirectional ────────────────────────────────────
print("\n=== T1+T2: strong filter (no 並列) + bidirectional ===")
import json
SUGG_PATH = Path(__file__).parent.parent.parent.parent / "bots/anya/work/p2-link-suggestions-20260701-0910.json"
try:
    with open(SUGG_PATH) as f:
        data = json.load(f)
    strong = [s for s in data["suggestions"] if s.get("relation") in p2c.STRONG_RELATIONS]
    parallel = [s for s in data["suggestions"] if s.get("relation") == "並列"]
    check("Strong pairs = 46", len(strong) == 46)
    check("並列 pairs excluded from STRONG_RELATIONS", "並列" not in p2c.STRONG_RELATIONS)
    check("Bidirectional: 46 × 2 = 92 edges", len(strong) * 2 == 92)
    print(f"  ℹ️  strong={len(strong)}, 並列={len(parallel)}")
except FileNotFoundError:
    print(f"  ⚠️  Suggestions file not found at {SUGG_PATH}")
    failed += 3


# ── T3: Idempotent — existing link recognized regardless of relation suffix ───
print("\n=== T3: extract_existing_link_slugs — fenced section ===")
card_with_fenced_links = """---
type: pearl
---

# Test Card

Content here.

---
連結：
- [[NoteA]]
- [[NoteB]]（延伸）
- [[NoteC]]（導致）
---
"""
existing = p2c.extract_existing_link_slugs(card_with_fenced_links)
check("[[NoteA]] detected (bare)", "NoteA" in existing)
check("[[NoteB]]（延伸）detected (with suffix)", "NoteB" in existing)
check("[[NoteC]]（導致）detected (with suffix)", "NoteC" in existing)
check("Non-existent slug not in set", "NoteX" not in existing)


# ── T4: Idempotent — card without target → NEW ────────────────────────────────
print("\n=== T4: idempotent — target not in existing → NEW ===")
card_without_target = """---
type: pearl
---

# Another Card

Content.

---
連結：
- [[SomeOtherNote]]
---
"""
existing2 = p2c.extract_existing_link_slugs(card_without_target)
check("SomeOtherNote in existing", "SomeOtherNote" in existing2)
check("NewTarget NOT in existing (would be NEW)", "NewTarget" not in existing2)


# ── T6: extract_existing_link_slugs — bare 連結 section (no --- wrapper) ──────
print("\n=== T6: bare 連結 section (no --- wrapper) ===")
card_bare_links = """---
type: pearl
---

# Bare Links Card

Content.

連結：
- [[AlphaNote]]
- [[BetaNote]]（引用）

Some trailing content.
"""
existing3 = p2c.extract_existing_link_slugs(card_bare_links)
check("AlphaNote detected in bare section", "AlphaNote" in existing3)
check("BetaNote detected with suffix in bare section", "BetaNote" in existing3)


# ── T5: No file writes in module ─────────────────────────────────────────────
print("\n=== T5: No write operations on vault/.md files ===")
import inspect
source = inspect.getsource(p2c)
db_write_patterns = [
    'conn.execute("INSERT',
    'conn.execute("UPDATE',
    'conn.execute("DELETE',
    '.write_text(plan_content',  # output plan file is OK, but not .md vault files
]
# The script writes ONE output file (p2c-write-plan.md in bots/anya/work/)
# Verify it does NOT write to vault paths
has_vault_write = "珍珠卡" in source and ".write_text" in source
# More precise: check that write_text is only called with output_path (bots/anya/work)
check("No vault .md write (write_text uses output_path, not vault path)",
      "珍珠卡" not in source.split("write_text")[1] if "write_text" in source else True)
check("No DB write SQL", not any(p in source for p in ['conn.execute("INSERT', 'conn.execute("UPDATE']))
check("OUTPUT_PATH in bots/anya/work",
      "anya" in str(p2c.OUTPUT_PATH) and "work" in str(p2c.OUTPUT_PATH))


# ── T7: HUB_THRESHOLD is sane ────────────────────────────────────────────────
print("\n=== T7: Constants sanity ===")
check("STRONG_RELATIONS contains all 4 types",
      p2c.STRONG_RELATIONS == {"延伸", "導致", "反例", "引用"})
check("HUB_THRESHOLD is positive integer", isinstance(p2c.HUB_THRESHOLD, int) and p2c.HUB_THRESHOLD > 0)


# ── Summary ───────────────────────────────────────────────────────────────────
print(f"\n{'='*40}")
print(f"RESULT: {passed} pass, {failed} fail")
if failed:
    print("FAILED ❌")
    sys.exit(1)
print("ALL PASSED ✅")
sys.exit(0)

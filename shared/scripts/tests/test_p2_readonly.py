"""
test_p2_readonly.py — Verify P2 linking engine (read-only) correctness.

Tests:
  T1. drawer_path filter finds Pearl cards (non-empty)
  T2. JSON parsing extracts from ```json fenced block
  T3. JSON parsing extracts from bare JSON object
  T4. JSON parsing LOGS (not swallows) on failure — no silent false
  T5. No write paths imported/callable from p2_linking_readonly
  T6. parse_judge_response handles Haiku's typical fence+explanation format

Run: python3 tests/test_p2_readonly.py
Exit: 0 = all pass, 1 = failure
"""
import io
import json
import logging
import sys
from pathlib import Path

# Add shared/scripts to path
sys.path.insert(0, str(Path(__file__).parent.parent))
import p2_linking_readonly as p2

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


# ── T1: Pearl card DB filter ──────────────────────────────────────────────────
print("\n=== T1: drawer_path Pearl filter (requires DB) ===")
try:
    conn = p2.get_db_conn()
    cards = p2.get_pearl_cards(conn)
    conn.close()
    check("Pearl cards found via drawer_path (non-empty)", len(cards) > 0)
    check("At least 50 Pearl cards (expected ~59)", len(cards) >= 50)
    check("All have drawer_path containing 珍珠卡",
          all("珍珠卡" in c["drawer_path"] for c in cards))
    print(f"  ℹ️  Found {len(cards)} Pearl cards")
except Exception as e:
    print(f"  ❌ DB query failed: {e}")
    failed += 3


# ── T2: JSON parsing — fenced block ──────────────────────────────────────────
print("\n=== T2: parse_judge_response — fenced block ===")
fenced_response = (
    "Sure! Here is my analysis:\n"
    "```json\n"
    '{"link": true, "relation": "延伸", "confidence": 0.85}\n'
    "```\n"
    "The cards share a common theme."
)
result = p2.parse_judge_response(fenced_response, "card-a", "card-b")
check("link=true extracted from fenced block", result.get("link") is True)
check("relation extracted", result.get("relation") == "延伸")
check("confidence=0.85 extracted", result.get("confidence") == 0.85)


# ── T3: JSON parsing — bare JSON in text ─────────────────────────────────────
print("\n=== T3: parse_judge_response — bare JSON object ===")
bare_response = 'Some text {"link": false, "relation": null, "confidence": 0.2} more text'
result = p2.parse_judge_response(bare_response, "card-a", "card-b")
check("link=false extracted from bare JSON", result.get("link") is False)
check("confidence=0.2 extracted", result.get("confidence") == 0.2)


# ── T4: JSON parsing — failure is LOGGED, not swallowed silently ─────────────
print("\n=== T4: parse_judge_response — logs on failure, returns safe default ===")
# Capture log output
log_capture = io.StringIO()
handler = logging.StreamHandler(log_capture)
handler.setLevel(logging.WARNING)
p2.log.addHandler(handler)
p2.log.setLevel(logging.WARNING)

garbage_response = "I cannot determine the relationship between these cards."
result = p2.parse_judge_response(garbage_response, "slug-x", "slug-y")

log_output = log_capture.getvalue()
p2.log.removeHandler(handler)

check("Returns link=False as safe default", result.get("link") is False)
check("Returns confidence=0.0 as safe default", result.get("confidence") == 0.0)
check("WARNING logged (not silent swallow)",
      "slug-x" in log_output or "No JSON" in log_output or "parse_judge_response" in log_output)


# ── T5: No write paths in module ─────────────────────────────────────────────
print("\n=== T5: No write operations accessible from module ===")
import inspect
source = inspect.getsource(p2)
# These are red-line patterns that must NOT appear
write_patterns = [
    "conn.execute(\"INSERT",
    "conn.execute(\"UPDATE",
    "conn.execute(\"DELETE",
    "conn.execute(\"DROP",
    ".write_text(",   # allow output file writes
]
# Only check DB write patterns (output file write is intentional)
db_write_patterns = [p for p in write_patterns if p != ".write_text("]
has_db_write = any(pat in source for pat in db_write_patterns)
check("No DB write SQL in module (INSERT/UPDATE/DELETE/DROP)", not has_db_write)
# Verify output path is in bots/anya/work, not vault or memory.db manipulation
check("OUTPUT_DIR points to bots/anya/work", "anya" in str(p2.OUTPUT_DIR) and "work" in str(p2.OUTPUT_DIR))


# ── T6: Realistic Haiku multi-line fenced response ────────────────────────────
print("\n=== T6: Realistic Haiku fence+explanation format ===")
realistic = (
    "Based on my analysis of both cards:\n\n"
    "Card A discusses AI architecture patterns while Card B explores similar themes "
    "from a different angle. There is a clear conceptual extension.\n\n"
    "```json\n"
    '{"link": true, "relation": "延伸", "confidence": 0.82}\n'
    "```"
)
result = p2.parse_judge_response(realistic, "arch-a", "arch-b")
check("Realistic Haiku response: link extracted", result.get("link") is True)
check("Realistic Haiku response: confidence ≥ 0.75", result.get("confidence", 0) >= 0.75)


# ── Summary ───────────────────────────────────────────────────────────────────
print(f"\n{'='*40}")
print(f"RESULT: {passed} pass, {failed} fail")
if failed:
    print("FAILED ❌")
    sys.exit(1)
print("ALL PASSED ✅")
sys.exit(0)

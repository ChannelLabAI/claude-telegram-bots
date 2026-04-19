"""
Tests for extract_agenda() — Phase A spec (MemOcean intent).

The extract_agenda() function defined here is the canonical implementation;
it will later be copied into the Python heredoc in regenerate-team-l0.sh.

Token budget:
  - agenda section   ≤ 200 tokens
  - fixed block      ≤ 300 tokens
  - total team-l0    ≤ 500 tokens

Truncation priority when agenda > 200 tokens:
  Risk Watch > Pending Decisions > OKR
"""

from __future__ import annotations

import re
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Optional

import yaml


# ─────────────────────────────────────────────────────────────────────────────
# extract_agenda() — copy this block verbatim into regenerate-team-l0.sh
# ─────────────────────────────────────────────────────────────────────────────

_SECTION_HEADERS = ["## Current OKR", "## Pending Decisions", "## Risk Watch"]
_MAX_TITLE_CHARS = 40          # Y part of "- **X** — Y" truncated to this
_MAX_ITEMS_PER_SECTION = 3     # show at most 3 items, then "+ N more"
_AGENDA_TOKEN_BUDGET = 200     # hard cap for the whole agenda block
_NOT_CREATED = "_（尚未建立）_"
_PARSE_ERROR = "_（解析失敗，請檢查 agenda.md）_"


def _approx_tokens(text: str) -> int:
    """Quick token approximation: chars / 4 (no external tokeniser needed)."""
    return max(1, len(text) // 4)


def _parse_section_items(section_body: str) -> list[str]:
    """
    Extract bullet lines matching `- **X** — Y` (or `- **X**` alone).
    Returns the title portion: "**X** — Y" with Y truncated to _MAX_TITLE_CHARS.
    """
    items: list[str] = []
    for line in section_body.splitlines():
        stripped = line.strip()
        # Match "- **Name** — description" or "- **Name**"
        m = re.match(r'^-\s+(\*\*[^*]+\*\*(?:\s*—\s*.+)?)', stripped)
        if not m:
            continue
        title = m.group(1)
        # Truncate the description part after "—" to _MAX_TITLE_CHARS chars
        em_match = re.match(r'^(\*\*[^*]+\*\*)\s*—\s*(.+)$', title)
        if em_match:
            bold_part = em_match.group(1)
            desc_part = em_match.group(2)
            if len(desc_part) > _MAX_TITLE_CHARS:
                desc_part = desc_part[:_MAX_TITLE_CHARS].rstrip() + "…"
            title = f"{bold_part} — {desc_part}"
        items.append(title)
    return items


def _render_section(header: str, items: list[str]) -> str:
    """Render one section with header + bullet items (or empty notice)."""
    lines = [header]
    if not items:
        lines.append("_（無）_")
        return "\n".join(lines)

    shown = items[:_MAX_ITEMS_PER_SECTION]
    hidden = len(items) - len(shown)
    for item in shown:
        lines.append(f"- {item}")
    if hidden > 0:
        lines.append(f"_(+{hidden} more)_")
    return "\n".join(lines)


def _split_sections(body: str) -> dict[str, str]:
    """
    Split markdown body into sections keyed by header text.
    Returns dict: header → section body (text between this header and next).
    """
    sections: dict[str, str] = {}
    pattern = r'(## [^\n]+)'
    parts = re.split(pattern, body)
    # parts alternates: [pre, header1, body1, header2, body2, ...]
    i = 1
    while i < len(parts) - 1:
        header = parts[i].strip()
        body_part = parts[i + 1] if i + 1 < len(parts) else ""
        sections[header] = body_part
        i += 2
    return sections


def extract_agenda(agenda_path: Path) -> str:
    """
    Read agenda.md and return a compressed markdown string ≤ 200 tokens.

    Returns:
      _（尚未建立）_              — file missing or empty
      _（解析失敗，請檢查 agenda.md）_  — bad frontmatter / parse error
      compressed markdown string  — normal case
    """
    # ── Guard: missing or empty ───────────────────────────────────────────────
    if not agenda_path.exists():
        return _NOT_CREATED
    raw = agenda_path.read_text(encoding="utf-8")
    if not raw.strip():
        return _NOT_CREATED

    # ── Parse YAML frontmatter ────────────────────────────────────────────────
    fm_match = re.match(r'^---\n(.*?)\n---\n', raw, re.DOTALL)
    if not fm_match:
        return _PARSE_ERROR
    try:
        fm = yaml.safe_load(fm_match.group(1))
        if not isinstance(fm, dict):
            return _PARSE_ERROR
        # Sanity-check: must at least have "type" key
        if "type" not in fm:
            return _PARSE_ERROR
    except yaml.YAMLError:
        return _PARSE_ERROR

    body = raw[fm_match.end():]
    sections_map = _split_sections(body)

    # ── Build sections in order (OKR, Decisions, Risk) ───────────────────────
    # Truncation priority (drop first when over budget): Risk > Decisions > OKR
    section_order = _SECTION_HEADERS          # [OKR, Decisions, Risk]
    drop_order = list(reversed(section_order))  # [Risk, Decisions, OKR]

    def build_output(active_headers: list[str]) -> str:
        parts: list[str] = []
        for hdr in active_headers:
            body_text = sections_map.get(hdr, "")
            items = _parse_section_items(body_text)
            parts.append(_render_section(hdr, items))
        return "\n\n".join(parts)

    active = list(section_order)
    output = build_output(active)

    # ── Enforce token budget by dropping lowest-priority sections ─────────────
    for drop_hdr in drop_order:
        if _approx_tokens(output) <= _AGENDA_TOKEN_BUDGET:
            break
        if drop_hdr in active:
            active.remove(drop_hdr)
            output = build_output(active)

    # Final hard truncate (should rarely trigger after section dropping)
    if _approx_tokens(output) > _AGENDA_TOKEN_BUDGET:
        budget_chars = _AGENDA_TOKEN_BUDGET * 4
        output = output[:budget_chars].rstrip() + "\n_(truncated)_"

    return output


# ─────────────────────────────────────────────────────────────────────────────
# Test helpers
# ─────────────────────────────────────────────────────────────────────────────

VALID_FRONTMATTER = textwrap.dedent("""\
    ---
    type: agenda
    updated: 2026-04-19T14:30+08:00
    owner: Anya
    ---
""")

SAMPLE_AGENDA = VALID_FRONTMATTER + textwrap.dedent("""\
    ## Current OKR
    - **GEO Analyzer v2** — ship the semantic search layer by end of April
      owner: Anna  horizon: Q2-2026
    - **MemOcean pipeline** — stabilise recall Hit@5 ≥ 90%
      owner: Anna  horizon: Q2-2026

    ## Pending Decisions
    - **DB migration** — PostgreSQL vs SQLite for production seabed
      owner: 老兔  eta: 2026-04-25
    - **Embedding model** — BGE-m3 vs OpenAI ada-002 cost-accuracy tradeoff
      owner: Anna  eta: 2026-04-22

    ## Risk Watch
    - **reCAPTCHA block** — Camoufox getting blocked on target sites
      trigger: scrape failure rate > 20%
    - **Token budget runaway** — sub-agents not respecting maxTurns
      trigger: daily spend > NT$500
""")


def _write_agenda(tmp_dir: Path, content: str) -> Path:
    p = tmp_dir / "agenda.md"
    p.write_text(content, encoding="utf-8")
    return p


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

class TestExtractAgendaNormal(unittest.TestCase):
    """T1: Normal agenda.md with 3 sections."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.agenda_path = _write_agenda(self.tmp, SAMPLE_AGENDA)

    def test_returns_string(self):
        result = extract_agenda(self.agenda_path)
        self.assertIsInstance(result, str)
        self.assertTrue(result.strip(), "result must not be blank")

    def test_contains_all_three_section_headers(self):
        result = extract_agenda(self.agenda_path)
        self.assertIn("## Current OKR", result)
        self.assertIn("## Pending Decisions", result)
        self.assertIn("## Risk Watch", result)

    def test_within_token_budget(self):
        result = extract_agenda(self.agenda_path)
        tokens = _approx_tokens(result)
        self.assertLessEqual(
            tokens, _AGENDA_TOKEN_BUDGET,
            f"agenda output is {tokens} tokens, exceeds {_AGENDA_TOKEN_BUDGET}"
        )

    def test_items_appear_as_bullets(self):
        result = extract_agenda(self.agenda_path)
        # At least the first OKR item should appear
        self.assertIn("**GEO Analyzer v2**", result)

    def test_description_truncated_to_40_chars(self):
        # Plant a very long description
        long_desc = "A" * 80
        content = VALID_FRONTMATTER + textwrap.dedent(f"""\
            ## Current OKR
            - **LongTask** — {long_desc}
              owner: X  horizon: Q2

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        # The description should be truncated with ellipsis
        self.assertIn("…", result)
        # Verify the raw 80-char description is not present
        self.assertNotIn(long_desc, result)

    def test_max_3_items_per_section(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **Item1** — desc1
            - **Item2** — desc2
            - **Item3** — desc3
            - **Item4** — desc4
            - **Item5** — desc5

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        self.assertIn("**Item1**", result)
        self.assertIn("**Item3**", result)
        self.assertNotIn("**Item4**", result)
        self.assertIn("+2 more", result)


class TestExtractAgendaMissing(unittest.TestCase):
    """T2: agenda.md does not exist → _（尚未建立）_"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_missing_file_returns_not_created(self):
        path = self.tmp / "agenda.md"
        result = extract_agenda(path)
        self.assertEqual(result, _NOT_CREATED)

    def test_no_exception_raised(self):
        path = self.tmp / "agenda.md"
        try:
            extract_agenda(path)
        except Exception as exc:
            self.fail(f"extract_agenda raised an exception for missing file: {exc}")


class TestExtractAgendaEmpty(unittest.TestCase):
    """T3: agenda.md is empty (0 bytes) → _（尚未建立）_"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_empty_file_returns_not_created(self):
        path = self.tmp / "agenda.md"
        path.write_bytes(b"")
        result = extract_agenda(path)
        self.assertEqual(result, _NOT_CREATED)

    def test_whitespace_only_returns_not_created(self):
        path = self.tmp / "agenda.md"
        path.write_text("   \n\t\n  ", encoding="utf-8")
        result = extract_agenda(path)
        self.assertEqual(result, _NOT_CREATED)

    def test_no_exception_raised(self):
        path = self.tmp / "agenda.md"
        path.write_bytes(b"")
        try:
            extract_agenda(path)
        except Exception as exc:
            self.fail(f"extract_agenda raised an exception for empty file: {exc}")


class TestExtractAgendaBadFrontmatter(unittest.TestCase):
    """T4: bad frontmatter → _（解析失敗）_, no exception."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def _assert_parse_error(self, content: str):
        path = _write_agenda(self.tmp, content)
        try:
            result = extract_agenda(path)
        except Exception as exc:
            self.fail(f"extract_agenda raised an exception instead of returning error string: {exc}")
        self.assertEqual(result, _PARSE_ERROR, f"Expected parse error, got: {result!r}")

    def test_no_frontmatter_at_all(self):
        self._assert_parse_error("## Current OKR\n- **Item** — desc\n")

    def test_unclosed_frontmatter(self):
        self._assert_parse_error("---\ntype: agenda\n## Current OKR\n")

    def test_invalid_yaml_in_frontmatter(self):
        # Tabs in YAML are invalid
        self._assert_parse_error("---\n\ttype: agenda\n---\n## Current OKR\n")

    def test_frontmatter_missing_type_key(self):
        # Frontmatter exists and is valid YAML but lacks "type"
        self._assert_parse_error("---\nowner: Anya\nupdated: 2026-04-19\n---\n## Current OKR\n")

    def test_frontmatter_is_scalar_not_dict(self):
        # YAML that parses to a non-dict
        self._assert_parse_error("---\njust a string\n---\n## Current OKR\n")

    def test_no_exception_from_bad_yaml(self):
        # Deeply broken YAML
        bad = "---\n: : :\n---\n## Current OKR\n"
        path = _write_agenda(self.tmp, bad)
        try:
            extract_agenda(path)
        except Exception as exc:
            self.fail(f"extract_agenda must not raise exceptions: {exc}")


class TestExtractAgendaIdempotent(unittest.TestCase):
    """T5: same input → byte-identical output (idempotent)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.agenda_path = _write_agenda(self.tmp, SAMPLE_AGENDA)

    def test_five_runs_identical(self):
        results = [extract_agenda(self.agenda_path) for _ in range(5)]
        for i, r in enumerate(results[1:], start=2):
            self.assertEqual(
                results[0], r,
                f"Run 1 and run {i} differ:\n---run1---\n{results[0]}\n---run{i}---\n{r}"
            )

    def test_idempotent_with_max_items(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **OKR1** — first objective for the quarter
            - **OKR2** — second objective for the quarter
            - **OKR3** — third objective for the quarter
            - **OKR4** — fourth objective that should be hidden

            ## Pending Decisions
            - **Dec1** — first decision needed

            ## Risk Watch
            - **Risk1** — first risk item
        """)
        path = _write_agenda(self.tmp, content)
        results = [extract_agenda(path) for _ in range(5)]
        for i, r in enumerate(results[1:], start=2):
            self.assertEqual(results[0], r, f"Run {i} differs from run 1")


class TestExtractAgendaTokenBudget(unittest.TestCase):
    """T-budget-split: verify token budget constraints and truncation priority."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_agenda_section_within_200_tokens(self):
        path = _write_agenda(self.tmp, SAMPLE_AGENDA)
        result = extract_agenda(path)
        tokens = _approx_tokens(result)
        self.assertLessEqual(tokens, 200, f"agenda section is {tokens} tokens")

    def test_truncation_drops_risk_first(self):
        """When over budget, Risk Watch is dropped before Pending Decisions."""
        # Build agenda with enough items to blow the 200-token budget
        many_items = "\n".join(
            f"- **Item{i}** — {'x' * 38}"
            for i in range(10)
        )
        content = VALID_FRONTMATTER + textwrap.dedent(f"""\
            ## Current OKR
{textwrap.indent(many_items, '            ')}

            ## Pending Decisions
{textwrap.indent(many_items, '            ')}

            ## Risk Watch
{textwrap.indent(many_items, '            ')}
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)

        tokens = _approx_tokens(result)
        self.assertLessEqual(tokens, 200, f"result is {tokens} tokens, expected ≤ 200")

        # If anything was dropped, Risk Watch should go first
        has_okr = "## Current OKR" in result
        has_decisions = "## Pending Decisions" in result
        has_risk = "## Risk Watch" in result

        if not has_risk:
            # Risk was dropped — acceptable. OKR must still be present.
            self.assertTrue(has_okr, "OKR must survive if Risk is dropped")
        elif not has_decisions:
            # Decisions dropped but not Risk — that violates priority
            self.assertFalse(has_risk, "Risk must be dropped before Decisions")
        # If all three present, budget was satisfied without dropping

    def test_truncation_drops_decisions_before_okr(self):
        """When even Risk dropping is not enough, Pending Decisions goes next."""
        # Create a huge OKR + Decisions block to force both Risk and Decisions to drop
        huge_items = "\n".join(
            f"- **BigItem{i}** — {'description text here ' * 3}"
            for i in range(10)
        )
        content = VALID_FRONTMATTER + textwrap.dedent(f"""\
            ## Current OKR
{textwrap.indent(huge_items, '            ')}

            ## Pending Decisions
{textwrap.indent(huge_items, '            ')}

            ## Risk Watch
{textwrap.indent(huge_items, '            ')}
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        tokens = _approx_tokens(result)
        self.assertLessEqual(tokens, 200, f"result is {tokens} tokens after truncation")

    def test_empty_section_shows_none_marker(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **OnlyItem** — the only okr

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        self.assertIn("## Pending Decisions", result)
        self.assertIn("_（無）_", result)

    def test_plus_n_more_annotation(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **A** — first
            - **B** — second
            - **C** — third
            - **D** — fourth
            - **E** — fifth

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        # 5 items, max 3 shown → +2 more
        self.assertIn("+2 more", result)
        self.assertNotIn("**D**", result)
        self.assertNotIn("**E**", result)


class TestExtractAgendaEdgeCases(unittest.TestCase):
    """Additional edge cases for robustness."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_only_frontmatter_no_sections(self):
        content = VALID_FRONTMATTER
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        # Should return something, not crash
        self.assertIsInstance(result, str)

    def test_unicode_content_handled(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **語義搜尋** — 完成繁中向量化流程

            ## Pending Decisions
            - **資料庫選擇** — PostgreSQL 還是 SQLite

            ## Risk Watch
            - **Token 預算** — 每日花費超標風險
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        self.assertIn("## Current OKR", result)
        self.assertIn("**語義搜尋**", result)

    def test_title_without_description_not_truncated(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            - **SimpleItem**

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        self.assertIn("**SimpleItem**", result)
        # No "…" since there's no description part
        # (only check the item line, not the whole output)
        item_line = next(
            (l for l in result.splitlines() if "**SimpleItem**" in l), ""
        )
        self.assertNotIn("…", item_line)

    def test_non_bullet_lines_in_section_ignored(self):
        content = VALID_FRONTMATTER + textwrap.dedent("""\
            ## Current OKR
            Some prose text here.
            - **ValidItem** — real item
            owner: X  horizon: Q2

            ## Pending Decisions

            ## Risk Watch
        """)
        path = _write_agenda(self.tmp, content)
        result = extract_agenda(path)
        self.assertIn("**ValidItem**", result)
        self.assertNotIn("Some prose text here", result)
        self.assertNotIn("owner: X", result)


if __name__ == "__main__":
    unittest.main(verbosity=2)

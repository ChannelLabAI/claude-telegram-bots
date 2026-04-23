"""Tests for pearl-lint.py dual-layer validation."""
import json
import subprocess
import sys
from pathlib import Path

LINT_SCRIPT = str(Path(__file__).parent.parent / "pearl-lint.py")
PEARL_BASE = str(Path.home() / "Documents/Obsidian Vault/Ocean/珍珠卡")


def run_lint(filepath: str, content: str, tool: str = "Write") -> tuple[int, str]:
    """Run pearl-lint.py with given input, return (exit_code, stderr)."""
    data = {
        "tool_name": tool,
        "tool_input": {"file_path": filepath, "content": content}
    }
    result = subprocess.run(
        [sys.executable, LINT_SCRIPT],
        input=json.dumps(data),
        capture_output=True,
        text=True
    )
    return result.returncode, result.stderr


VALID_CARD = f"""---
type: card
created: 2026-04-11
compiled_at: 2026-04-11
---

## Compiled Truth

這是一個測試卡片。[[Test]] [[Example]]

---

## Timeline

- 2026-04-11 初稿生成
"""

def test_valid_card_passes():
    fp = f"{PEARL_BASE}/test-valid.md"
    code, stderr = run_lint(fp, VALID_CARD)
    assert code == 0, f"Expected pass, got: {stderr}"

def test_missing_timeline_blocked():
    content = VALID_CARD.replace("## Timeline\n\n- 2026-04-11 初稿生成\n", "")
    fp = f"{PEARL_BASE}/test-no-timeline.md"
    code, stderr = run_lint(fp, content)
    assert code == 2, f"Expected block, got code={code}"
    assert "Timeline" in stderr

def test_missing_compiled_at_warns():
    content = VALID_CARD.replace("compiled_at: 2026-04-11\n", "")
    fp = f"{PEARL_BASE}/test-no-compiled-at.md"
    code, stderr = run_lint(fp, content)
    assert code == 0, f"Expected pass (warn only), got code={code}"
    assert "compiled_at" in stderr

def test_missing_frontmatter_blocked():
    content = "## Compiled Truth\n\nsome content\n\n## Timeline\n\n- date entry\n"
    fp = f"{PEARL_BASE}/test-no-fm.md"
    code, stderr = run_lint(fp, content)
    assert code == 2
    assert "frontmatter" in stderr.lower()

def test_non_pearl_path_allowed():
    fp = "/home/oldrabbit/other/file.md"
    code, stderr = run_lint(fp, "anything")
    assert code == 0

def test_underscore_prefix_allowed():
    fp = f"{PEARL_BASE}/_index.md"
    code, stderr = run_lint(fp, "no frontmatter needed")
    assert code == 0

def test_word_count_over_300_blocked():
    long_body = "word " * 310
    content = f"""---
type: card
created: 2026-04-11
compiled_at: 2026-04-11
---

## Compiled Truth

{long_body} [[A]] [[B]]

---

## Timeline

- 2026-04-11 entry
"""
    fp = f"{PEARL_BASE}/test-too-long.md"
    code, stderr = run_lint(fp, content)
    assert code == 2
    assert "300" in stderr

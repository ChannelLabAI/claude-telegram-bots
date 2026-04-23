#!/usr/bin/env python3
"""
memory_extractor.py — 4-type memory extractor (中文 + 英文).

Forked from /tmp/mempalace/mempalace/general_extractor.py with:
  - ❌ Dropped EMOTIONAL type entirely
  - ❌ Dropped _get_sentiment, NEGATIVE_WORDS, POSITIVE_WORDS
  - ✅ 4 types: DECISION / PREFERENCE / MILESTONE / PROBLEM
  - ✅ _disambiguate: PROBLEM + resolution marker → MILESTONE (keyword-only)
  - ✅ Markers loaded from markers.yml + world-seed.yml (entities downweighted)
  - ✅ Keeps _is_code_line + _extract_prose (strip code blocks before scoring)

Rule: 老兔 2026-04-08 拍板. 商業場景情緒是噪音不是訊號，越界存團隊情緒破壞信任。

Usage:
    from memory_extractor import extract_memories, classify_text

    memories = extract_memories(open("session.md").read())
    # [{"content": "...", "memory_type": "milestone", "chunk_index": 0}, ...]

    memory_type = classify_text("老兔拍板改用 Claude Opus 4.6")
    # "decision"

CLI:
    python3 memory_extractor.py <file>
    python3 memory_extractor.py --classify "some text"
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML required. pip install pyyaml", file=sys.stderr)
    sys.exit(1)


# ─── paths ────────────────────────────────────────────────────────────────────

SHARED_LIB = Path(__file__).resolve().parent
MARKERS_YML = SHARED_LIB / "markers.yml"
VAULT_SEED = Path.home() / "Documents" / "Obsidian Vault" / "Wiki" / "Concepts" / "world-seed.yml"
SHARED_SEED = SHARED_LIB / "world-seed.yml"


# ─── marker loading ───────────────────────────────────────────────────────────


def _load_markers() -> dict[str, list[str]]:
    if not MARKERS_YML.exists():
        raise FileNotFoundError(f"markers.yml not found: {MARKERS_YML}")
    data = yaml.safe_load(MARKERS_YML.read_text(encoding="utf-8")) or {}
    out = {
        "decision": list(data.get("decision") or []),
        "preference": list(data.get("preference") or []),
        "milestone": list(data.get("milestone") or []),
        "problem": list(data.get("problem") or []),
        "resolution": list(data.get("resolution") or []),
    }
    for key in out:
        out[key] = [str(m).strip() for m in out[key] if str(m).strip()]
    return out


def _load_entity_surfaces() -> set[str]:
    """
    Load entity surface forms from world-seed.yml. These are used only as a
    downweight set — if a matched marker equals an entity surface, it's ignored
    (prevents e.g. 'Ron' or 'Bonk' accidentally matching as markers). Usually
    none overlap, but the guard is cheap.
    """
    path = VAULT_SEED if VAULT_SEED.exists() else SHARED_SEED
    if not path.exists():
        return set()
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception:
        return set()
    surfaces: set[str] = set()
    for category in ("people", "projects", "brands"):
        for entry in data.get(category) or []:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            if name:
                surfaces.add(str(name).lower())
            for a in entry.get("aliases") or []:
                surfaces.add(str(a).lower())
    return surfaces


_MARKERS = _load_markers()
_ENTITY_SURFACES = _load_entity_surfaces()

# Precompile: each marker becomes (compiled regex, raw string).
# For CJK markers we match literally (no word boundaries, re.IGNORECASE).
# For ASCII markers we wrap with \b boundaries where the marker is alnum-only.
def _compile(markers: list[str]) -> list[tuple[re.Pattern[str], str]]:
    compiled: list[tuple[re.Pattern[str], str]] = []
    for m in markers:
        if not m:
            continue
        if m.lower() in _ENTITY_SURFACES:
            continue
        is_ascii = all(ord(c) < 128 for c in m)
        if is_ascii and re.fullmatch(r"[A-Za-z][A-Za-z0-9_ '-]*", m):
            pat = re.compile(rf"\b{re.escape(m)}\b", re.IGNORECASE)
        else:
            pat = re.compile(re.escape(m), re.IGNORECASE)
        compiled.append((pat, m))
    return compiled


ALL_MARKERS: dict[str, list[tuple[re.Pattern[str], str]]] = {
    "decision": _compile(_MARKERS["decision"]),
    "preference": _compile(_MARKERS["preference"]),
    "milestone": _compile(_MARKERS["milestone"]),
    "problem": _compile(_MARKERS["problem"]),
}
RESOLUTION_MARKERS: list[tuple[re.Pattern[str], str]] = _compile(_MARKERS["resolution"])


# ─── code-line filter (kept verbatim from upstream) ───────────────────────────

_CODE_LINE_PATTERNS = [
    re.compile(r"^\s*[\$#]\s"),
    re.compile(
        r"^\s*(cd|source|echo|export|pip|npm|git|python|bash|curl|wget|mkdir|rm|cp|mv|ls|cat|grep|find|chmod|sudo|brew|docker)\s"
    ),
    re.compile(r"^\s*```"),
    re.compile(r"^\s*(import|from|def|class|function|const|let|var|return)\s"),
    re.compile(r"^\s*[A-Z_]{2,}="),
    re.compile(r"^\s*\|"),
    re.compile(r"^\s*[-]{2,}"),
    re.compile(r"^\s*[{}\[\]]\s*$"),
    re.compile(r"^\s*(if|for|while|try|except|elif|else:)\b"),
    re.compile(r"^\s*\w+\.\w+\("),
    re.compile(r"^\s*\w+ = \w+\.\w+"),
]


def _is_code_line(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    for pattern in _CODE_LINE_PATTERNS:
        if pattern.match(stripped):
            return True
    # CJK text has low alpha-ratio; guard against stripping it
    has_cjk = any("\u4e00" <= c <= "\u9fff" for c in stripped)
    if has_cjk:
        return False
    alpha_ratio = sum(1 for c in stripped if c.isalpha()) / max(len(stripped), 1)
    if alpha_ratio < 0.4 and len(stripped) > 10:
        return True
    return False


def _extract_prose(text: str) -> str:
    lines = text.split("\n")
    prose: list[str] = []
    in_code = False
    for line in lines:
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if not _is_code_line(line):
            prose.append(line)
    result = "\n".join(prose).strip()
    return result if result else text


# ─── scoring ──────────────────────────────────────────────────────────────────


def _score_markers(text: str, markers: list[tuple[re.Pattern[str], str]]) -> tuple[float, list[str]]:
    score = 0.0
    hits: list[str] = []
    for pat, raw in markers:
        matches = pat.findall(text)
        if matches:
            score += len(matches)
            hits.append(raw)
    return score, hits


def _has_resolution(text: str) -> bool:
    for pat, _ in RESOLUTION_MARKERS:
        if pat.search(text):
            return True
    return False


def _disambiguate(memory_type: str, text: str, scores: dict[str, float]) -> str:
    """
    Keyword-only disambiguation (no sentiment analysis).

    Rule (老兔 2026-04-08):
      PROBLEM + resolution marker → upgrade to MILESTONE.
    """
    if memory_type == "problem" and _has_resolution(text):
        return "milestone"
    return memory_type


# ─── main extraction ──────────────────────────────────────────────────────────


def classify_text(text: str) -> str | None:
    """Classify a single snippet. Returns memory_type or None if no match."""
    prose = _extract_prose(text)
    scores: dict[str, float] = {}
    for mem_type, markers in ALL_MARKERS.items():
        score, _ = _score_markers(prose, markers)
        if score > 0:
            scores[mem_type] = score
    if not scores:
        return None
    max_type = max(scores, key=scores.get)
    return _disambiguate(max_type, prose, scores)


def extract_memories(text: str, min_confidence: float = 0.3) -> list[dict[str, Any]]:
    paragraphs = _split_into_segments(text)
    memories: list[dict[str, Any]] = []

    for para in paragraphs:
        if len(para.strip()) < 20:
            continue

        prose = _extract_prose(para)

        scores: dict[str, float] = {}
        for mem_type, markers in ALL_MARKERS.items():
            score, _ = _score_markers(prose, markers)
            if score > 0:
                scores[mem_type] = score
        if not scores:
            continue

        if len(para) > 500:
            length_bonus = 2
        elif len(para) > 200:
            length_bonus = 1
        else:
            length_bonus = 0

        max_type = max(scores, key=scores.get)
        max_score = scores[max_type] + length_bonus
        max_type = _disambiguate(max_type, prose, scores)

        confidence = min(1.0, max_score / 5.0)
        if confidence < min_confidence:
            continue

        memories.append(
            {
                "content": para.strip(),
                "memory_type": max_type,
                "chunk_index": len(memories),
                "confidence": round(confidence, 3),
            }
        )

    return memories


def _split_into_segments(text: str) -> list[str]:
    lines = text.split("\n")
    turn_patterns = [
        re.compile(r"^>\s"),
        re.compile(r"^(Human|User|Q)\s*:", re.I),
        re.compile(r"^(Assistant|AI|A|Claude|ChatGPT)\s*:", re.I),
    ]
    turn_count = 0
    for line in lines:
        stripped = line.strip()
        for pat in turn_patterns:
            if pat.match(stripped):
                turn_count += 1
                break

    if turn_count >= 3:
        return _split_by_turns(lines, turn_patterns)

    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    if len(paragraphs) <= 1 and len(lines) > 20:
        segments: list[str] = []
        for i in range(0, len(lines), 25):
            group = "\n".join(lines[i : i + 25]).strip()
            if group:
                segments.append(group)
        return segments
    return paragraphs


def _split_by_turns(lines: list[str], turn_patterns: list[re.Pattern[str]]) -> list[str]:
    segments: list[str] = []
    current: list[str] = []
    for line in lines:
        stripped = line.strip()
        is_turn = any(pat.match(stripped) for pat in turn_patterns)
        if is_turn and current:
            segments.append("\n".join(current))
            current = [line]
        else:
            current.append(line)
    if current:
        segments.append("\n".join(current))
    return segments


# ─── task-done hook helper ────────────────────────────────────────────────────


def tag_file_frontmatter(path: Path, memory_type: str) -> bool:
    """
    Add or update `memory_type:` in YAML frontmatter of a markdown file.
    Returns True if file was modified, False otherwise.
    """
    path = Path(path)
    text = path.read_text(encoding="utf-8")

    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end == -1:
            return False
        fm = text[4:end]
        body = text[end + 4 :]
        if re.search(r"^memory_type:\s*.*$", fm, re.MULTILINE):
            new_fm = re.sub(
                r"^memory_type:\s*.*$", f"memory_type: {memory_type}", fm, flags=re.MULTILINE
            )
            if new_fm == fm:
                return False
        else:
            new_fm = fm.rstrip() + f"\nmemory_type: {memory_type}\n"
        new_text = f"---\n{new_fm}\n---{body}"
    else:
        new_text = f"---\nmemory_type: {memory_type}\n---\n{text}"

    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        return True
    return False


# ─── CLI ──────────────────────────────────────────────────────────────────────


def _main(argv: list[str]) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="4-type memory extractor")
    ap.add_argument("target", nargs="?", help="file to extract from")
    ap.add_argument("--classify", help="classify a single text snippet")
    ap.add_argument("--tag", metavar="FILE", help="classify FILE and add memory_type frontmatter")
    args = ap.parse_args(argv)

    if args.classify:
        t = classify_text(args.classify)
        print(t or "none")
        return 0

    if args.tag:
        p = Path(args.tag)
        if not p.exists():
            print(f"not found: {p}", file=sys.stderr)
            return 1
        text = p.read_text(encoding="utf-8", errors="replace")
        mtype = classify_text(text)
        if not mtype:
            print(f"no memory markers matched: {p}")
            return 0
        changed = tag_file_frontmatter(p, mtype)
        print(f"{'TAGGED' if changed else 'UNCHANGED'} {mtype} {p}")
        return 0

    if not args.target:
        ap.print_help()
        return 1

    text = Path(args.target).read_text(encoding="utf-8", errors="replace")
    memories = extract_memories(text)
    counts = Counter(m["memory_type"] for m in memories)
    print(f"Extracted {len(memories)} memories:")
    for mtype in ("decision", "preference", "milestone", "problem"):
        c = counts.get(mtype, 0)
        if c:
            print(f"  {mtype:10} {c}")
    print()
    for m in memories[:10]:
        preview = m["content"][:80].replace("\n", " ")
        print(f"  [{m['memory_type']:10}] {preview}...")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

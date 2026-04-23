"""Skill loop runtime v0.2.

Runtime layer over 三菜's learned-skills schema. Ports Anna's PoC and
closes Bella's 6 security concerns (CR-20260408). Schema source of truth:
~/.claude-bots/shared/learned-skills/README.md.

Writes ONLY to _drafts/. Promotion to approved/ is human-only.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

MODEL = "claude-sonnet-4-5"

# ---------------------------------------------------------------------------
# Sanitation
# ---------------------------------------------------------------------------

_MAX_BYTES = 8192

# Prompt-injection markers (case-insensitive).
_INJECTION_MARKERS = [
    r"<system>", r"</system>",
    r"<user>", r"</user>",
    r"<assistant>", r"</assistant>",
    r"<instructions>", r"</instructions>",
    r"<\|im_start\|", r"<\|im_end\|",
    r"<\|system\|", r"<\|user\|", r"<\|assistant\|",
]
_INJECTION_RE = re.compile("|".join(_INJECTION_MARKERS), re.IGNORECASE)

# C0 control chars except \n \r \t
_C0_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")

_FENCE_RE = re.compile(r"^(```|~~~).*$", re.MULTILINE)


def _sanitize_text(s: str, max_bytes: int = _MAX_BYTES) -> str:
    """Strip code fences, enforce size cap, reject injection markers.

    Raises ValueError on: oversize, injection marker present, C0 control char.
    """
    if s is None:
        return ""
    if not isinstance(s, str):
        raise ValueError(f"expected str, got {type(s).__name__}")

    # Strip code fence lines (entire line removed).
    cleaned = _FENCE_RE.sub("", s)

    # Size cap (on cleaned text, UTF-8 bytes).
    if len(cleaned.encode("utf-8")) > max_bytes:
        raise ValueError("content exceeds 8KB sanitation cap")

    # Reject prompt-injection markers.
    if _INJECTION_RE.search(cleaned):
        raise ValueError("content contains prompt-injection marker")

    # Reject C0 controls (except \n \r \t).
    if _C0_RE.search(cleaned):
        raise ValueError("content contains disallowed control characters")

    return cleaned


# ---------------------------------------------------------------------------
# Slug validation
# ---------------------------------------------------------------------------

_SLUG_RE = re.compile(r"^[a-z][a-z0-9-]{1,62}$")


def _validate_slug(slug: str) -> str:
    """Kebab-case, 2–63 chars, starts with lowercase letter. No traversal."""
    if not isinstance(slug, str) or not _SLUG_RE.match(slug):
        raise ValueError(f"invalid slug: {slug!r}")
    return slug


# ---------------------------------------------------------------------------
# LLM wrapper
# ---------------------------------------------------------------------------

def _llm(prompt: str, timeout: int = 60) -> Optional[str]:
    """Call the claude CLI. Return stdout on success, None on any failure."""
    if shutil.which("claude") is None:
        logger.warning("claude CLI not on PATH; _llm returning None")
        return None
    try:
        result = subprocess.run(
            ["claude", "--model", MODEL, "-p", prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        logger.warning("claude CLI failed: %s", e)
        return None
    if result.returncode != 0:
        logger.warning("claude CLI exit %d: %s", result.returncode, (result.stderr or "")[:200])
        return None
    return (result.stdout or "").strip()


# ---------------------------------------------------------------------------
# SKILL.md render / parse
# ---------------------------------------------------------------------------

_H1_RE = re.compile(r"^#\s*Skill:\s*(.+?)\s*$", re.MULTILINE)
_SECTION_RE = re.compile(
    r"##\s*(是什麼|什麼時候用這個 skill|為什麼存在|邊界)\s*\n(.*?)(?=\n##\s|\Z)",
    re.DOTALL,
)


def _render_skill_md(title: str, what: str, when: str, why: str, boundary: str) -> str:
    return (
        f"# Skill: {title.strip()}\n\n"
        f"## 是什麼\n{what.strip()}\n\n"
        f"## 什麼時候用這個 skill\n{when.strip()}\n\n"
        f"## 為什麼存在\n{why.strip()}\n\n"
        f"## 邊界\n{boundary.strip()}\n"
    )


def _parse_skill_md(text: str) -> dict:
    """Extract H1 title and the four H2 sections. Raises ValueError if incomplete."""
    m = _H1_RE.search(text)
    if not m:
        raise ValueError("SKILL.md missing H1 '# Skill: ...'")
    title = m.group(1).strip()

    sections: dict[str, str] = {}
    for sm in _SECTION_RE.finditer(text):
        sections[sm.group(1)] = sm.group(2).strip()

    required = {
        "what": "是什麼",
        "when": "什麼時候用這個 skill",
        "why": "為什麼存在",
        "boundary": "邊界",
    }
    out = {"title": title}
    for key, heading in required.items():
        if heading not in sections:
            raise ValueError(f"SKILL.md missing section: {heading}")
        out[key] = sections[heading]
    return out


# ---------------------------------------------------------------------------
# Draft writing (atomic)
# ---------------------------------------------------------------------------

def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class TaskTrace:
    task: str
    steps: list[str]
    outcome: str  # "success" | "failure"
    tool_count: int
    duration_s: float
    bot: str
    timestamp: str = ""
    errors: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.timestamp:
            self.timestamp = datetime.now(timezone.utc).isoformat()


@dataclass
class Skill:
    slug: str
    title: str
    what: str
    when: str
    why: str
    boundary: str
    usage_md: str
    example_md: str
    state: str  # "draft" | "approved"
    path: Path
    usage_count: int = 0
    version: int = 1


# ---------------------------------------------------------------------------
# SkillManager
# ---------------------------------------------------------------------------

class SkillManager:
    def __init__(
        self,
        bot: str = "anna",
        learned_skills_dir: Path = Path("~/.claude-bots/shared/learned-skills").expanduser(),
        runtime_dir: Path = Path("~/.claude-bots/shared/skill-loop-runtime").expanduser(),
    ) -> None:
        self.bot = bot
        self.learned_skills_dir = Path(learned_skills_dir)
        self.runtime_dir = Path(runtime_dir)

        self.drafts_dir = self.learned_skills_dir / "_drafts"
        self.approved_dir = self.learned_skills_dir / "approved"

        # Self-check: refuse to start if schema dirs missing.
        if not self.drafts_dir.is_dir():
            raise RuntimeError(f"missing required dir: {self.drafts_dir}")
        if not self.approved_dir.is_dir():
            raise RuntimeError(f"missing required dir: {self.approved_dir}")

        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.usage_sidecar_path = self.runtime_dir / "usage.json"
        if not self.usage_sidecar_path.exists():
            _atomic_write(self.usage_sidecar_path, "{}")

    # ---- sidecar --------------------------------------------------------

    def _load_usage_sidecar(self) -> dict:
        try:
            return json.loads(self.usage_sidecar_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def _save_usage_sidecar(self, data: dict) -> None:
        _atomic_write(
            self.usage_sidecar_path,
            json.dumps(data, indent=2, ensure_ascii=False),
        )

    # ---- loading --------------------------------------------------------

    def _load_skill_dir(self, path: Path, state: str, usage_data: dict) -> Optional[Skill]:
        try:
            skill_md = (path / "SKILL.md").read_text(encoding="utf-8")
            usage_md = (path / "USAGE.md").read_text(encoding="utf-8")
            example_md = (path / "EXAMPLE.md").read_text(encoding="utf-8")
        except OSError as e:
            logger.warning("failed to read skill dir %s: %s", path, e)
            return None
        try:
            parsed = _parse_skill_md(skill_md)
        except ValueError as e:
            logger.warning("skill %s malformed: %s", path, e)
            return None

        slug = path.name
        entry = usage_data.get(slug, {})
        return Skill(
            slug=slug,
            title=parsed["title"],
            what=parsed["what"],
            when=parsed["when"],
            why=parsed["why"],
            boundary=parsed["boundary"],
            usage_md=usage_md,
            example_md=example_md,
            state=state,
            path=path,
            usage_count=int(entry.get("usage_count", 0)),
            version=int(entry.get("version", 1)),
        )

    def load_all_skills(self) -> list[Skill]:
        """Return only approved skills."""
        usage_data = self._load_usage_sidecar()
        out: list[Skill] = []
        if not self.approved_dir.is_dir():
            return out
        for child in sorted(self.approved_dir.iterdir()):
            if not child.is_dir():
                continue
            skill = self._load_skill_dir(child, "approved", usage_data)
            if skill is not None:
                out.append(skill)
        return out

    def list_skills(self) -> list[str]:
        return [s.slug for s in self.load_all_skills()]

    # ---- search ---------------------------------------------------------

    @staticmethod
    def _tokenize(text: str) -> set[str]:
        return {t for t in re.findall(r"[a-z0-9\u4e00-\u9fff]+", text.lower()) if len(t) >= 2}

    def search_skills(self, query: str, top_k: int = 3) -> list[Skill]:
        q_tokens = self._tokenize(query)
        if not q_tokens:
            return []
        scored: list[tuple[int, Skill]] = []
        for skill in self.load_all_skills():
            haystack = f"{skill.title}\n{skill.when}\n{skill.what}"
            s_tokens = self._tokenize(haystack)
            score = len(q_tokens & s_tokens)
            if score > 0:
                scored.append((score, skill))
        scored.sort(key=lambda x: (-x[0], x[1].slug))
        return [s for _, s in scored[:top_k]]

    # ---- context injection ---------------------------------------------

    def inject_context(self, task: str) -> str:
        """Return markdown with top matching skills, bumping usage_count."""
        matches = self.search_skills(task, top_k=3)
        if not matches:
            return ""

        usage_data = self._load_usage_sidecar()
        now = datetime.now(timezone.utc).isoformat()
        blocks: list[str] = ["# Relevant learned skills\n"]

        for skill in matches:
            try:
                title = _sanitize_text(skill.title)
                what = _sanitize_text(skill.what)
                when = _sanitize_text(skill.when)
                boundary = _sanitize_text(skill.boundary)
                usage_body = _sanitize_text(skill.usage_md)
            except ValueError as e:
                logger.warning("skipping skill %s in injection: %s", skill.slug, e)
                continue

            blocks.append(
                f"## {title}\n\n"
                f"**是什麼**: {what}\n\n"
                f"**什麼時候用**: {when}\n\n"
                f"**邊界**: {boundary}\n\n"
                f"### 使用方式\n{usage_body}\n"
            )

            entry = usage_data.get(skill.slug, {"usage_count": 0, "version": 1})
            entry["usage_count"] = int(entry.get("usage_count", 0)) + 1
            entry["version"] = int(entry.get("version", 1))
            entry["last_used"] = now
            usage_data[skill.slug] = entry

        if len(blocks) == 1:
            return ""

        self._save_usage_sidecar(usage_data)
        return "\n".join(blocks)

    # ---- creation -------------------------------------------------------

    def _should_create_skill(self, trace: TaskTrace, existing: list[Skill]) -> bool:
        existing_titles = "\n".join(f"- {s.title}" for s in existing) or "(none)"
        prompt = (
            "You are deciding whether a task trace should become a reusable skill.\n"
            f"Outcome: {trace.outcome}\n"
            f"Task: {trace.task}\n"
            f"Steps: {trace.steps}\n"
            f"Existing skills:\n{existing_titles}\n\n"
            "Answer exactly YES or NO."
        )
        resp = _llm(prompt)
        if resp is None:
            return False
        return resp.strip().upper().startswith("YES")

    def _generate_skill(self, trace: TaskTrace) -> Optional[dict]:
        prompt = (
            "Given this task trace, produce a reusable skill as a single JSON object "
            "with keys: slug, title, what, when, why, boundary, usage_md, example_md. "
            "slug must be kebab-case (lowercase letters, digits, hyphens, 2-63 chars, "
            "start with a letter). Return ONLY the JSON, no prose.\n\n"
            f"Task: {trace.task}\n"
            f"Steps: {trace.steps}\n"
            f"Outcome: {trace.outcome}\n"
            f"Errors: {trace.errors}\n"
        )
        resp = _llm(prompt)
        if resp is None:
            return None
        # Try to pull JSON out.
        try:
            m = re.search(r"\{.*\}", resp, re.DOTALL)
            if not m:
                return None
            data = json.loads(m.group(0))
        except (json.JSONDecodeError, ValueError):
            return None

        required = ["slug", "title", "what", "when", "why", "boundary", "usage_md", "example_md"]
        if not all(k in data and isinstance(data[k], str) for k in required):
            return None
        return data

    def maybe_create_skill(self, trace: TaskTrace) -> Optional[Skill]:
        # (a) sanitize input first — blocks prompt-injection attack vector.
        try:
            _sanitize_text(trace.task)
            for step in trace.steps:
                _sanitize_text(step)
            for err in trace.errors:
                _sanitize_text(err)
            _sanitize_text(trace.outcome)
            _sanitize_text(trace.bot)
        except ValueError as e:
            logger.warning("trace rejected by sanitizer: %s", e)
            return None

        existing = self.load_all_skills()
        if not self._should_create_skill(trace, existing):
            return None

        data = self._generate_skill(trace)
        if data is None:
            return None

        # (b) sanitize LLM output.
        try:
            slug = _validate_slug(data["slug"])
            title = _sanitize_text(data["title"])
            what = _sanitize_text(data["what"])
            when = _sanitize_text(data["when"])
            why = _sanitize_text(data["why"])
            boundary = _sanitize_text(data["boundary"])
            usage_md = _sanitize_text(data["usage_md"])
            example_md = _sanitize_text(data["example_md"])
        except ValueError as e:
            logger.warning("LLM output rejected by sanitizer: %s", e)
            return None

        skill_md = _render_skill_md(title, what, when, why, boundary)
        draft_path = self._write_draft(slug, skill_md, usage_md, example_md)

        usage_data = self._load_usage_sidecar()
        usage_data.setdefault(slug, {"usage_count": 0, "version": 1})
        self._save_usage_sidecar(usage_data)

        return self._load_skill_dir(draft_path, "draft", usage_data)

    def _write_draft(
        self, slug: str, skill_md: str, usage_md: str, example_md: str
    ) -> Path:
        slug = _validate_slug(slug)
        target = self.drafts_dir / slug
        target.mkdir(parents=True, exist_ok=True)
        _atomic_write(target / "SKILL.md", skill_md)
        _atomic_write(target / "USAGE.md", usage_md)
        _atomic_write(target / "EXAMPLE.md", example_md)
        return target

    # ---- improvement ----------------------------------------------------

    def _improve_skill(self, slug: str) -> Optional[Skill]:
        slug = _validate_slug(slug)
        # For v0.2 we only support improving drafts.
        draft_path = self.drafts_dir / slug
        approved_path = self.approved_dir / slug
        if approved_path.exists():
            # TODO(v0.3): human review pipeline for improvement of approved skills.
            raise NotImplementedError(
                "improving approved skills is not supported in v0.2"
            )
        if not draft_path.is_dir():
            return None

        usage_data = self._load_usage_sidecar()
        current = self._load_skill_dir(draft_path, "draft", usage_data)
        if current is None:
            return None

        prompt = (
            "You are improving a learned skill. Return either the literal token "
            "NO_CHANGE or a full new SKILL.md body with the H1 '# Skill: <title>' "
            "and the four H2 sections (是什麼, 什麼時候用這個 skill, 為什麼存在, 邊界).\n\n"
            f"Current SKILL.md:\n{(draft_path / 'SKILL.md').read_text(encoding='utf-8')}\n"
        )
        resp = _llm(prompt)
        if resp is None:
            return None

        if resp.strip() == "NO_CHANGE":
            entry = usage_data.get(slug, {"usage_count": 0, "version": 1})
            entry["version"] = int(entry.get("version", 1)) + 1
            usage_data[slug] = entry
            self._save_usage_sidecar(usage_data)
            return current

        try:
            cleaned = _sanitize_text(resp)
            parsed = _parse_skill_md(cleaned)
        except ValueError as e:
            logger.warning("improvement output rejected: %s", e)
            return None

        new_skill_md = _render_skill_md(
            parsed["title"], parsed["what"], parsed["when"], parsed["why"], parsed["boundary"]
        )
        self._write_draft(slug, new_skill_md, current.usage_md, current.example_md)

        entry = usage_data.get(slug, {"usage_count": 0, "version": 1})
        entry["version"] = int(entry.get("version", 1)) + 1
        usage_data[slug] = entry
        self._save_usage_sidecar(usage_data)

        return self._load_skill_dir(draft_path, "draft", usage_data)

    # ---- promotion guard -----------------------------------------------

    def promote_to_approved(self, slug: str) -> None:
        raise PermissionError(
            f"promotion is human-only; mv _drafts/{slug} approved/{slug} manually after review"
        )

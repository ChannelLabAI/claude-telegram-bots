#!/usr/bin/env python3
"""
ChannelLab Skill Loop — Minimal self-improving skill manager
Inspired by NousResearch/hermes-agent's skill system.

Flow:
  1. Bot completes a task and records a TaskTrace (steps, tools used, outcome)
  2. SkillManager evaluates: should this become a reusable skill?
     - Heuristic: ≥5 steps AND success AND no existing similar skill
     - LLM confirms: "Is this pattern worth saving?"
  3. If yes: LLM generates SKILL.md (YAML frontmatter + markdown body)
  4. Skill stored in ~/.claude-bots/shared/skills-loop/skills/{category}/{slug}/SKILL.md
  5. On next invocation: SkillManager searches skills, injects matches into context

Usage:
  from skill_manager import SkillManager, TaskTrace
  sm = SkillManager()

  # After completing a task:
  trace = TaskTrace(task="compress CLSC text", steps=[...], outcome="success", tool_count=6)
  sm.maybe_create_skill(trace)

  # Before starting a task:
  relevant = sm.search_skills("compress Chinese text")
  if relevant:
      print(f"Applying known skill: {relevant[0].name}")
"""

import os, re, json, subprocess, datetime
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

SKILLS_DIR = Path("~/.claude-bots/shared/skills-loop/skills").expanduser()
SKILLS_DIR.mkdir(parents=True, exist_ok=True)

SKILL_CREATION_THRESHOLD = 5   # min steps to consider creating a skill
MODEL = "claude-haiku-4-5-20251001"  # use haiku for skill management (cost-efficient)


# ─── Data structures ───────────────────────────────────────────────────────────

@dataclass
class TaskTrace:
    """Record of a completed task."""
    task:        str                  # natural language description
    steps:       list[str]            # what was done (tool calls / actions)
    outcome:     str                  # "success" | "partial" | "fail"
    tool_count:  int = 0              # number of tool calls
    duration_s:  float = 0.0
    bot:         str = "anna"
    timestamp:   str = field(default_factory=lambda: datetime.datetime.utcnow().isoformat())
    errors:      list[str] = field(default_factory=list)


@dataclass
class Skill:
    """A loaded skill."""
    name:        str
    description: str
    category:    str
    trigger:     str      # natural language pattern that activates this skill
    steps:       str      # markdown body (the actual skill procedure)
    path:        Path
    usage_count: int = 0
    version:     int = 1


# ─── Skill file I/O ────────────────────────────────────────────────────────────

def _write_skill(skill_dict: dict, category: str, slug: str) -> Path:
    """Write a skill to SKILL.md format (YAML frontmatter + markdown body)."""
    skill_dir = SKILLS_DIR / category / slug
    skill_dir.mkdir(parents=True, exist_ok=True)
    path = skill_dir / "SKILL.md"

    frontmatter = (
        f"---\n"
        f"name: {skill_dict['name']}\n"
        f"description: {skill_dict['description']}\n"
        f"category: {category}\n"
        f"trigger: \"{skill_dict['trigger']}\"\n"
        f"version: {skill_dict.get('version', 1)}\n"
        f"usage_count: 0\n"
        f"created_at: {datetime.datetime.utcnow().isoformat()}\n"
        f"bot: {skill_dict.get('bot', 'anna')}\n"
        f"---\n\n"
    )
    path.write_text(frontmatter + skill_dict["steps"], encoding="utf-8")
    return path


def _parse_skill(path: Path) -> Optional[Skill]:
    """Parse a SKILL.md file."""
    try:
        text = path.read_text(encoding="utf-8")
        # Extract YAML frontmatter
        fm_match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
        if not fm_match:
            return None
        fm_text = fm_match.group(1)
        body = text[fm_match.end():].strip()

        def fm_get(key, default=""):
            m = re.search(rf"^{key}:\s*(.+)$", fm_text, re.MULTILINE)
            return m.group(1).strip().strip('"') if m else default

        return Skill(
            name=fm_get("name"),
            description=fm_get("description"),
            category=fm_get("category"),
            trigger=fm_get("trigger"),
            steps=body,
            path=path,
            usage_count=int(fm_get("usage_count", "0")),
            version=int(fm_get("version", "1")),
        )
    except Exception:
        return None


def load_all_skills() -> list[Skill]:
    """Scan SKILLS_DIR and load all SKILL.md files."""
    skills = []
    for p in SKILLS_DIR.rglob("SKILL.md"):
        if ".git" in str(p):
            continue
        s = _parse_skill(p)
        if s:
            skills.append(s)
    return skills


# ─── LLM helpers (via claude CLI) ──────────────────────────────────────────────

def _llm(prompt: str, timeout: int = 60) -> str:
    """Call Claude CLI. Returns response text."""
    result = subprocess.run(
        ["claude", "--model", MODEL, "-p", prompt],
        capture_output=True, text=True, timeout=timeout
    )
    return result.stdout.strip()


def _should_create_skill(trace: TaskTrace, existing_skills: list[Skill]) -> bool:
    """Ask LLM if this task trace is worth creating a skill for."""
    existing_names = [s.name for s in existing_skills]
    existing_str = "\n".join(f"- {n}" for n in existing_names) if existing_names else "(none yet)"

    prompt = f"""You are evaluating whether a completed task should become a reusable skill.

Completed task: {trace.task}
Steps taken ({trace.tool_count} total):
{chr(10).join(f'  {i+1}. {s}' for i, s in enumerate(trace.steps))}
Outcome: {trace.outcome}
Errors: {trace.errors or 'none'}

Existing skills:
{existing_str}

Should this become a new reusable skill? Answer YES or NO.
YES if: task has ≥5 steps, succeeded, involves a repeatable pattern not covered by existing skills.
NO if: too simple, one-off, or already covered.

Reply with exactly: YES or NO"""

    response = _llm(prompt)
    return response.strip().upper().startswith("YES")


def _generate_skill(trace: TaskTrace) -> Optional[dict]:
    """Ask LLM to generate a SKILL.md from a task trace."""
    steps_str = "\n".join(f"{i+1}. {s}" for i, s in enumerate(trace.steps))

    prompt = f"""Create a reusable skill definition from this completed task.

Task: {trace.task}
Steps taken:
{steps_str}
Outcome: {trace.outcome}

Generate a skill definition with these fields:
- name: short snake_case identifier (e.g. compress-clsc-text)
- category: one of [data, communication, workflow, research, devops]
- description: one sentence what this skill does
- trigger: natural language pattern that should activate this skill (e.g. "when asked to compress Chinese text")
- steps: step-by-step procedure in markdown, generalized for reuse

Output ONLY valid JSON:
{{
  "name": "...",
  "category": "...",
  "description": "...",
  "trigger": "...",
  "steps": "## Steps\\n\\n1. ...\\n2. ..."
}}"""

    response = _llm(prompt, timeout=90)
    # Extract JSON
    json_match = re.search(r'\{[\s\S]*\}', response)
    if not json_match:
        return None
    try:
        return json.loads(json_match.group())
    except json.JSONDecodeError:
        return None


def _improve_skill(skill: Skill, trace: TaskTrace) -> Optional[str]:
    """Ask LLM to improve an existing skill based on new execution."""
    prompt = f"""Improve an existing skill based on a new successful execution.

Existing skill "{skill.name}":
{skill.steps}

New execution:
Task: {trace.task}
Steps: {chr(10).join(f'{i+1}. {s}' for i, s in enumerate(trace.steps))}
Outcome: {trace.outcome}

If the new execution reveals improvements (better approach, missing edge case, clearer steps), output the improved markdown body.
If no improvement needed, output: NO_CHANGE

Output only the improved steps markdown or NO_CHANGE:"""

    response = _llm(prompt, timeout=60)
    if response.strip() == "NO_CHANGE":
        return None
    return response.strip()


# ─── Main SkillManager ─────────────────────────────────────────────────────────

class SkillManager:
    def __init__(self, bot: str = "anna"):
        self.bot = bot
        self._skills_cache: Optional[list[Skill]] = None

    @property
    def skills(self) -> list[Skill]:
        if self._skills_cache is None:
            self._skills_cache = load_all_skills()
        return self._skills_cache

    def _invalidate_cache(self):
        self._skills_cache = None

    def search_skills(self, query: str, top_k: int = 3) -> list[Skill]:
        """Simple keyword-based skill search (no embeddings needed for PoC)."""
        query_lower = query.lower()
        query_words = set(re.findall(r'\w+', query_lower))
        scored = []
        for skill in self.skills:
            # Score = overlap between query words and skill text
            skill_text = (skill.name + " " + skill.description + " " + skill.trigger).lower()
            skill_words = set(re.findall(r'\w+', skill_text))
            overlap = len(query_words & skill_words)
            if overlap > 0:
                scored.append((overlap, skill))
        scored.sort(reverse=True, key=lambda x: x[0])
        return [s for _, s in scored[:top_k]]

    def maybe_create_skill(self, trace: TaskTrace) -> Optional[Path]:
        """
        After a task completes: evaluate if it should become a skill.
        Returns path to new/updated skill, or None.
        """
        if trace.outcome != "success":
            return None
        if trace.tool_count < SKILL_CREATION_THRESHOLD:
            return None

        # Check if a similar skill already exists
        similar = self.search_skills(trace.task, top_k=1)
        if similar:
            # Try to improve existing skill
            skill = similar[0]
            improved = _improve_skill(skill, trace)
            if improved:
                # Patch the existing skill
                new_version = skill.version + 1
                skill.path.write_text(
                    skill.path.read_text().replace(
                        f"version: {skill.version}", f"version: {new_version}"
                    ).replace(
                        skill.steps, improved
                    ),
                    encoding="utf-8"
                )
                self._invalidate_cache()
                print(f"[skill-loop] Updated skill '{skill.name}' to v{new_version}")
                return skill.path

        # Decide whether to create a new skill
        if not _should_create_skill(trace, self.skills):
            return None

        # Generate new skill
        skill_dict = _generate_skill(trace)
        if not skill_dict:
            return None

        skill_dict["bot"] = self.bot
        slug = re.sub(r'[^a-z0-9-]', '-', skill_dict.get("name", "unnamed").lower())
        category = skill_dict.get("category", "workflow")
        path = _write_skill(skill_dict, category, slug)
        self._invalidate_cache()
        print(f"[skill-loop] Created new skill '{skill_dict['name']}' at {path}")
        return path

    def inject_context(self, task: str) -> str:
        """
        Returns a context string to prepend to LLM prompt.
        Format: "Relevant skills:\n- name: description\n  trigger: ..."
        """
        relevant = self.search_skills(task)
        if not relevant:
            return ""
        lines = ["Relevant skills from memory:"]
        for s in relevant:
            lines.append(f"\n## {s.name}\nTrigger: {s.trigger}\n{s.steps}")
        return "\n".join(lines)

    def list_skills(self) -> list[dict]:
        return [
            {"name": s.name, "category": s.category,
             "description": s.description, "version": s.version}
            for s in self.skills
        ]

#!/usr/bin/env bash
# fatq-skill-extract.sh — Skillify flywheel: Bella PASS + novel_pattern → skill draft
#
# Usage (called by Bella CLAUDE.md APPROVE step):
#   fatq-skill-extract.sh <task_json_path>
#
# Triggers when:
#   - Last history entry has Bella PASS verdict AND
#   - task JSON has novel_pattern=yes OR novel_pattern absent/unclear (default trigger)
#
# Output: ~/.claude-bots/state/anya/inbox/skill-drafts/{task_id}-skill-draft.md

set -euo pipefail

SKILL_DRAFTS_DIR="$HOME/.claude-bots/state/anya/inbox/skill-drafts"
LOG="$HOME/.claude-bots/logs/skillify.log"
SECRETS="$HOME/.claude-bots/shared/secrets/llm-keys.env"

mkdir -p "$SKILL_DRAFTS_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S+08:00')] $*" >> "$LOG"; }

if [[ $# -lt 1 ]]; then
    log "ERROR: missing task_json_path argument"
    exit 2
fi

TASK_FILE="$1"
if [[ ! -f "$TASK_FILE" ]]; then
    log "ERROR: not found: $TASK_FILE"
    exit 1
fi

# Source API key — set -a exports all variables from the file to child processes
if [[ -f "$SECRETS" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$SECRETS"
    set +a
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    log "ERROR: ANTHROPIC_API_KEY not set"
    exit 1
fi

python3 - "$TASK_FILE" "$SKILL_DRAFTS_DIR" "$LOG" <<'PY'
import json
import os
import sys
from datetime import datetime
from pathlib import Path
import re

import anthropic

task_path = Path(sys.argv[1])
drafts_dir = Path(sys.argv[2])
log_path = Path(sys.argv[3])

def log(msg):
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"[{datetime.now().strftime('%Y-%m-%dT%H:%M:%S+08:00')}] {msg}\n")

try:
    task = json.loads(task_path.read_text(encoding="utf-8"))
except Exception as e:
    log(f"PARSE_ERROR {task_path}: {e}")
    sys.exit(1)

task_id = task.get("task_id", task_path.stem)
novel_pattern = task.get("novel_pattern", "").lower().strip()
draft_out = drafts_dir / f"{task_id}-skill-draft.md"

# Check: already drafted?
if draft_out.exists():
    log(f"SKIP already drafted: {task_id}")
    sys.exit(0)

# Check novel_pattern — drop only if explicitly "no"
if novel_pattern == "no":
    log(f"SKIP novel_pattern=no: {task_id}")
    sys.exit(0)

# Check Bella PASS verdict in history
history = task.get("history", [])
bella_pass = False
for entry in reversed(history):
    verdict = str(entry.get("verdict", "")).upper()
    action = str(entry.get("action", "")).lower()
    by = str(entry.get("by", "")).lower()
    # Look for PASS by Bella (bella / bellalovechl_bot / reviewer)
    if verdict == "PASS" and ("bella" in by or "reviewer" in by):
        bella_pass = True
        break
    # Also accept: action=approved/done by bella with no explicit verdict
    if action in ("approved", "done") and ("bella" in by or "reviewer" in by):
        bella_pass = True
        break

if not bella_pass:
    log(f"SKIP no Bella PASS verdict found: {task_id}")
    sys.exit(0)

log(f"TRIGGER task={task_id} novel_pattern={novel_pattern or '(missing)'}")

# Build context for skill extraction
def flatten(obj, max_chars=800):
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj[:max_chars]
    if isinstance(obj, list):
        return "\n".join(str(x) for x in obj)[:max_chars]
    if isinstance(obj, dict):
        return "\n".join(f"{k}: {v}" for k, v in obj.items())[:max_chars]
    return str(obj)[:max_chars]

goal = flatten(task.get("goal", ""))
background = flatten(task.get("background", ""))
deliverables = flatten(task.get("deliverables", []))
acceptance = flatten(task.get("acceptance_criteria", []))
tech_notes = flatten(task.get("tech_notes", []))
out_of_scope = flatten(task.get("out_of_scope", []))

# Extract learnings from history entries
history_notes = []
for entry in history:
    note = entry.get("note", "")
    if note and len(note) > 20:
        history_notes.append(note[:300])
history_text = "\n".join(history_notes[-5:])  # last 5 meaningful notes

prompt = f"""You are extracting a reusable skill card from a completed engineering task.
The task was reviewed and PASSED by Bella (QA reviewer). Your job: distill what was novel
and reusable into a structured Pearl skill card.

## Task: {task.get('title', task_id)}

**Goal:** {goal}

**Background:** {background}

**Deliverables:**
{deliverables}

**Acceptance Criteria:**
{acceptance}

**Tech Notes:**
{tech_notes}

**Out of Scope:**
{out_of_scope}

**Implementation notes (from history):**
{history_text}

---

Write a Pearl skill card in this EXACT format (YAML frontmatter + body):

```markdown
---
id: SKILL-{task_id[:20]}
type: skill
title: <concise skill name, 5-10 words>
tags: [skill, <1-3 domain tags>]
trigger: <1-2 sentence: when to apply this skill — keywords and scenario>
created: {datetime.now().strftime('%Y-%m-%d')}
novel_pattern: {novel_pattern or 'yes'}
source_task: {task_id}
---

## 解法摘要

<2-4 sentences: what the solution is and why it works>

## Trigger（何時用）

<Bullet list: specific signals that this skill applies — file names, error messages, task types>

## Solution（怎麼做）

<Step-by-step or key code pattern. Include actual commands/code snippets if relevant.>

## Anti-pattern（別這樣做）

<1-2 bullet points: common wrong approach and why it fails>

## Test case（驗證仍有效）

<Single command or check that confirms this skill still works>
```

Be concrete. Name specific files, commands, and patterns from the task. No generic advice.
The card should be immediately useful to Anna when she encounters a similar problem."""

client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
try:
    response = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=1200,
        messages=[{"role": "user", "content": prompt}],
    )
    raw = response.content[0].text.strip()
except Exception as e:
    log(f"API_ERROR {task_id}: {e}")
    sys.exit(1)

# Extract the markdown block if wrapped in ```markdown ... ```
match = re.search(r"```markdown\n(.*?)```", raw, re.DOTALL)
skill_content = match.group(1).strip() if match else raw

# Write draft
draft_out.write_text(skill_content + "\n", encoding="utf-8")
log(f"DRAFTED {draft_out.name}")
print(f"skill-draft: {draft_out}")
PY

---
name: recall-mistakes
description: Quick reference lookup for past mistakes and lessons learned via grep
allowed-tools: [Bash, Grep]
---

# /recall-mistakes — Mistake Pattern Lookup

## Trigger
```
/recall-mistakes <keyword>
```

## Overview
Fast reference tool to search the shared mistakes log and extract relevant patterns without loading the entire file. Prevents repeating known errors and surfaces lessons learned.

## Source File
```
~/.claude-bots/shared/mistakes.md
```

This file is maintained by the team and contains categorized past mistakes with context and lessons.

## Execution Flow

### Step 1: Grep Search
Call Bash tool with grep to find relevant sections:

```bash
grep -i -A 10 -B 2 "<keyword>" ~/.claude-bots/shared/mistakes.md | head -60
```

**Parameters:**
- `-i`: case-insensitive matching
- `-A 10`: 10 lines of context after match
- `-B 2`: 2 lines of context before match
- `head -60`: limit output to 60 lines (prevents context overflow)

### Step 2: Parse Results

Extract matched sections and structure as:
1. **Mistake title** (section header or descriptive line)
2. **Context** (what went wrong, when, who)
3. **Root cause** (why it happened)
4. **Lesson learned** (what to do differently next time)

### Step 3: Return Format

Return **only the matched sections**, formatted as plain markdown:

```
## Mistake 1: <Title>
**Context**: <situation>
**Lesson**: <what we learned>

---

## Mistake 2: <Title>
**Context**: <situation>
**Lesson**: <what we learned>
```

**Rules:**
- Max 5 matches per query
- Preserve original line breaks and section structure
- If a match is truncated by `head -60`, add `[... truncated]` marker
- Always include line numbers if available (grep -n)

### Step 4: No Results Edge Case

If grep returns empty:
```
No relevant mistakes found for: <keyword>

Suggestions:
- Check spelling of keyword
- Try a related term (e.g., 'token' instead of 'tokens')
- Review the full mistakes.md file manually: cat ~/.claude-bots/shared/mistakes.md
```

## Examples

### Example 1: Debugging bug
```
/recall-mistakes debug
```

grep returns sections on:
- Common debugging mistakes
- How to use `/investigate` skill
- What NOT to do when tracing errors

### Example 2: Token overflow
```
/recall-mistakes token context overflow
```

grep returns sections on:
- Section 11 (subagent return slimming)
- Past context rot incidents
- Token counting practices

### Example 3: No match
```
/recall-mistakes xyz123
```

Returns: "No relevant mistakes found for: xyz123"

## When to Use

- **Before starting a complex task** — check if there's a known pitfall
- **After hitting an error** — search for similar patterns in mistakes.md
- **Code review** — look up common mistakes in your subsystem
- **Onboarding new feature** — check what went wrong last time

## Related

- [[mistakes.md]] — source file, maintained by team
- [[feedback-log]] — ongoing lessons from current projects
- [[learned-skills]] — all approved MemOcean optimization skills

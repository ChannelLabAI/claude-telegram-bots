# Dataview queries for memory_type-tagged learnings

> These snippets are meant to live inside an Obsidian note (e.g. `Ocean/Pearl/learnings/_index.md`).
> ron-builder cannot write to the vault, so they're shipped here next to the extractor.
> An assistant should copy these into a vault note after the loader + extractor land.

## 1. This week's milestones

```dataview
TABLE file.mtime AS "updated", file.folder AS "folder"
FROM "Ocean/Pearl/learnings"
WHERE memory_type = "milestone"
  AND file.mtime >= date(today) - dur(7 days)
SORT file.mtime DESC
```

## 2. Problem → milestone upgrade rate (rolling 30 days)

```dataview
TABLE length(rows) AS "count"
FROM "Ocean/Pearl/learnings"
WHERE memory_type IN ("milestone", "problem")
  AND file.mtime >= date(today) - dur(30 days)
GROUP BY memory_type
```

Manual reading: `upgrade_rate = milestones / (milestones + problems)`.

## 3. All decisions by week

```dataview
TABLE file.mtime AS "updated"
FROM "Ocean/Pearl/learnings"
WHERE memory_type = "decision"
SORT file.mtime DESC
LIMIT 50
```

## 4. Untagged learnings (backfill TODO)

```dataview
LIST
FROM "Ocean/Pearl/learnings"
WHERE memory_type = null
```

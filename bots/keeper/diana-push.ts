#!/usr/bin/env bun
/**
 * diana-push.ts — Diana C: push insights/conflicts/todos to owner inboxes
 *
 * Design:
 *  - Conflicts:    new slug-pairs from Step 14 (contradiction-flags dedup = source of truth)
 *  - Overdue todos: open commitment/action_item > 7d old (full batch) OR < 24h (ingest-trigger urgent)
 *    ↑ 24h–7d "silent zone" is intentional — new item gets one prompt push, then quiet until overdue
 *  - Insights:     PatternCandidate.promoted===true not yet in push-ledger (full batch only)
 *
 * Anti-flood 4-layer gate:
 *  1. Ledger dedup (push-ledger.json, 30d cooldown) — conflicts use contradiction-flags, not ledger
 *  2. Contradiction-flags slug-pair check (Blocker 1): skip push for already-seen pairs
 *  3. Per-batch quota ≤5 per owner (priority: conflict > urgent_todo > overdue_todo > insight)
 *  4. PatternCandidate.promoted===true gate (not raw ontology items)
 *
 * Trial period: OWNER_TO_STATEDIR all → anya (Stage 2 owner routing is out_of_scope)
 * fail-open: any error returns without crashing batch
 */

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

// ── Types (mirror keeper-batch types) ────────────────────────────────────────

export interface ConflictEntry {
  slug_a: string;
  slug_b: string;
  reason: string;
  flagged_at: string;
}

export interface EnrichedOntologyItem {
  id: string;
  tag: string;
  text: string;
  source_slug: string;
  ts: string;
  owner: string;
  status: string;
}

export interface PatternCandidate {
  key: string;
  description: string;
  category: "PATTERN" | "DECISION" | "QUESTION";
  count: number;
  first_seen: string;
  last_seen: string;
  promoted: boolean;
}

interface PushLedgerEntry {
  dedup_key: string;
  pushed_at: string;
  target_state_dir: string;
}

// ── Config ────────────────────────────────────────────────────────────────────

const LEDGER_COOLDOWN_DAYS = 30;
const PER_OWNER_QUOTA = 5;
const OVERDUE_TODO_DAYS = 7;
const URGENT_TODO_HOURS = 24;

// Trial period: all → anya. Stage 2 owner routing is out_of_scope.
const ANYA_STATE_DIR = join(import.meta.dir, "../../bots/anya");
const OWNER_TO_STATEDIR: Record<string, string> = {};

function resolveStateDir(_owner: string): string {
  return OWNER_TO_STATEDIR[_owner] ?? ANYA_STATE_DIR; // all → anya (trial lock)
}

// ── Push ledger helpers ───────────────────────────────────────────────────────

async function loadLedger(agentHome: string): Promise<PushLedgerEntry[]> {
  const path = join(agentHome, "memory", "push-ledger.json");
  try {
    return JSON.parse(await readFile(path, "utf8")) as PushLedgerEntry[];
  } catch {
    return [];
  }
}

async function saveLedger(agentHome: string, ledger: PushLedgerEntry[]): Promise<void> {
  const path = join(agentHome, "memory", "push-ledger.json");
  await writeFile(path, JSON.stringify(ledger, null, 2) + "\n", "utf8");
}

function pruneLedger(ledger: PushLedgerEntry[]): { pruned: PushLedgerEntry[]; removed: number } {
  const cutoff = new Date(Date.now() - LEDGER_COOLDOWN_DAYS * 24 * 3600 * 1000).toISOString();
  const pruned = ledger.filter(e => e.pushed_at >= cutoff);
  return { pruned, removed: ledger.length - pruned.length };
}

function isInLedger(ledger: PushLedgerEntry[], dedupKey: string): boolean {
  return ledger.some(e => e.dedup_key === dedupKey);
}

function addToLedger(ledger: PushLedgerEntry[], dedupKey: string, targetStateDir: string): void {
  ledger.push({ dedup_key: dedupKey, pushed_at: new Date().toISOString(), target_state_dir: targetStateDir });
}

// ── Inbox write helper ────────────────────────────────────────────────────────

async function writeInboxMessage(
  stateDir: string,
  filename: string,
  content: string,
  meta: Record<string, string>
): Promise<void> {
  const inboxDir = join(stateDir, "inbox", "messages");
  await mkdir(inboxDir, { recursive: true });
  const msg = {
    method: "notifications/claude/channel",
    params: { content, meta },
  };
  await writeFile(join(inboxDir, filename), JSON.stringify(msg, null, 2) + "\n", "utf8");
}

function hexRand(): string {
  return randomBytes(2).toString("hex");
}

function dateStr(): string {
  return new Date().toISOString().slice(0, 10).replace(/-/g, "");
}

// ── Push item builders ────────────────────────────────────────────────────────

interface PushItem {
  priority: number;     // 1=highest (conflict), 2=urgent_todo, 3=overdue_todo, 4=insight
  owner: string;
  dedupKey: string;     // only for ledger items; conflicts skip ledger
  useLedger: boolean;   // false = use contradiction-flags (conflicts)
  write: (stateDir: string) => Promise<void>;
  label: string;        // for logging
}

function buildConflictPushItem(
  c: ConflictEntry,
  contradictionFlagsKeys: Set<string>
): PushItem | null {
  const sortedKey = [c.slug_a, c.slug_b].sort().join("|");
  // Blocker 1: skip if slug-pair already existed in contradiction-flags BEFORE this batch
  if (contradictionFlagsKeys.has(sortedKey)) return null;

  return {
    priority: 1,
    owner: "anya",        // trial: always anya
    dedupKey: sortedKey,  // not written to ledger; contradiction-flags is the dedup source
    useLedger: false,
    label: `conflict:${sortedKey}`,
    write: async (stateDir) => {
      const filename = `diana-push-conflict-${dateStr()}-${hexRand()}.json`;
      const content =
        `🔴 [Diana 衝突偵測] ${c.slug_a} vs ${c.slug_b}\n\n${c.reason}`;
      await writeInboxMessage(stateDir, filename, content, {
        source: "diana-c-push",
        push_type: "conflict",
        severity: "high",
        slug_a: c.slug_a,
        slug_b: c.slug_b,
        dedup_key: sortedKey,
        flagged_at: c.flagged_at,
      });
    },
  };
}

function buildUrgentTodoPushItem(item: EnrichedOntologyItem): PushItem {
  const dedupKey = `urgent_todo:${item.id}`;
  return {
    priority: 2,
    owner: item.owner,
    dedupKey,
    useLedger: true,
    label: `urgent_todo:${item.id}`,
    write: async (stateDir) => {
      const filename = `diana-push-urgent-todo-${dateStr()}-${hexRand()}.json`;
      const content =
        `⚡ [Diana 緊急待辦] ${item.tag}：${item.text}\n\n來源：${item.source_slug}`;
      await writeInboxMessage(stateDir, filename, content, {
        source: "diana-c-push",
        push_type: "urgent_todo",
        severity: "high",
        item_id: item.id,
        tag: item.tag,
        owner: item.owner,
        dedup_key: dedupKey,
        ts: item.ts,
      });
    },
  };
}

function buildOverdueTodoPushItem(item: EnrichedOntologyItem): PushItem {
  const dedupKey = `overdue_todo:${item.id}`;
  return {
    priority: 3,
    owner: item.owner,
    dedupKey,
    useLedger: true,
    label: `overdue_todo:${item.id}`,
    write: async (stateDir) => {
      const filename = `diana-push-overdue-todo-${dateStr()}-${hexRand()}.json`;
      const ageMs = Date.now() - new Date(item.ts).getTime();
      const ageDays = Math.floor(ageMs / 86400000);
      const content =
        `🟡 [Diana 逾期待辦 ${ageDays}天] ${item.tag}：${item.text}\n\n來源：${item.source_slug}`;
      await writeInboxMessage(stateDir, filename, content, {
        source: "diana-c-push",
        push_type: "overdue_todo",
        severity: "medium",
        item_id: item.id,
        tag: item.tag,
        owner: item.owner,
        dedup_key: dedupKey,
        ts: item.ts,
      });
    },
  };
}

function buildInsightPushItem(pattern: PatternCandidate): PushItem {
  const dedupKey = `insight:${pattern.key}`;
  return {
    priority: 4,
    owner: "anya",  // trial: always anya
    dedupKey,
    useLedger: true,
    label: `insight:${pattern.key}`,
    write: async (stateDir) => {
      const filename = `diana-push-insight-${dateStr()}-${hexRand()}.json`;
      const content =
        `💡 [Diana 洞察] [${pattern.category}] ${pattern.key}\n\n${pattern.description}`;
      await writeInboxMessage(stateDir, filename, content, {
        source: "diana-c-push",
        push_type: "insight",
        severity: "low",
        item_id: pattern.key,
        category: pattern.category,
        dedup_key: dedupKey,
        promoted_at: pattern.last_seen,
      });
    },
  };
}

// ── Main entry point ──────────────────────────────────────────────────────────

export async function pushInsightsToOwners(opts: {
  agentHome: string;
  newConflicts: ConflictEntry[];             // from Step 14 this batch
  ontologyItems: EnrichedOntologyItem[];     // reconciled items
  isIngestTrigger: boolean;
}): Promise<{ pushed: number; skipped: number; errors: number }> {
  const { agentHome, newConflicts, ontologyItems, isIngestTrigger } = opts;
  let pushed = 0, skipped = 0, errors = 0;

  // Load + prune ledger (30-day cleanup per AC[10])
  const rawLedger = await loadLedger(agentHome);
  const { pruned: ledger, removed: pruneCount } = pruneLedger(rawLedger);
  if (pruneCount > 0) {
    process.stderr.write(
      `[diana-push] push-ledger pruned ${pruneCount} entries (before: ${rawLedger.length}, after: ${ledger.length})\n`
    );
  }

  // Load contradiction-flags — existing slug-pairs (BEFORE this batch) for Blocker 1 check
  const flagsPath = join(agentHome, "memory", "contradiction-flags.json");
  let existingContraFlagKeys = new Set<string>();
  try {
    const flags = JSON.parse(await readFile(flagsPath, "utf8")) as ConflictEntry[];
    // Build key set from ALL existing flags, then EXCLUDE the new conflicts from this batch
    // (the new conflicts were just appended to flags — they should be pushed, not skipped)
    const newConflictKeys = new Set(newConflicts.map(c => [c.slug_a, c.slug_b].sort().join("|")));
    for (const f of flags) {
      const k = [f.slug_a, f.slug_b].sort().join("|");
      if (!newConflictKeys.has(k)) existingContraFlagKeys.add(k); // only pre-existing
    }
  } catch { /* no flags file yet */ }

  // ── Build push item list ──────────────────────────────────────────────────

  const items: PushItem[] = [];

  // 1. Conflicts (all paths)
  for (const c of newConflicts) {
    const item = buildConflictPushItem(c, existingContraFlagKeys);
    if (item) items.push(item);
    else skipped++;
  }

  // 2. Todos
  const now = Date.now();
  const urgentCutoffMs = URGENT_TODO_HOURS * 3600 * 1000;
  const overdueCutoffMs = OVERDUE_TODO_DAYS * 24 * 3600 * 1000;

  for (const item of ontologyItems) {
    if (!["commitment", "action_item"].includes(item.tag)) continue;
    if (item.status !== "open" && item.status !== undefined) continue;

    const tsMs = item.ts ? (now - new Date(item.ts).getTime()) : Infinity;
    const isUrgent = tsMs <= urgentCutoffMs;      // < 24h = urgent
    const isOverdue = tsMs >= overdueCutoffMs;    // > 7d = overdue

    // Silent zone: 24h–7d = intentional, no push (design decision, not a bug)
    if (isIngestTrigger) {
      if (isUrgent) items.push(buildUrgentTodoPushItem(item));
    } else {
      if (isUrgent) items.push(buildUrgentTodoPushItem(item));
      else if (isOverdue) items.push(buildOverdueTodoPushItem(item));
    }
  }

  // 3. Insights (full batch only)
  if (!isIngestTrigger) {
    const candidatesPath = join(agentHome, "memory", "pattern-candidates.json");
    try {
      const candidates = JSON.parse(await readFile(candidatesPath, "utf8")) as PatternCandidate[];
      for (const p of candidates) {
        if (!p.promoted) continue;
        items.push(buildInsightPushItem(p));
      }
    } catch { /* no pattern-candidates yet */ }
  }

  // ── Sort by priority, apply per-owner quota ───────────────────────────────

  items.sort((a, b) => a.priority - b.priority);

  const ownerCounts = new Map<string, number>();
  const toPush: PushItem[] = [];

  for (const item of items) {
    const owner = item.owner;
    const stateDir = resolveStateDir(owner);
    const count = ownerCounts.get(stateDir) ?? 0;

    // Ledger dedup check (conflicts skip ledger)
    if (item.useLedger && isInLedger(ledger, item.dedupKey)) {
      skipped++;
      continue;
    }

    if (count >= PER_OWNER_QUOTA) {
      skipped++;
      continue; // quota exceeded, lower-priority items dropped
    }

    ownerCounts.set(stateDir, count + 1);
    toPush.push(item);
  }

  // ── Execute pushes ────────────────────────────────────────────────────────

  for (const item of toPush) {
    const stateDir = resolveStateDir(item.owner);
    try {
      await item.write(stateDir);
      // Update ledger (conflicts skip ledger, use contradiction-flags as dedup)
      if (item.useLedger) {
        addToLedger(ledger, item.dedupKey, stateDir);
      }
      pushed++;
      process.stderr.write(`[diana-push] pushed ${item.label} → ${stateDir.split("/").slice(-2).join("/")}\n`);
    } catch (err) {
      errors++;
      process.stderr.write(`[diana-push] ERROR pushing ${item.label}: ${String(err)}\n`);
    }
  }

  // Save ledger (conflicts don't affect ledger, only todo/insight do)
  try {
    await saveLedger(agentHome, ledger);
  } catch (err) {
    process.stderr.write(`[diana-push] ERROR saving push-ledger: ${String(err)}\n`);
  }

  process.stderr.write(
    `[diana-push] done — pushed=${pushed} skipped=${skipped} errors=${errors} ` +
    `(ledger: ${ledger.length} entries after prune)\n`
  );

  return { pushed, skipped, errors };
}

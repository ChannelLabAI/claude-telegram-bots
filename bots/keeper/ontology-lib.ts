/**
 * ontology-lib.ts — Shared library for Diana Phase 3 Interaction Ontology.
 *
 * Exports:
 *   tokenize, jaccard                — text similarity (AC5)
 *   parseItemBlock, serializeItemBlock — item-block codec (AC2)
 *   parseAllBlocks                   — extract all blocks from vault file content
 *   buildOntologyIndex               — scan route files → ontology-index.json (AC3)
 *   filterOntologyIndex              — AND-filter on index, since_days on ts (AC4)
 *
 * ID authority rule (R1): sentinel `<!-- ontology-item id=UUID -->` is the
 * single source of truth. YAML `id:` is a validation field; mismatches warn
 * and use the sentinel value.
 */

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";

// ── Types ─────────────────────────────────────────────────────────────────────

export const ONTOLOGY_TAGS = [
  "decision", "commitment", "action_item", "assumption", "risk",
  "dependency", "open_question", "owner_implied", "precedent", "customer_signal",
] as const;

export type OntologyTag = typeof ONTOLOGY_TAGS[number];

export interface OntologyItemBlock {
  id: string;
  tag: OntologyTag;
  text: string;
  source_slug: string;
  ts: string;
  owner?: string;
  status?: string;
  created_at?: string;
  related?: string[];
}

export interface OntologyIndexItem {
  tag: string;
  path: string;
  text: string;
  owner: string;
  status: string;
  ts: string;
  source_slug: string;
}

export interface OntologyIndex {
  version: number;
  updated_at: string;
  by_tag: Record<string, string[]>;
  by_owner: Record<string, string[]>;
  by_status: Record<string, string[]>;
  items: Record<string, OntologyIndexItem>;
}

export interface OntologyQuery {
  tag?: string;
  status?: string;
  owner?: string;
  since_days?: number;
  limit?: number;
}

// ── Constants ─────────────────────────────────────────────────────────────────

/** R1: sentinel regex — single source of truth for item ID */
export const SENTINEL_RE = /<!-- ontology-item id=([0-9a-f-]{36}) -->/;
const SENTINEL_RE_GLOBAL = /<!-- ontology-item id=([0-9a-f-]{36}) -->/g;
const SENTINEL_END = "<!-- /ontology-item -->";
const YAML_FENCE = "```";
const YAML_FENCE_OPEN = "```yaml";

// ── tokenize ──────────────────────────────────────────────────────────────────

/**
 * Mixed tokenization: whitespace-split for ASCII words + per-character for CJK.
 * Unicode ranges: 一-鿿(U+4E00–U+9FFF) + 㐀-䶿(U+3400–U+4DBF) Extension A.
 * spec R3 canonical implementation — used everywhere for Jaccard comparisons.
 */
export function tokenize(text: string): Set<string> {
  const tokens = text.match(/\b\w+\b|[一-鿿㐀-䶿]/g) ?? [];
  return new Set(tokens.map(t => t.toLowerCase()));
}

// ── jaccard ───────────────────────────────────────────────────────────────────

/** Jaccard similarity between two strings using tokenize(). */
export function jaccard(a: string, b: string): number {
  const sa = tokenize(a);
  const sb = tokenize(b);
  if (sa.size === 0 && sb.size === 0) return 0;
  let intersection = 0;
  for (const t of sa) if (sb.has(t)) intersection++;
  const union = new Set([...sa, ...sb]).size;
  return union === 0 ? 0 : intersection / union;
}

// ── YAML line parser ──────────────────────────────────────────────────────────

/** Parse one `key: value` YAML line. Returns null for blank/comment lines. */
function parseYamlLine(line: string): [string, unknown] | null {
  const colon = line.indexOf(":");
  if (colon === -1) return null;
  const key = line.slice(0, colon).trim();
  const rawValue = line.slice(colon + 1).trim();
  if (!key) return null;

  // Double- or single-quoted string
  if (
    (rawValue.startsWith('"') && rawValue.endsWith('"')) ||
    (rawValue.startsWith("'") && rawValue.endsWith("'"))
  ) {
    try { return [key, JSON.parse(rawValue)]; } catch { /* fallthrough */ }
    return [key, rawValue.slice(1, -1)];
  }

  // JSON array
  if (rawValue.startsWith("[")) {
    try { return [key, JSON.parse(rawValue)]; } catch { return [key, []]; }
  }

  return [key, rawValue];
}

function parseSimpleYaml(yaml: string): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const line of yaml.split("\n")) {
    const entry = parseYamlLine(line);
    if (entry) result[entry[0]] = entry[1];
  }
  return result;
}

// ── Serialize helpers ─────────────────────────────────────────────────────────

function serializeYaml(item: OntologyItemBlock): string {
  const lines: string[] = [
    `id: ${item.id}`,
    `tag: ${item.tag}`,
    `text: ${JSON.stringify(item.text)}`,
    `source_slug: ${item.source_slug}`,
    `ts: ${item.ts}`,
  ];
  if (item.owner !== undefined) lines.push(`owner: ${item.owner}`);
  if (item.status !== undefined) lines.push(`status: ${item.status}`);
  if (item.created_at !== undefined) lines.push(`created_at: ${item.created_at}`);
  if (item.related !== undefined) lines.push(`related: ${JSON.stringify(item.related)}`);
  return lines.join("\n");
}

// ── parseItemBlock ────────────────────────────────────────────────────────────

/**
 * Parse a single raw item block string (from sentinel to /sentinel inclusive).
 * Sentinel ID is authoritative (R1); YAML `id` mismatch logs a warning.
 * Returns null if block is malformed or tag is invalid.
 */
export function parseItemBlock(raw: string): OntologyItemBlock | null {
  const sentinelMatch = SENTINEL_RE.exec(raw);
  if (!sentinelMatch) return null;
  const sentinelId = sentinelMatch[1];

  // Locate ```yaml ... ``` within the block
  const yamlOpenIdx = raw.indexOf(YAML_FENCE_OPEN);
  if (yamlOpenIdx === -1) return null;
  const yamlBodyStart = raw.indexOf("\n", yamlOpenIdx) + 1;
  const yamlCloseIdx = raw.indexOf(YAML_FENCE, yamlBodyStart);
  if (yamlCloseIdx === -1) return null;

  const yamlBody = raw.slice(yamlBodyStart, yamlCloseIdx).trim();
  const parsed = parseSimpleYaml(yamlBody);

  // R1: sentinel is authoritative; YAML id is validation only
  if (parsed["id"] && parsed["id"] !== sentinelId) {
    process.stderr.write(
      `[ontology-lib] WARN: sentinel id=${sentinelId} ≠ YAML id=${parsed["id"]}, using sentinel\n`,
    );
  }

  const tag = parsed["tag"];
  if (typeof tag !== "string" || !(ONTOLOGY_TAGS as readonly string[]).includes(tag)) {
    return null;
  }

  return {
    id: sentinelId,
    tag: tag as OntologyTag,
    text: String(parsed["text"] ?? ""),
    source_slug: String(parsed["source_slug"] ?? "unknown"),
    ts: String(parsed["ts"] ?? ""),
    owner: parsed["owner"] !== undefined ? String(parsed["owner"]) : undefined,
    status: parsed["status"] !== undefined ? String(parsed["status"]) : undefined,
    created_at: parsed["created_at"] !== undefined ? String(parsed["created_at"]) : undefined,
    related: Array.isArray(parsed["related"]) ? (parsed["related"] as unknown[]).map(String) : undefined,
  };
}

// ── serializeItemBlock ────────────────────────────────────────────────────────

/** Serialize an OntologyItemBlock to the canonical item-block format (AC2). */
export function serializeItemBlock(item: OntologyItemBlock): string {
  return [
    `<!-- ontology-item id=${item.id} -->`,
    YAML_FENCE_OPEN,
    serializeYaml(item),
    YAML_FENCE,
    SENTINEL_END,
  ].join("\n");
}

// ── parseAllBlocks ────────────────────────────────────────────────────────────

/** Extract all valid item blocks from vault file content. */
export function parseAllBlocks(content: string): OntologyItemBlock[] {
  const results: OntologyItemBlock[] = [];
  SENTINEL_RE_GLOBAL.lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = SENTINEL_RE_GLOBAL.exec(content)) !== null) {
    const blockStart = match.index;
    const endIdx = content.indexOf(SENTINEL_END, blockStart);
    if (endIdx === -1) continue;
    const blockEnd = endIdx + SENTINEL_END.length;
    const raw = content.slice(blockStart, blockEnd);
    const item = parseItemBlock(raw);
    if (item) results.push(item);
  }

  return results;
}

// ── buildOntologyIndex ────────────────────────────────────────────────────────

/**
 * Scan all files referenced in routes, parse item blocks, build index.
 * Writes `vaultDir/_index/ontology-index.json` atomically (unless dryRun).
 * routes: tag → relative-vault-path (same shape as ONTOLOGY_ROUTES in keeper-batch).
 */
export async function buildOntologyIndex(
  vaultDir: string,
  routes: Record<string, string>,
  dryRun = false,
): Promise<OntologyIndex> {
  const index: OntologyIndex = {
    version: 1,
    updated_at: new Date().toISOString(),
    by_tag: {},
    by_owner: {},
    by_status: {},
    items: {},
  };

  const uniquePaths = new Set(Object.values(routes));

  for (const relPath of uniquePaths) {
    const absPath = join(vaultDir, relPath);
    let content: string;
    try {
      content = await readFile(absPath, "utf8");
    } catch {
      continue;
    }

    for (const item of parseAllBlocks(content)) {
      const { id } = item;
      if (index.items[id]) continue; // deduplicate by id

      const owner = item.owner ?? "unassigned";
      const status = item.status ?? "open";

      index.items[id] = {
        tag: item.tag,
        path: relPath,
        text: item.text,
        owner,
        status,
        ts: item.ts,
        source_slug: item.source_slug,
      };

      (index.by_tag[item.tag] ??= []).push(id);
      (index.by_owner[owner] ??= []).push(id);
      (index.by_status[status] ??= []).push(id);
    }
  }

  if (!dryRun) {
    const indexDir = join(vaultDir, "_index");
    await mkdir(indexDir, { recursive: true });
    const indexPath = join(indexDir, "ontology-index.json");
    // Atomic write: write to temp then rename
    const tmpPath = indexPath + ".tmp";
    await writeFile(tmpPath, JSON.stringify(index, null, 2) + "\n", "utf8");
    const { renameSync } = await import("node:fs");
    renameSync(tmpPath, indexPath);
  }

  return index;
}

// ── filterOntologyIndex ───────────────────────────────────────────────────────

/**
 * AND-filter the ontology index.
 * since_days filters on `ts` (event time), not `created_at` (ingest time). (R2)
 * Results sorted by ts descending.
 */
export function filterOntologyIndex(
  index: OntologyIndex,
  query: OntologyQuery,
): OntologyIndexItem[] {
  const { tag, status, owner, since_days, limit } = query;

  let candidates = Object.keys(index.items);

  if (tag) {
    const ids = new Set(index.by_tag[tag] ?? []);
    candidates = candidates.filter(id => ids.has(id));
  }

  if (status) {
    const ids = new Set(index.by_status[status] ?? []);
    candidates = candidates.filter(id => ids.has(id));
  }

  if (owner) {
    const ids = new Set(index.by_owner[owner] ?? []);
    candidates = candidates.filter(id => ids.has(id));
  }

  if (since_days !== undefined && since_days > 0) {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - since_days);
    candidates = candidates.filter(id => {
      const ts = index.items[id].ts;
      if (!ts) return false;
      try { return new Date(ts) >= cutoff; } catch { return false; }
    });
  }

  let results = candidates.map(id => index.items[id]);
  results.sort((a, b) => (b.ts > a.ts ? 1 : b.ts < a.ts ? -1 : 0));

  if (limit !== undefined && limit > 0) {
    results = results.slice(0, limit);
  }

  return results;
}

#!/usr/bin/env bun
/**
 * query-ontology.ts — CLI for querying the Interaction Ontology index (AC8).
 *
 * Usage:
 *   bun run query-ontology.ts --tag commitment --status open
 *   bun run query-ontology.ts --owner anya --since 7
 *   bun run query-ontology.ts --tag any --since 1 --json
 *   bun run query-ontology.ts --limit 5
 *
 * Options:
 *   --tag <tag|any>    Filter by ontology tag ("any" = no filter)
 *   --status <status>  Filter by status (open|closed|needs_review|superseded)
 *   --owner <name>     Filter by owner
 *   --since <days>     Only items with ts within last N days
 *   --limit <n>        Max results (default: 20)
 *   --json             Output raw JSON instead of human-readable text
 */

import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";

import { filterOntologyIndex } from "./ontology-lib";
import type { OntologyIndex, OntologyQuery } from "./ontology-lib";

const MANIFEST_PATH = join(import.meta.dir, "AGENT_MANIFEST.json");

// ── Arg parser ────────────────────────────────────────────────────────────────

function parseArgs(argv: string[]): { query: OntologyQuery; json: boolean } {
  const args = argv.slice(2);
  const query: OntologyQuery = {};
  let json = false;

  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    const next = args[i + 1];

    switch (flag) {
      case "--tag":
        if (next && next !== "any") query.tag = next;
        i++;
        break;
      case "--status":
        if (next) { query.status = next; i++; }
        break;
      case "--owner":
        if (next) { query.owner = next; i++; }
        break;
      case "--since":
        if (next) { query.since_days = parseInt(next, 10); i++; }
        break;
      case "--limit":
        if (next) { query.limit = parseInt(next, 10); i++; }
        break;
      case "--json":
        json = true;
        break;
      default:
        process.stderr.write(`Unknown flag: ${flag}\n`);
    }
  }

  if (query.limit === undefined) query.limit = 20;
  return { query, json };
}

// ── Human-readable formatter ──────────────────────────────────────────────────

function formatHuman(query: OntologyQuery, index: OntologyIndex): void {
  const results = filterOntologyIndex(index, query);
  const totalItems = Object.keys(index.items).length;

  if (results.length === 0) {
    const tag = query.tag ?? "item";
    console.log(`📭 查無符合條件的 ${tag} item`);
    return;
  }

  const filterDesc: string[] = [];
  if (query.tag) filterDesc.push(`tag: ${query.tag}`);
  if (query.status) filterDesc.push(`status: ${query.status}`);
  if (query.owner) filterDesc.push(`owner: ${query.owner}`);
  if (query.since_days) filterDesc.push(`since: ${query.since_days}d`);
  const desc = filterDesc.length > 0 ? ` [${filterDesc.join(", ")}]` : "";

  console.log(`📋 ${results.length} 筆結果${desc}（index 共 ${totalItems} 筆，updated_at: ${index.updated_at.slice(0, 19)}）\n`);

  for (const item of results) {
    const ts = item.ts ? item.ts.slice(0, 10) : "—";
    const owner = item.owner !== "unassigned" ? ` [${item.owner}]` : "";
    const statusIcon = item.status === "open" ? "🟢" : item.status === "closed" ? "✅" : item.status === "needs_review" ? "⚠️" : "🔄";
    console.log(`${statusIcon} [${item.tag}]${owner} ${item.text}`);
    console.log(`   来源: ${item.source_slug}  ts: ${ts}  path: ${item.path}\n`);
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const { query, json } = parseArgs(process.argv);

  // Load VAULT_DIR from manifest
  let vaultDir: string;
  try {
    const manifest = JSON.parse(await readFile(MANIFEST_PATH, "utf8"));
    vaultDir = manifest.VAULT_DIR as string;
  } catch {
    process.stderr.write("ERROR: could not load AGENT_MANIFEST.json\n");
    process.exit(1);
  }

  const indexPath = join(vaultDir, "_index", "ontology-index.json");
  if (!existsSync(indexPath)) {
    process.stderr.write(`ERROR: index not found at ${indexPath}\nRun: bun run keeper-batch.ts\n`);
    process.exit(1);
  }

  let index: OntologyIndex;
  try {
    index = JSON.parse(await readFile(indexPath, "utf8")) as OntologyIndex;
  } catch (err) {
    process.stderr.write(`ERROR: could not parse index: ${String(err)}\n`);
    process.exit(1);
  }

  if (json) {
    const results = filterOntologyIndex(index, query);
    console.log(JSON.stringify(results, null, 2));
  } else {
    formatHuman(query, index);
  }
}

main().catch(err => {
  process.stderr.write(`fatal: ${String(err)}\n`);
  process.exit(1);
});

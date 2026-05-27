#!/usr/bin/env bun
/**
 * diana-query.ts — relay handler for diana:query signal (AC4).
 *
 * Called by relay-listener.ts when a diana:query relay file arrives.
 * Reads the relay JSON, loads ontology-index.json, filters via
 * filterOntologyIndex(), and writes a TG-readable relay response.
 *
 * Usage:
 *   bun run diana-query.ts <relay-file-path>
 *
 * Relay payload schema:
 *   { "type": "query", "query": { tag?, status?, owner?, since_days?, limit? }, "reply_to": "@Anyachl_bot" }
 *
 * Response times: cold 0→reply ≤ 5s (no LLM, pure lookup).
 */

import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";

import { filterOntologyIndex } from "./ontology-lib";
import type { OntologyIndex, OntologyQuery } from "./ontology-lib";

// ── Config ────────────────────────────────────────────────────────────────────

const MANIFEST_PATH = join(import.meta.dir, "AGENT_MANIFEST.json");
const RELAY_DIR = join(import.meta.dir, "../../relay");
const INDEX_STALE_MS = 24 * 60 * 60 * 1000; // 24h

const TODAY = new Date().toISOString().slice(0, 10);

function log(msg: string): void {
  process.stderr.write(`[diana-query ${TODAY}] ${msg}\n`);
}

interface Manifest {
  VAULT_DIR: string;
}

async function loadManifest(): Promise<Manifest> {
  return JSON.parse(await readFile(MANIFEST_PATH, "utf8"));
}

// ── Index loader ──────────────────────────────────────────────────────────────

async function loadIndex(vaultDir: string): Promise<OntologyIndex | null> {
  const indexPath = join(vaultDir, "_index", "ontology-index.json");
  if (!existsSync(indexPath)) return null;

  // Stale check
  try {
    const s = await stat(indexPath);
    if (Date.now() - s.mtimeMs > INDEX_STALE_MS) {
      log(`WARN: index stale (mtime=${new Date(s.mtimeMs).toISOString()})`);
      return null; // treat as missing to trigger fallback message
    }
  } catch {
    return null;
  }

  try {
    return JSON.parse(await readFile(indexPath, "utf8")) as OntologyIndex;
  } catch (err) {
    log(`ERROR: index parse failed: ${String(err)}`);
    return null;
  }
}

// ── Result formatter ──────────────────────────────────────────────────────────

function formatFilterSummary(query: OntologyQuery): string {
  const parts: string[] = [];
  if (query.tag) parts.push(`tag=${query.tag}`);
  if (query.status) parts.push(`status=${query.status}`);
  if (query.owner) parts.push(`owner=${query.owner}`);
  if (query.since_days) parts.push(`since_days=${query.since_days}`);
  if (query.limit) parts.push(`limit=${query.limit}`);
  return parts.join(", ") || "（無過濾條件）";
}

function formatQueryResult(query: OntologyQuery, index: OntologyIndex): string {
  const results = filterOntologyIndex(index, query);

  if (results.length === 0) {
    const tag = query.tag ?? "item";
    return `📭 查無符合條件的 ${tag} item（條件：${formatFilterSummary(query)}）`;
  }

  const lines: string[] = [`📋 查詢結果（${results.length} 筆）— 條件：${formatFilterSummary(query)}\n`];
  for (const item of results) {
    const ts = item.ts ? item.ts.slice(0, 10) : "—";
    const owner = item.owner !== "unassigned" ? ` [${item.owner}]` : "";
    const status = item.status !== "open" ? ` ⚠️ ${item.status}` : "";
    lines.push(`• [${item.tag}]${owner}${status} ${item.text}（${ts}）`);
  }
  return lines.join("\n");
}

// ── Relay writer ──────────────────────────────────────────────────────────────

async function writeRelayResponse(text: string, replyTo: string): Promise<void> {
  await mkdir(RELAY_DIR, { recursive: true });
  const ts = Date.now();
  const relayPath = join(RELAY_DIR, `${ts}-diana-query-response.json`);
  const msg = {
    from_bot: "diana-query",
    chat_id: "self",
    recipient: replyTo.replace(/^@/, "").toLowerCase(),
    text,
    ts: new Date().toISOString(),
  };
  await writeFile(relayPath, JSON.stringify(msg, null, 2) + "\n", "utf8");
  log(`relay response written → ${relayPath}`);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const relayFile = process.argv[2];
  if (!relayFile) {
    log("ERROR: no relay file path provided");
    process.exit(1);
  }

  // Parse relay file
  let payload: { type?: string; query?: OntologyQuery; reply_to?: string };
  try {
    payload = JSON.parse(await readFile(relayFile, "utf8"));
  } catch (err) {
    log(`ERROR: could not read relay file ${relayFile}: ${String(err)}`);
    process.exit(1);
  }

  const query: OntologyQuery = payload.query ?? {};
  const replyTo = payload.reply_to ?? "anya";
  log(`query received: ${JSON.stringify(query)}`);

  const manifest = await loadManifest();
  const index = await loadIndex(manifest.VAULT_DIR);

  let responseText: string;
  if (!index) {
    responseText = `⚠️ Ontology index 不存在或超過 24h 未更新。請先發送 diana:batch 觸發一次夜間批次建立索引。`;
  } else {
    responseText = formatQueryResult(query, index);
  }

  await writeRelayResponse(responseText, replyTo);
  log(`query handled. result: ${responseText.slice(0, 80)}...`);
}

main().catch(err => {
  process.stderr.write(`[diana-query] fatal: ${String(err)}\n`);
  process.exit(1);
});

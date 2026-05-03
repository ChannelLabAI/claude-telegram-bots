#!/usr/bin/env bun
// keeper-batch.ts — Keeper Agent Phase 1 nightly batch
// Triggered: OS crontab 0 23 * * * (23:00 CST = 15:00 UTC)

import Anthropic from "@anthropic-ai/sdk";
import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, basename, dirname } from "node:path";
import { spawnSync } from "node:child_process";

// ── Config ────────────────────────────────────────────────────────────────────

const DRY_RUN = process.argv.includes("--dry-run");
const MANIFEST_PATH = join(import.meta.dir, "AGENT_MANIFEST.json");

interface Manifest {
  AGENT_HOME: string;
  VAULT_DIR: string;
  USER_INBOX_DIR: string;
}

async function loadManifest(): Promise<Manifest> {
  return JSON.parse(await readFile(MANIFEST_PATH, "utf8"));
}

// M3: module-level config, set in main() after loadManifest
let _AGENT_HOME = import.meta.dir;

// B5: strategic model resolved from model-router.yml
let _strategicModel = "claude-opus-4-7";

// B1: whitelist of allowed vault subdirectories
const ALLOWED_SUBDIRS = new Set([
  "技術海圖", "珍珠卡", "企劃", "Chart", "Reports", "_drafts",
]);

const TODAY = new Date().toISOString().slice(0, 10); // YYYY-MM-DD

// ── Logging ───────────────────────────────────────────────────────────────────

function log(msg: string): void {
  process.stderr.write(`[keeper ${TODAY}] ${msg}\n`);
}

// ── B5: Load model-router.yml ─────────────────────────────────────────────────

interface ModelRouter {
  routes: Record<string, string>;
  models: Record<string, string>;
}

function parseModelRouterYaml(content: string): ModelRouter {
  const routes: Record<string, string> = {};
  const models: Record<string, string> = {};
  let section = "";
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    if (trimmed === "routes:") { section = "routes"; continue; }
    if (trimmed === "models:") { section = "models"; continue; }
    if (/^\S/.test(line) && trimmed.includes(":")) { section = ""; continue; }
    if (section && line.startsWith("  ")) {
      const m = trimmed.match(/^([\w-]+):\s+(\S+)/);
      if (m) {
        if (section === "routes") routes[m[1]] = m[2];
        else if (section === "models") models[m[1]] = m[2];
      }
    }
  }
  return { routes, models };
}

async function loadModelRouter(): Promise<void> {
  const routerPath = join(_AGENT_HOME, "../../shared/config/model-router.yml");
  try {
    const content = await readFile(routerPath, "utf8");
    const parsed = parseModelRouterYaml(content);
    const alias = parsed.routes["strategic"] ?? "claude-opus";
    _strategicModel = parsed.models[alias] ?? alias;
    log(`model-router: strategic tier = ${_strategicModel}`);
  } catch (err) {
    log(`WARN: could not load model-router.yml: ${String(err)}, using fallback ${_strategicModel}`);
  }
}

// ── N1: Dry-run-safe file write (fixed dirname) ───────────────────────────────

async function safeWrite(path: string, content: string): Promise<void> {
  if (DRY_RUN) {
    log(`DRY-RUN would write: ${path} (${content.length} bytes)`);
    return;
  }
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content, "utf8");
  log(`wrote: ${path}`);
}

// ── memocean MCP helper (M3: path derived from _AGENT_HOME) ──────────────────

interface MCPResult {
  result?: { content?: Array<{ text?: string }> };
  error?: { message?: string };
}

function callMemocean(toolName: string, args: Record<string, unknown>): unknown {
  const memoceanPath = join(_AGENT_HOME, "../../shared/memocean-mcp");
  const pyScript = `
import json, sys, os
os.environ.setdefault("CHANNELLAB_BOTS_ROOT", os.path.expanduser("~/.claude-bots"))
sys.path.insert(0, ${JSON.stringify(memoceanPath)})
try:
    from memocean_mcp.server import handle_request
    req = {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":${JSON.stringify(toolName)},"arguments":${JSON.stringify(args)}}}
    r = handle_request(req)
    print(json.dumps(r))
except Exception as e:
    print(json.dumps({"error":{"message":str(e)}}))
`;
  const result = spawnSync("python3", ["-c", pyScript], {
    encoding: "utf8",
    env: { ...process.env },
    timeout: 30000,
  });
  if (result.error) return null;
  try {
    const r: MCPResult = JSON.parse(result.stdout.trim());
    if (r.error) { log(`memocean ${toolName} error: ${r.error.message}`); return null; }
    const text = r.result?.content?.[0]?.text;
    if (!text) return null;
    return JSON.parse(text);
  } catch { return null; }
}

// ── Anthropic API (M3: secrets path, M4: API key regex) ──────────────────────

function loadApiKey(): string {
  // M3: derive from _AGENT_HOME
  const secretsPath = join(_AGENT_HOME, "../../shared/secrets/llm-keys.env");
  try {
    const content = require("fs").readFileSync(secretsPath, "utf8") as string;
    for (const line of content.split("\n")) {
      // M4: handle quoted values and inline comments
      const m = line.match(/^ANTHROPIC_API_KEY\s*=\s*(.+)$/);
      if (m) {
        let val = m[1].trim();
        val = val.replace(/\s+#.*$/, "");       // strip inline comment
        val = val.replace(/^["']|["']$/g, "");  // strip surrounding quotes
        return val;
      }
    }
  } catch {}
  return process.env.ANTHROPIC_API_KEY ?? "";
}

// M2: JSON schema validators for Opus outputs
const ONTOLOGY_TAGS = [
  "decision", "commitment", "action_item", "assumption", "risk",
  "dependency", "open_question", "owner_implied", "precedent", "customer_signal",
] as const;

type OntologyTag = typeof ONTOLOGY_TAGS[number];

interface OntologyItem {
  tag: OntologyTag;
  text: string;
  source_slug: string;
  ts: string;
}

interface ClassificationResult {
  subdir: string;
  title: string;
  is_duplicate: boolean;
  duplicate_hint: string | null;
}

function validateOntologyItem(item: unknown): item is OntologyItem {
  if (!item || typeof item !== "object") return false;
  const o = item as Record<string, unknown>;
  return (
    typeof o.tag === "string" &&
    (ONTOLOGY_TAGS as readonly string[]).includes(o.tag) &&
    typeof o.text === "string" && o.text.length > 0 &&
    typeof o.source_slug === "string" &&
    typeof o.ts === "string"
  );
}

function validateClassification(parsed: unknown): parsed is ClassificationResult {
  if (!parsed || typeof parsed !== "object") return false;
  const p = parsed as Record<string, unknown>;
  return (
    typeof p.subdir === "string" && p.subdir.length > 0 &&
    typeof p.title === "string" && p.title.length > 0 &&
    typeof p.is_duplicate === "boolean"
  );
}

// B5: use _strategicModel (resolved from model-router.yml)
async function callOpus(systemPrompt: string, userContent: string): Promise<string> {
  const apiKey = loadApiKey();
  if (!apiKey) { log("WARN: no ANTHROPIC_API_KEY"); return ""; }
  const client = new Anthropic({ apiKey });
  const msg = await client.messages.create({
    model: _strategicModel,
    max_tokens: 2048,
    system: systemPrompt,
    messages: [{ role: "user", content: userContent }],
  });
  return msg.content[0].type === "text" ? msg.content[0].text : "";
}

// ── Batch log types ───────────────────────────────────────────────────────────

interface BatchAction {
  action: string;
  path?: string;
  result: string;
  detail?: string;
}

// ── Step 1: Scan inbox ────────────────────────────────────────────────────────

async function scanInbox(userInboxDir: string): Promise<string[]> {
  const inboxDirs = [join(userInboxDir, "anya", "inbox", "messages")];
  const items: string[] = [];

  for (const dir of inboxDirs) {
    if (!existsSync(dir)) { log(`inbox dir not found: ${dir}`); continue; }
    const files = await readdir(dir).catch(() => [] as string[]);
    for (const f of files) {
      if (f.includes(".read-by-") || f.startsWith(".")) continue;
      if (!f.endsWith(".json") && !f.endsWith(".md")) continue;
      const markerPath = join(dir, `${f}.read-by-keeper`);
      if (existsSync(markerPath)) continue;
      items.push(join(dir, f));
    }
  }

  log(`Step 1: found ${items.length} inbox items`);
  return items;
}

// ── Step 2: Ontology extraction ───────────────────────────────────────────────

const ONTOLOGY_SYSTEM = `You are an interaction ontology extractor for a team knowledge system.
Analyze conversation records and identify structured patterns.

For each identifiable item, output a JSON array with objects:
{ "tag": "<one of the 10 tags>", "text": "<quoted or paraphrased content>", "source_slug": "<slug>", "ts": "<ISO timestamp if available>" }

Tags: decision, commitment, action_item, assumption, risk, dependency, open_question, owner_implied, precedent, customer_signal.

Output ONLY a valid JSON array, no explanation.`;

async function extractOntology(
  agentHome: string,
  actions: BatchAction[]
): Promise<OntologyItem[]> {
  log("Step 2: extracting interaction ontology...");

  const radarQuery = `date:${TODAY} type:seabed`;
  if (DRY_RUN) {
    log(`DRY-RUN Step 2a: would call memocean_radar_search query="${radarQuery}"`);
    log(`DRY-RUN Step 2b: would call claude-opus to extract ontology tags`);
    log(`DRY-RUN Step 2c: would write logs/${TODAY}-ontology.json`);
    actions.push({ action: "ontology_extract", result: "dry-run", detail: "skipped in dry-run" });
    return [];
  }

  const radarResult = callMemocean("memocean_radar_search", { query: radarQuery, limit: 20 }) as Array<{ slug: string }> | null;
  const slugs: string[] = Array.isArray(radarResult) ? radarResult.map(r => r.slug).filter(Boolean) : [];
  log(`Step 2a: found ${slugs.length} seabed slugs for today`);

  if (slugs.length === 0) {
    log("Step 2: no seabed records for today, skipping ontology extraction");
    actions.push({ action: "ontology_extract", result: "skip", detail: "no seabed records for today" });
    return [];
  }

  const records: Array<{ slug: string; content: string }> = [];
  for (const slug of slugs.slice(0, 10)) {
    const content = callMemocean("memocean_seabed_get", { slug }) as string | null;
    if (content && typeof content === "string") {
      records.push({ slug, content: content.slice(0, 1000) });
    }
  }

  if (records.length === 0) {
    log("Step 2: could not fetch seabed content");
    actions.push({ action: "ontology_extract", result: "skip", detail: "no seabed content fetched" });
    return [];
  }

  const userContent = records.map(r => `--- ${r.slug} ---\n${r.content}`).join("\n\n");

  let items: OntologyItem[] = [];
  try {
    const raw = await callOpus(ONTOLOGY_SYSTEM, userContent);
    const parsed = JSON.parse(raw.trim().replace(/^```json\n?/, "").replace(/\n?```$/, ""));
    // M2: validate each item against schema
    items = Array.isArray(parsed) ? parsed.filter(validateOntologyItem) : [];
    const rawCount = Array.isArray(parsed) ? parsed.length : 0;
    if (rawCount !== items.length) {
      log(`Step 2b: filtered ${rawCount - items.length} invalid ontology items`);
    }
    log(`Step 2b: extracted ${items.length} valid ontology items`);
  } catch (err) {
    log(`Step 2b: parse error: ${String(err)}`);
    actions.push({ action: "ontology_extract", result: "error", detail: String(err) });
    return [];
  }

  actions.push({ action: "ontology_extract", result: "ok", detail: `${items.length} items from ${records.length} seabed records` });
  return items;
}

// ── Step 3: Process inbox items ───────────────────────────────────────────────

const CLASSIFY_SYSTEM = `You are classifying Obsidian vault inbox items for the Ocean knowledge base.
Given an inbox item, respond with a JSON object:
{
  "subdir": "<Ocean subdirectory: 技術海圖 | 珍珠卡 | 企劃 | Chart | Reports | _drafts>",
  "title": "<clean title for the file>",
  "is_duplicate": <true|false>,
  "duplicate_hint": "<slug if likely duplicate, else null>"
}
Output ONLY valid JSON.`;

async function processInboxItems(
  items: string[],
  vaultDir: string,
  actions: BatchAction[]
): Promise<number> {
  if (DRY_RUN) {
    for (const item of items) {
      log(`DRY-RUN Step 3: would classify + process: ${basename(item)}`);
    }
    actions.push({ action: "inbox_process", result: "dry-run", detail: `${items.length} items would be processed` });
    return items.length;
  }

  let processed = 0;
  // B2: intra-batch dedup set
  const writtenInBatch = new Set<string>();

  for (const itemPath of items) {
    try {
      const content = await readFile(itemPath, "utf8");
      const snippet = content.slice(0, 500);

      callMemocean("memocean_radar_search", { query: snippet.slice(0, 100), limit: 3 });

      let classification: ClassificationResult = {
        subdir: "_drafts", title: basename(itemPath, ".json"), is_duplicate: false, duplicate_hint: null
      };

      try {
        const raw = await callOpus(CLASSIFY_SYSTEM, `Item path: ${basename(itemPath)}\n\nContent:\n${snippet}`);
        const parsed = JSON.parse(raw.trim().replace(/^```json\n?/, "").replace(/\n?```$/, ""));
        // M2: validate classification schema
        if (validateClassification(parsed)) {
          classification = parsed;
        } else {
          log(`Step 3: invalid classification schema for ${basename(itemPath)}, using defaults`);
        }
      } catch { /* keep defaults */ }

      // B1: whitelist check + path traversal guard
      if (!ALLOWED_SUBDIRS.has(classification.subdir)) {
        log(`Step 3: subdir "${classification.subdir}" not in whitelist, using _drafts`);
        classification.subdir = "_drafts";
      }
      const destDir = join(vaultDir, classification.subdir);
      if (!destDir.startsWith(vaultDir)) {
        log(`Step 3: path traversal attempt blocked for ${basename(itemPath)}`);
        actions.push({ action: "inbox_file", path: itemPath, result: "blocked", detail: "path traversal" });
        continue;
      }

      if (classification.is_duplicate) {
        log(`Step 3: ${basename(itemPath)} → duplicate (${classification.duplicate_hint}), merging metadata`);
        actions.push({ action: "inbox_merge", path: itemPath, result: "merged", detail: `duplicate of ${classification.duplicate_hint}` });
      } else {
        const sanitizedTitle = classification.title.replace(/[^a-zA-Z0-9一-鿿_-]/g, "-").slice(0, 60);
        await mkdir(destDir, { recursive: true });

        // B2: avoid file clobber — counter suffix + intra-batch dedup
        let destFile = join(destDir, `${TODAY}-${sanitizedTitle}.md`);
        let counter = 1;
        while (existsSync(destFile) || writtenInBatch.has(destFile)) {
          destFile = join(destDir, `${TODAY}-${sanitizedTitle}-${counter}.md`);
          counter++;
        }
        writtenInBatch.add(destFile);

        // B3: append wikilink footer
        const wikilinks = `\n\n[[Ocean/${classification.subdir}]] [[${TODAY}]]`;
        await writeFile(destFile, content + wikilinks, "utf8");
        log(`Step 3: ${basename(itemPath)} → ${destFile}`);
        actions.push({ action: "inbox_file", path: destFile, result: "written", detail: classification.subdir });
      }

      await writeFile(`${itemPath}.read-by-keeper`, new Date().toISOString(), "utf8");
      processed++;
    } catch (err) {
      log(`Step 3 error for ${basename(itemPath)}: ${String(err)}`);
      actions.push({ action: "inbox_file", path: itemPath, result: "error", detail: String(err) });
    }
  }
  return processed;
}

// ── Step 4: Conflict detection (N2: reliable AUTHOR: prefix parsing) ──────────

async function detectConflicts(vaultDir: string, actions: BatchAction[]): Promise<number> {
  if (DRY_RUN) {
    log("DRY-RUN Step 4: would check git log for multi-author changes in last 24h");
    return 0;
  }

  // N2: use AUTHOR: prefix to reliably distinguish author lines from file paths
  const result = spawnSync(
    "git",
    ["log", "--since=24 hours ago", "--name-only", "--pretty=format:AUTHOR:%an", "--", "*.md"],
    { cwd: vaultDir, encoding: "utf8", timeout: 10000 }
  );

  if (result.error || !result.stdout) {
    log("Step 4: no git or no changes");
    return 0;
  }

  const fileAuthors = new Map<string, Set<string>>();
  let currentAuthor = "";
  for (const line of result.stdout.split("\n").filter(Boolean)) {
    if (line.startsWith("AUTHOR:")) {
      currentAuthor = line.slice(7);
    } else if (currentAuthor) {
      if (!fileAuthors.has(line)) fileAuthors.set(line, new Set());
      fileAuthors.get(line)!.add(currentAuthor);
    }
  }

  let conflicts = 0;
  for (const [file, authors] of fileAuthors) {
    if (authors.size > 1) {
      log(`Step 4: conflict in ${file} — authors: ${[...authors].join(", ")}`);
      actions.push({ action: "conflict", path: file, result: "detected", detail: [...authors].join(", ") });
      conflicts++;
    }
  }

  log(`Step 4: ${conflicts} conflicts detected`);
  return conflicts;
}

// ── Step 6: Relay summary (B4: @Anyachl_bot prefix, M1: ISO-8601 ts) ─────────

async function writeRelay(
  items: OntologyItem[],
  processed: number,
  conflicts: number,
  relayDir: string
): Promise<void> {
  const commitments = items.filter(i => i.tag === "commitment").length;
  const assumptions = items.filter(i => i.tag === "assumption").length;
  const ownerImplied = items.filter(i => i.tag === "owner_implied").length;
  const openQ = items.filter(i => i.tag === "open_question").length;

  // B4: relay text must start with @Anyachl_bot for routing
  const summary = `@Anyachl_bot 📋 Keeper 日報 ${TODAY}：inbox 處理 ${processed} 件｜衝突 ${conflicts} 個｜承諾未指派 ${ownerImplied} 個｜assumption ${assumptions} 個｜open_question ${openQ} 個｜commitment ${commitments} 個`;

  const relayMsg = {
    from_bot: "keeper",
    chat_id: "self",
    recipient: "anya",
    text: summary,
    message_id: 0,
    ts: new Date().toISOString(),  // M1: ISO-8601
  };

  const relayPath = join(relayDir, `${Date.now()}-keeper-daily.json`);
  if (DRY_RUN) {
    log(`DRY-RUN Step 6: would write relay: ${relayPath}`);
    log(`DRY-RUN relay content: ${summary}`);
    return;
  }

  await safeWrite(relayPath, JSON.stringify(relayMsg, null, 2) + "\n");
  log(`Step 6: relay written → ${relayPath}`);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log(`=== Keeper Agent Phase 1 batch ${DRY_RUN ? "(DRY-RUN)" : ""} ===`);

  const manifest = await loadManifest();
  const { AGENT_HOME, VAULT_DIR, USER_INBOX_DIR } = manifest;

  // M3: set module-level path so callMemocean/loadApiKey use it
  _AGENT_HOME = AGENT_HOME;

  // B5: resolve strategic model from model-router.yml
  await loadModelRouter();

  const RELAY_DIR = join(USER_INBOX_DIR, "..", "relay");
  const LOGS_DIR = join(AGENT_HOME, "logs");
  const STATE_PATH = join(AGENT_HOME, "batch-state.json");

  await mkdir(LOGS_DIR, { recursive: true });

  const actions: BatchAction[] = [];

  const inboxItems = await scanInbox(USER_INBOX_DIR);
  const ontologyItems = await extractOntology(AGENT_HOME, actions);
  const processed = await processInboxItems(inboxItems, VAULT_DIR, actions);
  const conflicts = await detectConflicts(VAULT_DIR, actions);

  const batchLog = {
    date: TODAY,
    dry_run: DRY_RUN,
    inbox_scanned: inboxItems.length,
    items_processed: processed,
    conflicts_detected: conflicts,
    ontology_items: ontologyItems.length,
    actions,
  };

  await safeWrite(
    join(LOGS_DIR, `${TODAY}-batch.json`),
    JSON.stringify(batchLog, null, 2) + "\n"
  );

  await safeWrite(
    join(LOGS_DIR, `${TODAY}-ontology.json`),
    JSON.stringify({ date: TODAY, items: ontologyItems }, null, 2) + "\n"
  );

  const stateUpdate = {
    last_run: new Date().toISOString(),
    items_processed: processed,
    last_ontology_log: ontologyItems.length > 0 ? `logs/${TODAY}-ontology.json` : null,
    last_batch_log: `logs/${TODAY}-batch.json`,
  };

  if (!DRY_RUN) {
    await writeFile(STATE_PATH, JSON.stringify(stateUpdate, null, 2) + "\n", "utf8");
    log("Step 5: batch-state.json updated");
  } else {
    log(`DRY-RUN Step 5: would update batch-state.json: last_run=${stateUpdate.last_run}`);
  }

  await writeRelay(ontologyItems, processed, conflicts, RELAY_DIR);

  log("=== Batch complete ===");
  log(`inbox: ${inboxItems.length} scanned, ${processed} processed`);
  log(`ontology: ${ontologyItems.length} items`);
  log(`conflicts: ${conflicts}`);
  log(`dry-run: ${DRY_RUN}`);

  if (DRY_RUN) {
    console.log(`\n--- DRY-RUN SUMMARY (${TODAY}) ---`);
    console.log(`Inbox items found: ${inboxItems.length}`);
    inboxItems.forEach(f => console.log(`  - ${basename(f)}`));
    console.log(`Would extract ontology from Seabed (${TODAY})`);
    console.log(`Would write: logs/${TODAY}-batch.json`);
    console.log(`Would write: logs/${TODAY}-ontology.json`);
    console.log(`Would update: batch-state.json`);
    console.log(`Would write relay: ~/.claude-bots/relay/{ts}-keeper-daily.json`);
    console.log("--- END DRY-RUN ---\n");
  }
}

main().catch((err) => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});

#!/usr/bin/env bun
// keeper-batch.ts — Keeper Agent Phase 1 nightly batch
// Triggered: OS crontab 0 23 * * * (23:00 CST = 15:00 UTC)

import Anthropic from "@anthropic-ai/sdk";
import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, basename, dirname, extname } from "node:path";
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
// analysis model for classification/extraction tasks (cheaper than strategic)
let _analysisModel = "claude-sonnet-4-6";

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
    const analysisAlias = parsed.routes["analysis"] ?? "claude-sonnet";
    _analysisModel = parsed.models[analysisAlias] ?? analysisAlias;
    log(`model-router: strategic=${_strategicModel}, analysis=${_analysisModel}`);
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

interface PatternCandidate {
  key: string;
  description: string;
  category: "PATTERN" | "DECISION" | "QUESTION";
  count: number;       // consecutive batch occurrences
  first_seen: string;  // ISO date
  last_seen: string;   // ISO date
  promoted: boolean;   // already written to diana-memory.md
}

function validateOntologyItem(item: unknown): item is OntologyItem {
  if (!item || typeof item !== "object") return false;
  const o = item as Record<string, unknown>;
  if (typeof o.tag !== "string") return false;
  if (!(ONTOLOGY_TAGS as readonly string[]).includes(o.tag)) return false;
  if (typeof o.text !== "string" || o.text.length === 0) return false;
  // source_slug and ts may be missing — coerce to string
  if (!o.source_slug) o.source_slug = "unknown";
  if (!o.ts) o.ts = "";
  return true;
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
  return callLLM(_strategicModel, systemPrompt, userContent, 2048);
}

async function callSonnet(systemPrompt: string, userContent: string): Promise<string> {
  return callLLM(_analysisModel, systemPrompt, userContent, 2048);
}

async function callHaiku(systemPrompt: string, userContent: string): Promise<string> {
  return callLLM("claude-haiku-4-5-20251001", systemPrompt, userContent, 1024);
}

async function callLLM(model: string, systemPrompt: string, userContent: string, maxTokens: number): Promise<string> {
  const apiKey = loadApiKey();
  if (!apiKey) { log("WARN: no ANTHROPIC_API_KEY"); return ""; }
  const client = new Anthropic({ apiKey });
  const msg = await client.messages.create({
    model,
    max_tokens: maxTokens,
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

// ── B1: Processed slug tracking ───────────────────────────────────────────────

async function loadProcessedSlugs(agentHome: string): Promise<Set<string>> {
  const p = join(agentHome, "memory", "processed-slugs.json");
  try {
    return new Set(JSON.parse(await readFile(p, "utf8")) as string[]);
  } catch {
    return new Set();
  }
}

async function saveProcessedSlugs(agentHome: string, slugs: Set<string>): Promise<void> {
  const p = join(agentHome, "memory", "processed-slugs.json");
  const arr = [...slugs].slice(-2000); // keep last 2000
  await safeWrite(p, JSON.stringify(arr, null, 2) + "\n");
}

// B1: parse chats.clsc.md directly — returns slug + inline content
function getRecentUnprocessedRecords(
  seabedPath: string,
  pastDays: number,
  processedSlugs: Set<string>
): Array<{ slug: string; content: string }> {
  const validDates = new Set<string>();
  for (let i = 0; i < pastDays; i++) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    validDates.add(d.toISOString().slice(0, 10).replace(/-/g, ""));
  }

  let raw: string;
  try {
    raw = require("fs").readFileSync(seabedPath, "utf8") as string;
  } catch {
    return [];
  }

  const seen = new Map<string, string>();
  for (const line of raw.split("\n")) {
    // CLSC format: [slug|tags|categories|"content excerpt"|score|sentiment|source]
    const m = line.match(/^\[([^|\]]+)\|[^|]*\|[^|]*\|"([^"]*)"/);
    if (!m) continue;
    const slug = m[1];
    const excerpt = m[2];
    const dateM = slug.match(/^(?:tg|msg)-(\d{8})/);
    if (!dateM || !validDates.has(dateM[1])) continue;
    if (processedSlugs.has(slug)) continue;
    seen.set(slug, excerpt);
  }
  return [...seen.entries()].map(([slug, content]) => ({ slug, content }));
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
  seabedPath: string,
  processedSlugs: Set<string>,
  actions: BatchAction[]
): Promise<{ items: OntologyItem[]; newSlugs: string[] }> {
  log("Step 2: extracting interaction ontology (past 7 days, unprocessed)...");

  const allRecords = getRecentUnprocessedRecords(seabedPath, 7, processedSlugs);

  if (DRY_RUN) {
    log(`DRY-RUN Step 2a: found ${allRecords.length} unprocessed records in past 7 days`);
    log(`DRY-RUN Step 2b: would call claude-opus to extract ontology tags`);
    log(`DRY-RUN Step 2c: would write logs/${TODAY}-ontology.json`);
    actions.push({ action: "ontology_extract", result: "dry-run", detail: "skipped in dry-run" });
    return { items: [], newSlugs: [] };
  }

  log(`Step 2a: found ${allRecords.length} unprocessed seabed records (past 7 days)`);

  if (allRecords.length === 0) {
    log("Step 2: no new seabed records in past 7 days, skipping");
    actions.push({ action: "ontology_extract", result: "skip", detail: "no new records" });
    return { items: [], newSlugs: [] };
  }

  // Process up to 10 records per batch to control cost
  const records = allRecords.slice(0, 10);

  if (records.length === 0) {
    log("Step 2: no content available");
    actions.push({ action: "ontology_extract", result: "skip", detail: "no content" });
    return { items: [], newSlugs: [] };
  }

  const userContent = records.map(r => `--- ${r.slug} ---\n${r.content}`).join("\n\n");

  let items: OntologyItem[] = [];
  try {
    const raw = await callSonnet(ONTOLOGY_SYSTEM, userContent);
    const parsed = JSON.parse(raw.trim().replace(/^```json\n?/, "").replace(/\n?```$/, ""));
    items = Array.isArray(parsed) ? parsed.filter(validateOntologyItem) : [];
    const rawCount = Array.isArray(parsed) ? parsed.length : 0;
    if (rawCount !== items.length) log(`Step 2b: filtered ${rawCount - items.length} invalid items`);
    log(`Step 2b: extracted ${items.length} valid ontology items from ${records.length} records`);
  } catch (err) {
    log(`Step 2b: parse error: ${String(err)}`);
    actions.push({ action: "ontology_extract", result: "error", detail: String(err) });
    return { items: [], newSlugs: records.map(r => r.slug) };
  }

  actions.push({ action: "ontology_extract", result: "ok", detail: `${items.length} items from ${records.length} records` });
  return { items, newSlugs: records.map(r => r.slug) };
}

// ── B2: Route ontology items to Ocean vault ───────────────────────────────────

const ONTOLOGY_ROUTES: Partial<Record<OntologyTag, string>> = {
  commitment:     "珍珠卡/承諾追蹤.md",
  action_item:    "珍珠卡/承諾追蹤.md",
  open_question:  "企劃/開放問題.md",
  decision:       "技術海圖/決策記錄.md",
  assumption:     "_drafts/假設與風險.md",
  risk:           "_drafts/假設與風險.md",
};

const ROUTE_HEADERS: Record<string, string> = {
  "珍珠卡/承諾追蹤.md":   "# 承諾追蹤",
  "企劃/開放問題.md":     "# 開放問題",
  "技術海圖/決策記錄.md": "# 決策記錄",
  "_drafts/假設與風險.md": "# 假設與風險",
};

async function routeOntologyItems(
  items: OntologyItem[],
  vaultDir: string,
  actions: BatchAction[]
): Promise<void> {
  if (items.length === 0) return;

  const byFile = new Map<string, OntologyItem[]>();
  for (const item of items) {
    const relPath = ONTOLOGY_ROUTES[item.tag];
    if (!relPath) continue;
    if (!byFile.has(relPath)) byFile.set(relPath, []);
    byFile.get(relPath)!.push(item);
  }

  for (const [relPath, fileItems] of byFile) {
    const destPath = join(vaultDir, relPath);
    let existing = "";
    try {
      existing = await readFile(destPath, "utf8");
    } catch {
      existing = ROUTE_HEADERS[relPath] + "\n";
    }

    const section =
      `\n## ${TODAY}\n` +
      fileItems.map(i => `- **[${i.tag}]** ${i.text}（來源：\`${i.source_slug}\`）`).join("\n") +
      "\n";

    await safeWrite(destPath, existing + section);
    actions.push({ action: "ontology_route", path: destPath, result: "written", detail: `${fileItems.length} items → ${relPath}` });
  }

  log(`Step 8: routed ${items.length} ontology items → ${byFile.size} Ocean file(s)`);
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
        const raw = await callSonnet(CLASSIFY_SYSTEM, `Item path: ${basename(itemPath)}\n\nContent:\n${snippet}`);
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

// ── Step 9: Vault audit — auto-link orphaned nodes ────────────────────────────

// Directories to skip during .md audit
const AUDIT_SKIP_DIRS = new Set([".stversions", ".obsidian", "封存深淵", "原檔海床"]);

// Process order: most important directories first
const AUDIT_PRIORITY_DIRS = [
  "業務流", "技術海圖", "珍珠卡", "調研指南", "聊天記錄",
  "Currents", "Seabed", "Reports", "Chart", "Research", "_drafts",
];

const AUDIT_BATCH_SIZE = 20;

// Ocean vault 目錄語義說明，注入 prompt 讓 Haiku 能做出符合分類體系的推薦
const OCEAN_DIR_MAP = `Ocean vault 目錄語義：
- 珍珠卡/ → 萃取的洞見、Pearl cards、重要概念提煉
- 技術海圖/ → 系統架構、技術決策、基礎建設文件
- 業務流/ → 業務流程、GitHub 代碼文檔、專案執行記錄
- 調研指南/ → 市場研究、競品分析、外部資料
- 聊天記錄/ → Telegram 業務對話記錄，應連接對話中提及的業務節點（項目名、人名、工具名等）
- Currents/ → 流動中的想法、進行中草稿
- Seabed/ → 沉澱的底層知識、永久參考
- Reports/ → 正式報告、分析輸出
- 企劃/ → 企劃案、產品規劃
- _drafts/ → 草稿暫存`;

const AUDIT_SYSTEM = `你是 Obsidian 知識庫整理助手，負責讓孤立筆記連入知識圖譜。

${OCEAN_DIR_MAP}

給你一批筆記，每筆包含：FILE（相對路徑）、摘要、可用節點清單。
請為每個筆記選出 2-4 個最相關的 wikilink。

⚠️ 嚴格規則：只能從「可用節點清單」中選擇，禁止發明清單以外的節點名稱。若清單中無合適節點，選最接近的即可，不要補充任何清單外的名稱。

輸出格式：每個筆記一行，格式嚴格如下（TAB 分隔）：
<FILE路徑>\t[[連結A]]\t[[連結B]]\t[[連結C]]

只輸出這些行，不要任何說明。`;

// Build index of valid hub-node filenames from key vault directories.
// These are guaranteed to exist — Haiku may ONLY pick from this list.
function buildHubNodeIndex(vaultDir: string): string[] {
  const hubDirs = ["珍珠卡", "技術海圖", "業務流", "企劃", "Reports"];
  const nodes: string[] = [];
  for (const dir of hubDirs) {
    const res = spawnSync("find", [
      join(vaultDir, dir), "-maxdepth", "3", "-name", "*.md",
      "-not", "-path", "*/.stversions/*",
      "-not", "-path", "*/.obsidian/*",
    ], { encoding: "utf8", timeout: 15000 });
    for (const fp of (res.stdout ?? "").split("\n").filter(Boolean)) {
      nodes.push(basename(fp, ".md"));
    }
  }
  return [...new Set(nodes)].sort();
}

async function loadAuditedNodes(agentHome: string): Promise<Set<string>> {
  const p = join(agentHome, "memory", "audited-nodes.json");
  try {
    return new Set(JSON.parse(await readFile(p, "utf8")) as string[]);
  } catch {
    return new Set();
  }
}

async function saveAuditedNodes(agentHome: string, nodes: Set<string>): Promise<void> {
  const p = join(agentHome, "memory", "audited-nodes.json");
  await safeWrite(p, JSON.stringify([...nodes], null, 2) + "\n");
}

function findOrphanedFiles(vaultDir: string, auditedNodes: Set<string>): string[] {
  // Find ALL .md files not yet correctly audited (includes files with broken-only links)
  const result = spawnSync("find", [
    vaultDir, "-name", "*.md",
    "-not", "-path", "*/.stversions/*",
    "-not", "-path", "*/.obsidian/*",
  ], { encoding: "utf8", timeout: 30000 });

  if (result.error || !result.stdout) return [];

  return result.stdout.split("\n")
    .filter(Boolean)
    .filter(fp => {
      const relPath = fp.replace(vaultDir + "/", "");
      const topDir = relPath.split("/")[0];
      if (AUDIT_SKIP_DIRS.has(topDir)) return false;
      return !auditedNodes.has(relPath);
    });
}

function sortByAuditPriority(files: string[], vaultDir: string): string[] {
  const pri: Record<string, number> = {};
  AUDIT_PRIORITY_DIRS.forEach((d, i) => { pri[d] = i; });
  return [...files].sort((a, b) => {
    const dA = a.replace(vaultDir + "/", "").split("/")[0];
    const dB = b.replace(vaultDir + "/", "").split("/")[0];
    return (pri[dA] ?? 99) - (pri[dB] ?? 99);
  });
}

async function vaultAudit(
  vaultDir: string,
  agentHome: string,
  actions: BatchAction[]
): Promise<number> { // returns remaining orphan count after this batch
  log("Step 9: vault audit — finding orphaned nodes...");

  if (DRY_RUN) {
    const auditedNodes = await loadAuditedNodes(agentHome);
    const orphans = findOrphanedFiles(vaultDir, auditedNodes);
    log(`DRY-RUN Step 9: would audit ${Math.min(AUDIT_BATCH_SIZE, orphans.length)} of ${orphans.length} orphaned files`);
    actions.push({ action: "vault_audit", result: "dry-run", detail: `${orphans.length} orphans total` });
    return 0;
  }

  const auditedNodes = await loadAuditedNodes(agentHome);
  const orphans = sortByAuditPriority(findOrphanedFiles(vaultDir, auditedNodes), vaultDir);
  log(`Step 9a: ${orphans.length} unaudited orphans — processing ${Math.min(AUDIT_BATCH_SIZE, orphans.length)}`);

  if (orphans.length === 0) {
    log("Step 9: vault is clean — no orphans remaining!");
    actions.push({ action: "vault_audit", result: "done", detail: "no orphans" });
    return 0;
  }

  const batch = orphans.slice(0, AUDIT_BATCH_SIZE);

  // Build valid hub node index once per batch — Haiku may ONLY pick from these
  const hubNodes = buildHubNodeIndex(vaultDir);
  const hubList = hubNodes.join(" | ");

  // Build input: sanitize snippets
  const inputBlocks = batch.map(fp => {
    const relPath = fp.replace(vaultDir + "/", "");
    let raw = "";
    try {
      raw = require("fs").readFileSync(fp, "utf8") as string;
    } catch {}

    // Sanitize: collapse whitespace, strip non-printable chars → prevents JSON unterminated string
    const snippet = raw.slice(0, 300).replace(/\s+/g, " ").replace(/[^\x20-\x7E一-鿿　-〿＀-￯]/g, "").trim();

    return `=== ${relPath} ===\n摘要：${snippet}\n可用節點清單：${hubList}`;
  });

  let results: Array<{ file: string; links: string[] }> = [];
  try {
    const raw = await callHaiku(AUDIT_SYSTEM, inputBlocks.join("\n\n"));
    // Parse tab-delimited lines: <file>\t[[A]]\t[[B]]...
    for (const line of raw.split("\n")) {
      const parts = line.trim().split("\t").filter(Boolean);
      if (parts.length < 2) continue;
      const file = parts[0].trim();
      const links = parts.slice(1).map(l => l.trim()).filter(l => l.startsWith("[["));
      if (file && links.length > 0) results.push({ file, links });
    }
    log(`Step 9b: Haiku returned links for ${results.length}/${batch.length} files`);
  } catch (err) {
    log(`Step 9b: Haiku error: ${String(err)}`);
    actions.push({ action: "vault_audit", result: "error", detail: String(err) });
  }

  // Apply wikilinks + mark audited
  let patched = 0;
  for (const r of results) {
    const filePath = join(vaultDir, r.file);
    const links = r.links.slice(0, 5).join(" ");
    try {
      let content = require("fs").readFileSync(filePath, "utf8") as string;
      content = content.trimEnd() + `\n\n${links}\n`;
      await writeFile(filePath, content, "utf8");
      log(`Step 9c: patched ${r.file}`);
      actions.push({ action: "vault_audit", path: filePath, result: "patched", detail: links });
      patched++;
    } catch (err) {
      log(`Step 9c: failed ${r.file}: ${String(err)}`);
    }
  }

  // Mark as audited: files Haiku processed + files too short to link (< 80 chars)
  const resultFiles = new Set(results.map(r => r.file));
  for (const fp of batch) {
    const relPath = fp.replace(vaultDir + "/", "");
    if (resultFiles.has(relPath)) {
      auditedNodes.add(relPath);
    } else {
      try {
        const size = require("fs").statSync(fp).size;
        if (size < 80) auditedNodes.add(relPath); // too short to meaningfully link
      } catch {}
    }
  }
  await saveAuditedNodes(agentHome, auditedNodes);
  const remaining = Math.max(0, orphans.length - batch.length);
  log(`Step 9: patched ${patched}/${batch.length} files — ${remaining} orphans remaining`);
  actions.push({ action: "vault_audit", result: "ok", detail: `patched ${patched}/${batch.length}, ${remaining} left` });
  return remaining;
}

// ── P0-1: Threshold-based long-term memory promotion ─────────────────────────
// Only write to diana-memory.md when a signal persists for PATTERN_THRESHOLD
// consecutive batches. Daily observations go to batch logs, not here.

const PATTERN_THRESHOLD = 3;

async function appendLongTermMemory(
  agentHome: string,
  batchNum: number,
  processed: number,
  ontologyCount: number,
  conflicts: number,
  auditPatched: number
): Promise<void> {
  const candidatesPath = join(agentHome, "memory", "pattern-candidates.json");
  const memPath = join(agentHome, "memory", "diana-memory.md");

  let candidates: PatternCandidate[] = [];
  try {
    candidates = JSON.parse(await readFile(candidatesPath, "utf8"));
  } catch { }

  // Evaluate which signals are active this batch
  const activeKeys = new Set<string>();
  const signals: Array<{ key: string; description: string; category: PatternCandidate["category"] }> = [];

  if (processed === 0) {
    activeKeys.add("inbox_always_empty");
    signals.push({
      key: "inbox_always_empty",
      description: "Inbox 持續為空：上游 feed 為 cron 排程而非即時用戶觸發，空批次是正常狀態不是錯誤",
      category: "PATTERN",
    });
  }

  if (ontologyCount === 0) {
    activeKeys.add("ontology_zero");
    signals.push({
      key: "ontology_zero",
      description: "Ontology 連續提取為零：seabed 對話密度不足以提取結構性資訊，非異常",
      category: "PATTERN",
    });
  }

  if (auditPatched > 0) {
    activeKeys.add("vault_audit_active");
    signals.push({
      key: "vault_audit_active",
      description: `Vault 孤兒補連進行中：每批次平均補 ${auditPatched} 個節點，為多批次持續工作`,
      category: "PATTERN",
    });
  }

  if (conflicts === 0) {
    activeKeys.add("no_git_conflicts");
    signals.push({
      key: "no_git_conflicts",
      description: "Git 衝突率為零：vault 目前為單人編輯環境，衝突偵測為預防機制非常態需求",
      category: "PATTERN",
    });
  }

  // Update candidate counts
  for (const sig of signals) {
    const existing = candidates.find(c => c.key === sig.key);
    if (existing) {
      existing.count++;
      existing.last_seen = TODAY;
    } else {
      candidates.push({
        key: sig.key,
        description: sig.description,
        category: sig.category,
        count: 1,
        first_seen: TODAY,
        last_seen: TODAY,
        promoted: false,
      });
    }
  }

  // Reset count for signals absent this batch (they reset if they stop being true)
  for (const c of candidates) {
    if (!activeKeys.has(c.key) && !c.promoted) {
      if (c.count > 0) log(`Step 7b: candidate "${c.key}" broke streak (was ${c.count}), resetting`);
      c.count = 0;
    }
  }

  // Promote candidates that crossed the threshold
  const toPromote = candidates.filter(c => c.count >= PATTERN_THRESHOLD && !c.promoted);

  if (toPromote.length === 0) {
    const pending = candidates.filter(c => !c.promoted && c.count > 0);
    log(`Step 7b: no promotions this batch (${pending.length} candidates: ${pending.map(c => `${c.key}=${c.count}`).join(", ")})`);
    await safeWrite(candidatesPath, JSON.stringify(candidates, null, 2) + "\n");
    return;
  }

  let content = await readFile(memPath, "utf8").catch(() => "");

  for (const candidate of toPromote) {
    const entry = `\n### ${TODAY}\n- ${candidate.description}（首次觀察 ${candidate.first_seen}，連續 ${candidate.count} 批次確認）\n`;
    const sectionHeader = candidate.category === "PATTERN" ? "## 發現的 Pattern"
      : candidate.category === "DECISION" ? "## 歷史決策"
      : "## 開放問題";

    const sIdx = content.indexOf(sectionHeader);
    if (sIdx === -1) {
      content += `\n${sectionHeader}${entry}`;
    } else {
      const afterHeader = sIdx + sectionHeader.length;
      let nextSection = content.indexOf("\n## ", afterHeader);
      if (nextSection === -1) nextSection = content.length;
      const sectionContent = content.slice(afterHeader, nextSection).replace(/\n（空，等批次後逐步填入）/g, "");
      content = content.slice(0, afterHeader) + sectionContent + entry + content.slice(nextSection);
    }

    candidate.promoted = true;
    log(`Step 7b: promoted [${candidate.category}] ${candidate.key} → diana-memory.md`);
  }

  await safeWrite(memPath, content);
  await safeWrite(candidatesPath, JSON.stringify(candidates, null, 2) + "\n");
  log(`Step 7b: ${toPromote.length} pattern(s) promoted to long-term memory`);
}

// ── Step 12: Link non-md assets into knowledge graph ─────────────────────────
// For each directory that has unreferenced .py/.ts/.png etc. files,
// find the nearest .md file and append [[filename.ext]] wikilinks.

const NON_MD_ASSET_EXTS = new Set([".py", ".ts", ".js", ".tsx", ".mjs", ".sh", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".psd", ".ai", ".yml", ".yaml", ".css", ".sql", ".csv", ".pyc", ".gz", ".zip", ".jsonl", ".jinja", ".service", ".bak", ".cisc", ".clsc", ".pdf", ".woff", ".woff2", ".lock", ".ico", ".template"]);
const NON_MD_SKIP_DIRS = new Set([".stversions", ".obsidian", ".trash", "_graphify"]);
const NON_MD_BATCH_DIRS = 10; // directories per batch

async function linkNonMdAssets(vaultDir: string, agentHome: string, actions: BatchAction[]): Promise<number> {
  log("Step 12: scanning for non-md asset orphans...");
  if (DRY_RUN) {
    log("DRY-RUN Step 12: would scan for non-md orphans");
    return 0;
  }

  // Load already-linked assets from state file
  const linkedPath = join(agentHome, "memory", "linked-assets.json");
  let linkedAssets: Set<string>;
  try {
    linkedAssets = new Set(JSON.parse(await readFile(linkedPath, "utf8")) as string[]);
  } catch {
    linkedAssets = new Set();
  }

  // Collect all referenced filenames from .md wikilinks
  const grepRef = spawnSync("grep", [
    "-roh", "\\[\\[[^\\]]*\\]\\]", "--include=*.md",
    "--exclude-dir=.stversions", "--exclude-dir=.obsidian", vaultDir,
  ], { encoding: "utf8", timeout: 30000 });
  const referenced = new Set<string>();
  if (grepRef.stdout) {
    for (const link of grepRef.stdout.split("\n")) {
      const name = link.trim().replace(/^\[\[/, "").replace(/\]\]$/, "").trim();
      referenced.add(name);
      referenced.add(name.split("/").pop() ?? name);
    }
  }

  // Find non-md files grouped by directory
  const dirMap = new Map<string, string[]>(); // relDir → [filename, ...]
  const walkResult = spawnSync("find", [
    vaultDir, "-type", "f",
    "-not", "-path", "*/.stversions/*",
    "-not", "-path", "*/.obsidian/*",
    "-not", "-path", "*/.trash/*",
    "-not", "-path", "*/_graphify/*",
  ], { encoding: "utf8", timeout: 30000 });

  for (const fp of (walkResult.stdout ?? "").split("\n").filter(Boolean)) {
    const ext = fp.slice(fp.lastIndexOf(".")).toLowerCase();
    if (!NON_MD_ASSET_EXTS.has(ext)) continue;
    const relFp = fp.replace(vaultDir + "/", "");
    const topDir = relFp.split("/")[0];
    if (NON_MD_SKIP_DIRS.has(topDir)) continue;
    if (linkedAssets.has(relFp)) continue;
    const fname = relFp.split("/").pop() ?? relFp;
    if (referenced.has(fname) || referenced.has(relFp)) { linkedAssets.add(relFp); continue; }

    const relDir = relFp.includes("/") ? relFp.slice(0, relFp.lastIndexOf("/")) : ".";
    if (!dirMap.has(relDir)) dirMap.set(relDir, []);
    dirMap.get(relDir)!.push(fname);
  }

  const dirs = [...dirMap.keys()].slice(0, NON_MD_BATCH_DIRS);
  log(`Step 12: ${dirMap.size} dirs with unlinked assets — processing ${dirs.length}`);
  if (dirs.length === 0) {
    actions.push({ action: "link_assets", result: "done", detail: "no unlinked assets" });
    await writeFile(linkedPath, JSON.stringify([...linkedAssets], null, 2) + "\n", "utf8");
    return 0;
  }

  let patched = 0;
  for (const relDir of dirs) {
    const absDir = relDir === "." ? vaultDir : join(vaultDir, relDir);
    const assets = dirMap.get(relDir)!;

    // Smart target selection:
    // Priority 1 — same dir: README > same-name .md > spec/index > any .md
    // Priority 2 — walk up toward vault root (fallback)
    let targetMd = "";
    const sameDirResult = spawnSync("find", [absDir, "-maxdepth", "1", "-name", "*.md"], { encoding: "utf8", timeout: 10000 });
    const sameDirMds = (sameDirResult.stdout ?? "").split("\n").filter(Boolean);
    if (sameDirMds.length > 0) {
      const readme = sameDirMds.find(f => /^readme$/i.test(basename(f, ".md")));
      const sameName = sameDirMds.find(f =>
        assets.some(a => basename(f, ".md").toLowerCase() === basename(a, extname(a)).toLowerCase())
      );
      const specIdx = sameDirMds.find(f => /^(spec|index|overview|概覽|主)/i.test(basename(f)));
      targetMd = readme ?? sameName ?? specIdx ?? sameDirMds[0];
    }
    if (!targetMd) {
      let searchDir = dirname(absDir);
      for (let i = 0; i < 6; i++) {
        if (!searchDir.startsWith(vaultDir) || searchDir === vaultDir) break;
        const mdResult = spawnSync("find", [searchDir, "-maxdepth", "1", "-name", "*.md"], { encoding: "utf8", timeout: 10000 });
        const mds = (mdResult.stdout ?? "").split("\n").filter(Boolean);
        if (mds.length > 0) {
          targetMd = mds.find(f => /README|index|主/i.test(basename(f))) ?? mds[0];
          break;
        }
        searchDir = dirname(searchDir);
      }
    }
    if (!targetMd) continue;
    const wikilinks = assets.slice(0, 10).map(f => `[[${f}]]`).join(" ");

    try {
      let content = require("fs").readFileSync(targetMd, "utf8") as string;
      content = content.trimEnd() + `\n\n${wikilinks}\n`;
      await writeFile(targetMd, content, "utf8");
      log(`Step 12: linked ${assets.length} assets into ${targetMd.replace(vaultDir + "/", "")}`);
      actions.push({ action: "link_assets", path: targetMd, result: "patched", detail: `${assets.length} assets` });
      patched++;
      // Mark assets as linked
      for (const fname of assets) {
        const relFp = relDir === "." ? fname : `${relDir}/${fname}`;
        linkedAssets.add(relFp);
      }
    } catch (err) {
      log(`Step 12: failed ${relDir}: ${String(err)}`);
    }
  }

  await writeFile(linkedPath, JSON.stringify([...linkedAssets], null, 2) + "\n", "utf8");
  const remaining = Math.max(0, dirMap.size - dirs.length);
  log(`Step 12: patched ${patched}/${dirs.length} dirs — ${remaining} dirs remaining`);
  actions.push({ action: "link_assets", result: "ok", detail: `${patched} dirs patched, ${remaining} left` });
  return remaining;
}

// ── Step 13: Clean Syncthing conflict files ───────────────────────────────────

async function cleanSyncConflicts(vaultDir: string, actions: BatchAction[]): Promise<void> {
  if (DRY_RUN) { log("DRY-RUN Step 13: would clean sync-conflict files"); return; }

  const result = spawnSync("find", [
    vaultDir, "-type", "f",
    "-name", "*.sync-conflict-*.md",
    "-not", "-path", "*/.stversions/*",
  ], { encoding: "utf8", timeout: 30000 });

  const files = (result.stdout ?? "").split("\n").filter(Boolean);
  let deleted = 0;
  if (files.length === 0) {
    log("Step 13: no sync-conflict files found");
  } else {
    log(`Step 13: deleting ${files.length} sync-conflict files...`);
  }
  for (const fp of files) {
    try {
      require("fs").unlinkSync(fp);
      deleted++;
    } catch (err) {
      log(`Step 13: failed to delete ${fp}: ${String(err)}`);
    }
  }
  log(`Step 13: deleted ${deleted}/${files.length} sync-conflict files`);

  // Also clean Obsidian-generated duplicate files: "filename 2.md", "filename 3.md" etc.
  // Note: -regextype must come before all predicates in GNU find
  const dupResult = spawnSync("find", [
    vaultDir, "-regextype", "posix-extended",
    "-type", "f",
    "-regex", ".*\\ [0-9]+\\.md$",
    "-not", "-path", "*/.stversions/*",
    "-not", "-path", "*/.obsidian/*",
  ], { encoding: "utf8", timeout: 30000 });

  const dupFiles = (dupResult.stdout ?? "").split("\n").filter(Boolean);
  let dupDeleted = 0;
  if (dupFiles.length > 0) {
    log(`Step 13: deleting ${dupFiles.length} Obsidian duplicate files...`);
    for (const fp of dupFiles) {
      try {
        require("fs").unlinkSync(fp);
        dupDeleted++;
      } catch (err) {
        log(`Step 13: failed to delete dup ${fp}: ${String(err)}`);
      }
    }
    log(`Step 13: deleted ${dupDeleted}/${dupFiles.length} Obsidian duplicate files`);
  }

  actions.push({ action: "clean_conflicts", result: "ok", detail: `${deleted} sync-conflicts + ${dupDeleted} obsidian-dups deleted` });
}


// ── Step 14: Contradiction scan (weekly, Sunday only) ────────────────────────

const TEST_CONTRADICTION = process.argv.includes("--test-contradiction");

async function contradictionScan(
  vaultDir: string,
  agentHome: string,
  actions: BatchAction[]
): Promise<void> {
  log("Step 14: contradiction scan...");

  // Weekly gate: Sunday only
  if (!TEST_CONTRADICTION && new Date().getDay() !== 0) {
    log("Step 14: not Sunday, skipping contradiction scan");
    return;
  }

  if (DRY_RUN && !TEST_CONTRADICTION) {
    log("DRY-RUN Step 14: would scan radar_vec for contradictions");
    return;
  }

  interface PairCandidate {
    slug_a: string;
    slug_b: string;
    distance: number;
    clsc_a: string;
    clsc_b: string;
  }

  let pairs: PairCandidate[] = [];

  if (TEST_CONTRADICTION) {
    // Test mode: mock 3 pairs
    log("Step 14: TEST MODE — using mock pairs");
    pairs = [
      { slug_a: "test-a", slug_b: "test-b", distance: 0.1, clsc_a: "Policy X should be done first", clsc_b: "Policy Y should be done before X" },
      { slug_a: "test-c", slug_b: "test-d", distance: 0.15, clsc_a: "Water is wet", clsc_b: "Water is a liquid" },
      { slug_a: "test-e", slug_b: "test-f", distance: 0.2, clsc_a: "AI is safe", clsc_b: "AI is perfectly safe" },
    ];
  } else {
    // Query radar_vec for high-similarity pairs via Python
    const memoceanPath = join(agentHome, "../../shared/memocean-mcp");
    const pyScript = `
import sys, json, random, os
memocean_path = sys.argv[1]
sys.path.insert(0, memocean_path)

try:
    from memocean_mcp.config import FTS_DB
    import sqlite3
    import sqlite_vec

    THRESHOLD = 0.5477
    TOP_N = 200
    MAX_SLUGS = 300

    conn = sqlite3.connect(str(FTS_DB))
    sqlite_vec.load(conn)

    all_slugs = [r[0] for r in conn.execute("SELECT slug FROM radar_vec").fetchall()]
    if len(all_slugs) > MAX_SLUGS:
        random.shuffle(all_slugs)
        all_slugs = all_slugs[:MAX_SLUGS]

    seen_pairs = set()
    candidates = []

    for slug in all_slugs:
        row = conn.execute("SELECT embedding FROM radar_vec WHERE slug = ?", (slug,)).fetchone()
        if not row:
            continue
        emb_blob = row[0]
        rows = conn.execute(
            "SELECT slug, distance FROM radar_vec WHERE embedding MATCH ? AND k = 10",
            (emb_blob,)
        ).fetchall()
        for neighbor_slug, dist in rows:
            if neighbor_slug == slug or dist > THRESHOLD:
                continue
            pair = tuple(sorted([slug, neighbor_slug]))
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            candidates.append({"slug_a": pair[0], "slug_b": pair[1], "distance": float(dist)})

    candidates.sort(key=lambda x: x["distance"])
    result = []
    for c in candidates[:TOP_N]:
        ra = conn.execute("SELECT clsc FROM radar WHERE slug = ?", (c["slug_a"],)).fetchone()
        rb = conn.execute("SELECT clsc FROM radar WHERE slug = ?", (c["slug_b"],)).fetchone()
        if ra and rb:
            result.append({**c, "clsc_a": ra[0], "clsc_b": rb[0]})

    conn.close()
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({"error": str(e)}))
`;

    const result = spawnSync("python3", ["-", memoceanPath], {
      input: pyScript,
      encoding: "utf8",
      timeout: 120000,
    });

    if (result.error || result.status !== 0) {
      log(`WARN Step 14: python script failed: ${result.stderr}`);
      actions.push({ action: "contradiction_scan", result: "error", detail: result.stderr ?? "spawn error" });
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(result.stdout.trim());
    } catch (err) {
      log(`WARN Step 14: JSON parse error: ${String(err)}`);
      actions.push({ action: "contradiction_scan", result: "error", detail: String(err) });
      return;
    }

    if (parsed && typeof parsed === "object" && "error" in (parsed as Record<string, unknown>)) {
      log(`WARN Step 14: radar_vec query error: ${(parsed as { error: string }).error}`);
      actions.push({ action: "contradiction_scan", result: "error", detail: (parsed as { error: string }).error });
      return;
    }

    if (!Array.isArray(parsed)) {
      log("WARN Step 14: unexpected result shape");
      actions.push({ action: "contradiction_scan", result: "error", detail: "unexpected result shape" });
      return;
    }

    pairs = parsed as PairCandidate[];
    log(`Step 14a: ${pairs.length} candidate pairs from radar_vec`);
  }

  // For each pair, call Haiku to classify conflict
  const CONFLICT_SYSTEM = `You are a knowledge consistency checker.
Given two CLSC (compact knowledge) entries, determine if they contradict each other.
Respond ONLY with JSON: {"conflict": boolean, "reason": string}`;

  interface ConflictEntry {
    slug_a: string;
    slug_b: string;
    reason: string;
    flagged_at: string;
  }

  const newConflicts: ConflictEntry[] = [];
  let inboxDir: string;

  if (TEST_CONTRADICTION) {
    // Use a temp dir for test output
    const tmpDir = `/tmp/keeper-contradiction-test-${Date.now()}`;
    inboxDir = join(tmpDir, "anya", "inbox", "messages");
    log(`Step 14: TEST MODE writing to temp dir: ${tmpDir}`);
  } else {
    inboxDir = join(agentHome, "../../bots/anya/inbox/messages");
  }

  for (const pair of pairs) {
    const userContent = `Entry A (${pair.slug_a}):
<clsc-entry>${pair.clsc_a}</clsc-entry>

Entry B (${pair.slug_b}):
<clsc-entry>${pair.clsc_b}</clsc-entry>`;
    let raw = "";
    try {
      raw = await callHaiku(CONFLICT_SYSTEM, userContent);
    } catch (err) {
      log(`Step 14b: Haiku error for pair ${pair.slug_a}/${pair.slug_b}: ${String(err)}`);
      continue;
    }

    let classification: { conflict: boolean; reason: string } | null = null;
    try {
      // Strip markdown code fences if present
      const cleaned = raw.trim().replace(/^```[\w]*\n?/, "").replace(/\n?```$/, "");
      const parsed = JSON.parse(cleaned) as { conflict?: boolean; reason?: string };
      if (typeof parsed.conflict === "boolean" && typeof parsed.reason === "string") {
        classification = { conflict: parsed.conflict, reason: parsed.reason };
      }
    } catch {
      log(`Step 14b: parse error for ${pair.slug_a}/${pair.slug_b}: ${raw.slice(0, 100)}`);
      continue;
    }

    if (!classification || !classification.conflict) continue;

    // Write inbox item for Anya
    const hexRand = Math.floor(Math.random() * 0xFFFF).toString(16).padStart(4, "0");
    const dateStr = TODAY.replace(/-/g, "");
    const inboxFile = join(inboxDir, `conflict-${dateStr}-${hexRand}.json`);
    const inboxMsg = {
      method: "notifications/claude/channel",
      params: {
        content: `🔴 CLSC 衝突：${pair.slug_a} vs ${pair.slug_b}

${classification.reason}`,
        meta: {
          source: "keeper-contradiction-scan",
          event: "contradiction_flagged",
          slug_a: pair.slug_a,
          slug_b: pair.slug_b,
          reason: classification.reason.slice(0, 2000),
        },
      },
    };
    await safeWrite(inboxFile, JSON.stringify(inboxMsg, null, 2) + "\n");
    log(`Step 14c: flagged conflict: ${pair.slug_a} vs ${pair.slug_b}`);

    newConflicts.push({
      slug_a: pair.slug_a,
      slug_b: pair.slug_b,
      reason: classification.reason.slice(0, 2000),
      flagged_at: new Date().toISOString(),
    });
  }

  // Write/merge contradiction-flags.json
  const flagsPath = join(agentHome, "memory", "contradiction-flags.json");
  let existing: ConflictEntry[] = [];
  try {
    existing = JSON.parse(await readFile(flagsPath, "utf8").catch(() => "[]")) as ConflictEntry[];
  } catch { existing = []; }

  // Dedup by sorted slug pair
  const seen = new Set<string>(existing.map(e => [e.slug_a, e.slug_b].sort().join("|")));
  for (const c of newConflicts) {
    const key = [c.slug_a, c.slug_b].sort().join("|");
    if (!seen.has(key)) {
      seen.add(key);
      existing.push(c);
    }
  }

  if (!TEST_CONTRADICTION) {
    await safeWrite(flagsPath, JSON.stringify(existing, null, 2) + "\n");
  }

  const conflictCount = newConflicts.length;
  log(`Step 14: done — ${conflictCount} new conflicts flagged (total: ${existing.length})`);
  actions.push({ action: "contradiction_scan", result: "ok", detail: `${conflictCount} conflicts flagged` });

  // Test mode: verify exactly expected number of inbox items
  if (TEST_CONTRADICTION) {
    log(`Step 14 TEST: ${conflictCount} inbox item(s) written`);
    if (conflictCount !== 1) {
      log(`Step 14 TEST: FAIL — expected 1 conflict, got ${conflictCount}`);
      process.exit(1);
    }
    log("Step 14 TEST: PASS — exactly 1 conflict detected as expected");
  }
}

// ── P1-1: Find orphan concepts (referenced but no definition page) ─────────────

async function findOrphanConcepts(
  vaultDir: string,
  agentHome: string,
  actions: BatchAction[]
): Promise<void> {
  log("Step 10: scanning for orphan concepts...");

  if (DRY_RUN) {
    log("DRY-RUN Step 10: would scan vault for orphan concepts");
    return;
  }

  // Collect all wikilink references across the vault
  const grepResult = spawnSync("grep", [
    "-roh", "\\[\\[[^\\]]*\\]\\]",
    "--include=*.md",
    "--exclude-dir=.stversions",
    "--exclude-dir=.obsidian",
    vaultDir,
  ], { encoding: "utf8", timeout: 30000 });

  if (grepResult.error || !grepResult.stdout) {
    log("Step 10: grep failed, skipping");
    return;
  }

  const refCounts = new Map<string, number>();
  for (const match of grepResult.stdout.split("\n").filter(Boolean)) {
    const m = match.match(/\[\[([^\]|#]+)/);
    if (!m) continue;
    const concept = m[1].trim();
    refCounts.set(concept, (refCounts.get(concept) ?? 0) + 1);
  }

  // Collect all existing node names (file basenames without .md)
  const findResult = spawnSync("find", [
    vaultDir, "-name", "*.md",
    "-not", "-path", "*/.stversions/*",
    "-not", "-path", "*/.obsidian/*",
  ], { encoding: "utf8", timeout: 15000 });

  const existingNodes = new Set<string>();
  for (const fp of findResult.stdout?.split("\n").filter(Boolean) ?? []) {
    existingNodes.add(fp.split("/").pop()!.replace(/\.md$/, ""));
  }

  // Find orphan concepts: referenced ≥2 times but no definition page
  const orphans = [...refCounts.entries()]
    .filter(([concept, count]) => count >= 2 && !existingNodes.has(concept))
    .sort((a, b) => b[1] - a[1])
    .slice(0, 50)
    .map(([concept, count]) => ({ concept, ref_count: count }));

  const outPath = join(agentHome, "logs", `${TODAY}-orphan-concepts.json`);
  await safeWrite(outPath, JSON.stringify({ date: TODAY, total: orphans.length, concepts: orphans }, null, 2) + "\n");
  log(`Step 10: found ${orphans.length} orphan concepts (top: ${orphans.slice(0, 3).map(o => o.concept).join(", ")})`);
  actions.push({ action: "orphan_concepts", result: "ok", detail: `${orphans.length} concepts, written to ${outPath}` });
}

// ── P1-3: Weekly digest every 7 batches ──────────────────────────────────────

async function generateWeeklyDigest(
  agentHome: string,
  vaultDir: string,
  batchNum: number,
  actions: BatchAction[]
): Promise<void> {
  // Use real ISO week number — only generate once per calendar week
  const d = new Date();
  const startOfYear = new Date(d.getFullYear(), 0, 1);
  const weekNum = Math.ceil(((d.getTime() - startOfYear.getTime()) / 86400000 + startOfYear.getDay() + 1) / 7);
  const weekStr = `${TODAY.slice(0, 4)}-W${String(weekNum).padStart(2, "0")}`;

  // Check if digest for this ISO week already exists
  const vaultPath = join(vaultDir, "Reports", `${weekStr}-diana-digest.md`);
  if (existsSync(vaultPath)) return;

  log(`Step 11: generating weekly digest (ISO week ${weekStr}, batch #${batchNum})...`);
  if (DRY_RUN) { log("DRY-RUN Step 11: would generate weekly digest"); return; }

  // ── Layer 1: Short-term — scan this week's batch logs ──────────────────────
  const logsDir = join(agentHome, "logs");
  const weekStart = new Date(); weekStart.setDate(weekStart.getDate() - weekStart.getDay());
  let weekBatches = 0, weekPatched = 0, weekAssets = 0, weekInbox = 0, weekOntology = 0;
  try {
    const logFiles = await readdir(logsDir);
    for (const f of logFiles) {
      if (!f.endsWith("-batch.json")) continue;
      const datePart = f.slice(0, 10);
      if (new Date(datePart) < weekStart) continue;
      try {
        const bl = JSON.parse(require("fs").readFileSync(join(logsDir, f), "utf8")) as {
          inbox_scanned?: number; items_processed?: number; ontology_items?: number;
          actions?: Array<{ action: string; result: string }>;
        };
        weekBatches++;
        weekInbox += bl.items_processed ?? 0;
        weekOntology += bl.ontology_items ?? 0;
        weekPatched += (bl.actions ?? []).filter(a => a.action === "vault_audit" && a.result === "patched").length;
        weekAssets += (bl.actions ?? []).filter(a => a.action === "link_assets" && a.result === "patched").length;
      } catch {}
    }
  } catch {}

  // ── Layer 2: Mid-term — pattern candidates nearing promotion ───────────────
  interface PatternCandidateDigest { key: string; description: string; count: number; promoted: boolean; first_seen: string; }
  let candidates: PatternCandidateDigest[] = [];
  try {
    candidates = JSON.parse(require("fs").readFileSync(join(agentHome, "memory", "pattern-candidates.json"), "utf8")) as PatternCandidateDigest[];
  } catch {}
  const newThisWeek = candidates.filter(c => new Date(c.first_seen) >= weekStart && !c.promoted);
  const nearThreshold = candidates.filter(c => c.count >= 2 && !c.promoted);
  const promotedThisWeek = candidates.filter(c => c.promoted && new Date(c.first_seen) >= weekStart);

  // ── Layer 3: Long-term — new entries in diana-memory.md this week ──────────
  const mem = await readFile(join(agentHome, "memory", "diana-memory.md"), "utf8").catch(() => "");
  const weekDateStrs = Array.from({ length: 7 }, (_, i) => {
    const d = new Date(weekStart); d.setDate(d.getDate() + i);
    return d.toISOString().slice(0, 10);
  });
  const newMemoryLines = (mem.match(/^###? \d{4}-\d{2}-\d{2}[\s\S]*?(?=^###? |\Z)/gm) ?? [])
    .filter(block => weekDateStrs.some(ds => block.includes(ds)));
  const openQuestions = mem.includes("## 開放問題")
    ? mem.split("## 開放問題")[1].trim().split("\n").filter(l => l.trim() && l.trim() !== "（空，等批次後逐步填入）")
    : [];

  // ── Build digest ───────────────────────────────────────────────────────────
  const layer2Section = [
    nearThreshold.length > 0 ? `**接近晉升（count ≥ 2）：**\n${nearThreshold.map(c => `- ${c.key}（${c.count}/3）：${c.description}`).join("\n")}` : "",
    newThisWeek.length > 0 ? `**本週新信號：**\n${newThisWeek.map(c => `- ${c.key}：${c.description}`).join("\n")}` : "",
    promotedThisWeek.length > 0 ? `**本週晉升：**\n${promotedThisWeek.map(c => `- ✅ ${c.key}`).join("\n")}` : "",
  ].filter(Boolean).join("\n\n") || "（本週無新候選）";

  const layer3Section = newMemoryLines.length > 0
    ? newMemoryLines.join("\n\n").trim()
    : "（本週無新晉升）";

  const digest = `# Diana Weekly Digest — ${weekStr}

## Layer 1：本週執行摘要（批次日誌）

| 指標 | 數值 |
|---|---|
| 本週批次數 | ${weekBatches} |
| .md 補連節點 | ${weekPatched} |
| 非 .md 資產連入目錄 | ${weekAssets} |
| Inbox 處理 | ${weekInbox} |
| Ontology 提取 | ${weekOntology} |

## Layer 2：觀察累積中（Pattern Candidates）

${layer2Section}

## Layer 3：本週長期記憶新增

${layer3Section}

## 待決問題

${openQuestions.length > 0 ? openQuestions.join("\n") : "（尚無）"}

[[Diana]] [[MemOcean]] [[Weekly Digest]] [[Ocean]]
`;

  const logPath = join(agentHome, "logs", `${weekStr}-digest.md`);

  await safeWrite(logPath, digest);
  await safeWrite(vaultPath, digest);
  log(`Step 11: weekly digest written (${weekStr})`);
  actions.push({ action: "weekly_digest", result: "ok", detail: vaultPath });
}

// ── Step 7: Update state.json + diana-memory.md ───────────────────────────────

async function updateDianaState(
  agentHome: string,
  processed: number,
  ontologyCount: number,
  conflicts: number
): Promise<void> {
  const statePath = join(agentHome, "state.json");
  const now = new Date().toISOString();

  let state: Record<string, unknown> = {};
  try {
    state = JSON.parse(await readFile(statePath, "utf8"));
  } catch {}

  state.agent_name = "Diana";
  state.role = "company-agent";
  state.status = "idle";
  state.last_run = now;
  state.last_batch_summary = `inbox:${processed} ontology:${ontologyCount} conflicts:${conflicts}`;
  state.tmux_session = "diana";
  if (!state.started_at) state.started_at = now;

  await safeWrite(statePath, JSON.stringify(state, null, 2) + "\n");
}

async function updateDianaMemory(
  agentHome: string,
  processed: number,
  ontologyItems: OntologyItem[],
  conflicts: number
): Promise<void> {
  const memPath = join(agentHome, "memory", "diana-memory.md");

  let content = "";
  try {
    content = await readFile(memPath, "utf8");
  } catch {}

  const batchMatch = content.match(/批次執行次數：(\d+)/);
  const inboxMatch = content.match(/總 inbox 處理數：(\d+)/);
  const ontologyMatch = content.match(/Ontology 標記總數：(\d+)/);
  const auditMatch = content.match(/Vault 已審查節點：(\d+)/);
  const slugMatch = content.match(/已處理 Slug 總數：(\d+)/);

  const newBatch = (batchMatch ? parseInt(batchMatch[1]) : 0) + 1;
  const newInbox = (inboxMatch ? parseInt(inboxMatch[1]) : 0) + processed;
  const newOntology = (ontologyMatch ? parseInt(ontologyMatch[1]) : 0) + ontologyItems.length;

  // load actual counts from JSON files for accuracy
  const slugFile = join(agentHome, "memory", "processed-slugs.json");
  let slugTotal = slugMatch ? parseInt(slugMatch[1]) : 0;
  try {
    const slugArr = JSON.parse(require("fs").readFileSync(slugFile, "utf8")) as string[];
    slugTotal = slugArr.length;
  } catch {}

  const auditFile = join(agentHome, "memory", "audited-nodes.json");
  let auditTotal = auditMatch ? parseInt(auditMatch[1]) : 0;
  try {
    const auditArr = JSON.parse(require("fs").readFileSync(auditFile, "utf8")) as string[];
    auditTotal = auditArr.length;
  } catch {}

  content = content
    .replace(/批次執行次數：\d+/, `批次執行次數：${newBatch}`)
    .replace(/總 inbox 處理數：\d+/, `總 inbox 處理數：${newInbox}`)
    .replace(/Ontology 標記總數：\d+/, `Ontology 標記總數：${newOntology}`);

  if (content.includes("已處理 Slug 總數：")) {
    content = content.replace(/已處理 Slug 總數：\d+/, `已處理 Slug 總數：${slugTotal}`);
  } else {
    content = content.replace(/- Ontology 標記總數：\d+/, `- Ontology 標記總數：${newOntology}\n- 已處理 Slug 總數：${slugTotal}`);
  }

  if (content.includes("Vault 已審查節點：")) {
    content = content.replace(/Vault 已審查節點：\d+/, `Vault 已審查節點：${auditTotal}`);
  } else {
    content = content.replace(/- 已處理 Slug 總數：\d+/, `- 已處理 Slug 總數：${slugTotal}\n- Vault 已審查節點：${auditTotal}`);
  }

  await safeWrite(memPath, content);
  log(`Step 7: diana-memory.md updated (batch #${newBatch}, slugs ${slugTotal}, audit ${auditTotal})`);
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

  // Use date-keyed filename so same-day batches overwrite rather than accumulate
  const relayPath = join(relayDir, `${TODAY}-keeper-daily.json`);
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
  const SEABED_PATH = join(AGENT_HOME, "../../seabed/chats.clsc.md");

  await mkdir(LOGS_DIR, { recursive: true });

  const actions: BatchAction[] = [];

  const processedSlugs = await loadProcessedSlugs(AGENT_HOME);
  const inboxItems = await scanInbox(USER_INBOX_DIR);
  const { items: ontologyItems, newSlugs } = await extractOntology(AGENT_HOME, SEABED_PATH, processedSlugs, actions);
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

  await routeOntologyItems(ontologyItems, VAULT_DIR, actions);
  await cleanSyncConflicts(VAULT_DIR, actions);
  const remainingOrphans = await vaultAudit(VAULT_DIR, AGENT_HOME, actions);
  const remainingAssetDirs = await linkNonMdAssets(VAULT_DIR, AGENT_HOME, actions);
  await findOrphanConcepts(VAULT_DIR, AGENT_HOME, actions);
  await writeRelay(ontologyItems, processed, conflicts, RELAY_DIR);

  // Self-schedule next batch if md orphans or asset dirs remain
  if (!DRY_RUN && (remainingOrphans > 0 || remainingAssetDirs > 0)) {
    const reason = [
      remainingOrphans > 0 ? `${remainingOrphans} md orphans` : "",
      remainingAssetDirs > 0 ? `${remainingAssetDirs} asset dirs` : "",
    ].filter(Boolean).join(", ");
    const continuationPath = join(RELAY_DIR, `${Date.now()}-vault-continuation.json`);
    await safeWrite(continuationPath, JSON.stringify({
      from_bot: "keeper-batch",
      chat_id: "self",
      recipient: "diana",
      text: "diana:batch",
      reason: `continuation: ${reason}`,
      message_id: 0,
      ts: new Date().toISOString(),
    }, null, 2) + "\n");
    log(`Step 9/12: self-scheduled next batch (${reason})`);
  }

  // Count vault audit patches from actions
  const auditPatched = actions.filter(a => a.action === "vault_audit" && a.result === "patched").length;

  if (!DRY_RUN) {
    // B1: save processed slugs
    for (const s of newSlugs) processedSlugs.add(s);
    await saveProcessedSlugs(AGENT_HOME, processedSlugs);
    await updateDianaState(AGENT_HOME, processed, ontologyItems.length, conflicts);
    await updateDianaMemory(AGENT_HOME, processed, ontologyItems, conflicts);

    // Load updated batch count for digest + long-term memory
    let batchNum = 0;
    try {
      const bs = JSON.parse(require("fs").readFileSync(join(AGENT_HOME, "batch-state.json"), "utf8")) as { items_processed?: number };
      // count from diana-memory
      const dm = await readFile(join(AGENT_HOME, "memory", "diana-memory.md"), "utf8").catch(() => "");
      const m = dm.match(/批次執行次數：(\d+)/);
      batchNum = m ? parseInt(m[1]) : 1;
    } catch {}

    await appendLongTermMemory(AGENT_HOME, batchNum, processed, ontologyItems.length, conflicts, auditPatched);
    await generateWeeklyDigest(AGENT_HOME, VAULT_DIR, batchNum, actions);
    await contradictionScan(VAULT_DIR, AGENT_HOME, actions);
  } else if (TEST_CONTRADICTION) {
    await contradictionScan(VAULT_DIR, AGENT_HOME, actions);
  }

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
    console.log("DRY-RUN Step 14: would scan radar_vec for contradictions (Sunday only)");
    console.log("--- END DRY-RUN ---\n");
  }
}

main().catch((err) => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});

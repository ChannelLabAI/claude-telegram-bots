#!/usr/bin/env bun
import { createHash } from "node:crypto";
import {
  existsSync, mkdirSync, readFileSync, renameSync, writeFileSync, watch,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

type KnowledgeBase = {
  project: string;
  name: string;
  root_node_token: string;
  truth_path: string;
  archive_keywords: string[];
  archive_target_title: string;
};
type Config = {
  schema: string;
  space_id: string;
  lark_host: string;
  truth_repo: string;
  archive_log: string;
  state_dir: string;
  pm_hub_url_patterns: string[];
  dynamic_value_exempt_title_patterns: string[];
  knowledge_bases: KnowledgeBase[];
};
type Page = {
  project: string;
  kb: string;
  title: string;
  node_token: string;
  obj_token: string;
  url: string;
  text: string;
  blocks: unknown[];
};
type Snapshot = { schema: string; fetched_at: string; pages: Page[] };
type Finding = {
  check: "K1" | "K2" | "K3" | "K4";
  severity: "P1" | "P2";
  project: string;
  page: string;
  page_url: string;
  category: string;
  evidence: string;
  suggestion: string;
  source_sha?: string;
};

const API_ROOT = "https://open.larksuite.com/open-apis";
const args = process.argv.slice(2);

function option(name: string, fallback?: string): string | undefined {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
}
function die(message: string, code = 2): never {
  console.error(`[kb-guard] ${message}`);
  process.exit(code);
}
function readJson<T>(path: string): T {
  try { return JSON.parse(readFileSync(path, "utf8")) as T; }
  catch (error) { die(`cannot read JSON ${path}: ${String(error)}`); }
}
function atomicJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, path);
}
function sha(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
function configPath(): string {
  const root = resolve(import.meta.dir, "../..");
  return option("--config", join(root, "shared/config/kb-guard.json"))!;
}
function loadConfig(): Config {
  const config = readJson<Config>(configPath());
  if (config.schema !== "kb-guard-config-v1" || !config.knowledge_bases?.length) {
    die("invalid config schema or empty knowledge_bases");
  }
  return config;
}
function pageFor(config: Config, snapshot: Snapshot, project: string): Page | undefined {
  return snapshot.pages.find((page) => page.project === project)
    ?? snapshot.pages.find((page) => page.kb === config.knowledge_bases.find((kb) => kb.project === project)?.name);
}

async function larkGet(path: string, token: string): Promise<any> {
  const response = await fetch(`${API_ROOT}${path}`, {
    method: "GET",
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(20_000),
  });
  const payload = await response.json().catch(() => ({})) as any;
  if (!response.ok || Number(payload.code ?? 0) !== 0) {
    throw new Error(`Lark GET failed status=${response.status} code=${payload.code ?? "?"}`);
  }
  return payload.data ?? payload;
}
function gcpSecret(name: string): string {
  const result = spawnSync("gcloud", ["secrets", "versions", "access", "latest", `--secret=${name}`, "--project=channellab-prod"], { encoding: "utf8", timeout: 10_000 });
  if (result.status !== 0 || !result.stdout.trim()) throw new Error(`required GCP secret unavailable: ${name}`);
  return result.stdout.trim();
}
async function larkAccessToken(): Promise<string> {
  if (process.env.KB_GUARD_LARK_TOKEN) return process.env.KB_GUARD_LARK_TOKEN;
  const response = await fetch(`${API_ROOT}/auth/v3/tenant_access_token/internal`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ app_id: gcpSecret("lark-app-id-chl"), app_secret: gcpSecret("lark-app-secret-chl") }),
    signal: AbortSignal.timeout(15_000),
  });
  const payload = await response.json().catch(() => ({})) as any;
  if (!response.ok || Number(payload.code ?? 0) !== 0 || !String(payload.tenant_access_token ?? "")) {
    throw new Error(`Lark tenant token failed status=${response.status} code=${payload.code ?? "?"}`);
  }
  return String(payload.tenant_access_token);
}
async function paged(path: string, token: string, pageSize: number): Promise<any[]> {
  const output: any[] = [];
  let pageToken = "";
  do {
    const separator = path.includes("?") ? "&" : "?";
    const query = `${path}${separator}page_size=${pageSize}${pageToken ? `&page_token=${encodeURIComponent(pageToken)}` : ""}`;
    const data = await larkGet(query, token);
    output.push(...(Array.isArray(data.items) ? data.items : Array.isArray(data.nodes) ? data.nodes : []));
    pageToken = data.has_more ? String(data.page_token ?? data.next_page_token ?? "") : "";
    if (data.has_more && !pageToken) throw new Error("Lark pagination omitted page_token");
  } while (pageToken);
  return output;
}
function blockText(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(blockText).filter(Boolean).join(" ");
  if (!value || typeof value !== "object") return "";
  const object = value as Record<string, unknown>;
  const direct = typeof object.text === "string" ? object.text : "";
  return [direct, ...Object.entries(object)
    .filter(([key]) => !["token", "file_token", "url", "block_id", "parent_id"].includes(key))
    .map(([, child]) => blockText(child))].filter(Boolean).join(" ");
}
async function fetchSnapshot(config: Config): Promise<Snapshot> {
  const token = await larkAccessToken();
  const pages: Page[] = [];
  for (const kb of config.knowledge_bases) {
    const rootData = await larkGet(`/wiki/v2/spaces/get_node?token=${encodeURIComponent(kb.root_node_token)}`, token);
    const root = rootData.node ?? rootData;
    const queue: string[] = [kb.root_node_token];
    const seenParents = new Set<string>();
    if (String(root.obj_type ?? "") === "docx" && String(root.obj_token ?? "")) {
      const objToken = String(root.obj_token);
      const blocks = await paged(`/docx/v1/documents/${encodeURIComponent(objToken)}/blocks`, token, 500);
      pages.push({
        project: kb.project, kb: kb.name, title: String(root.title ?? kb.name),
        node_token: kb.root_node_token, obj_token: objToken,
        url: `https://${config.lark_host}/wiki/${kb.root_node_token}`,
        text: blocks.map(blockText).filter(Boolean).join("\n"), blocks,
      });
    }
    while (queue.length) {
      const parent = queue.shift()!;
      if (seenParents.has(parent)) continue;
      seenParents.add(parent);
      const nodes = await paged(`/wiki/v2/spaces/${encodeURIComponent(config.space_id)}/nodes?parent_node_token=${encodeURIComponent(parent)}`, token, 50);
      for (const node of nodes) {
        const nodeToken = String(node.node_token ?? "");
        if (node.has_child && nodeToken) queue.push(nodeToken);
        if (String(node.obj_type ?? "") !== "docx") continue;
        const objToken = String(node.obj_token ?? "");
        if (!objToken) continue;
        const blocks = await paged(`/docx/v1/documents/${encodeURIComponent(objToken)}/blocks`, token, 500);
        pages.push({
          project: kb.project,
          kb: kb.name,
          title: String(node.title ?? nodeToken),
          node_token: nodeToken,
          obj_token: objToken,
          url: `https://${config.lark_host}/wiki/${nodeToken}`,
          text: blocks.map(blockText).filter(Boolean).join("\n"),
          blocks,
        });
      }
    }
  }
  return { schema: "kb-guard-snapshot-v1", fetched_at: new Date().toISOString(), pages };
}

function exemptDynamicPage(config: Config, title: string): boolean {
  return config.dynamic_value_exempt_title_patterns.some((pattern) =>
    title.toLocaleLowerCase().includes(pattern.toLocaleLowerCase()));
}
function scanK2(config: Config, snapshot: Snapshot): Finding[] {
  const findings: Finding[] = [];
  for (const page of snapshot.pages) {
    for (const rawLine of page.text.split("\n")) {
      const line = rawLine.trim();
      const matches: Array<[string, RegExp]> = [
        ["health_dynamic", /健康度\s*[：:]\s*[🟢🟡🔴]/u],
        ["owner_due_dynamic", /@[\p{L}\p{N}_-]+.*\bdue:\d{4}-\d{2}-\d{2}\b/iu],
        ["current_payment_dynamic", /(本期款項|已到帳)/u],
      ];
      for (const [category, pattern] of matches) {
        if (!pattern.test(line)) continue;
        if (category === "current_payment_dynamic" && exemptDynamicPage(config, page.title)) continue;
        findings.push({
          check: "K2", severity: "P1", project: page.project, page: page.title,
          page_url: page.url, category, evidence: `matched forbidden dynamic-value pattern: ${category}`,
          suggestion: "Remove the dynamic value from the manually curated KB; keep current state in pm-hub truth.",
        });
      }
    }
  }
  return findings;
}
function findFileObjects(value: unknown, output: Array<Record<string, unknown>>): void {
  if (Array.isArray(value)) { for (const child of value) findFileObjects(child, output); return; }
  if (!value || typeof value !== "object") return;
  const object = value as Record<string, unknown>;
  if (object.file && typeof object.file === "object") output.push(object.file as Record<string, unknown>);
  for (const child of Object.values(object)) findFileObjects(child, output);
}
function expandHome(path: string): string {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}
async function scanK3(config: Config, snapshot: Snapshot): Promise<Finding[]> {
  const findings: Finding[] = [];
  const httpMapPath = option("--http-map");
  const httpMap = httpMapPath ? readJson<Record<string, number>>(httpMapPath) : undefined;
  for (const page of snapshot.pages) {
    const urls = [...new Set(page.text.match(/https?:\/\/[^\s)\]>]+/g) ?? [])]
      .filter((url) => config.pm_hub_url_patterns.some((prefix) => url.startsWith(prefix)));
    for (const url of urls) {
      let status = httpMap?.[url];
      if (status === undefined) {
        try {
          const response = await fetch(url, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(10_000) });
          status = response.status;
        } catch { status = 0; }
      }
      if (status < 200 || status >= 400) findings.push({
        check: "K3", severity: "P1", project: page.project, page: page.title,
        page_url: page.url, category: "pm_hub_link_broken", evidence: `${url} status=${status}`,
        suggestion: "Ask a human steward to verify and replace the broken pm-hub link.",
      });
    }
    const paths = [...new Set(page.text.match(/(?:~\/|\/home\/[^/]+\/)agency\/archive\/[^\s)\]>]+/g) ?? [])];
    for (const path of paths) if (!existsSync(expandHome(path))) findings.push({
      check: "K3", severity: "P1", project: page.project, page: page.title,
      page_url: page.url, category: "archive_path_missing", evidence: path,
      suggestion: "Ask a human steward to restore the archive object or update the KB reference.",
    });
    const files: Array<Record<string, unknown>> = [];
    findFileObjects(page.blocks, files);
    for (let index = 0; index < files.length; index++) {
      const token = String(files[index].token ?? files[index].file_token ?? "").trim();
      if (!token) findings.push({
        check: "K3", severity: "P1", project: page.project, page: page.title,
        page_url: page.url, category: "file_token_empty", evidence: `file block index=${index} token=<empty>`,
        suggestion: "Ask a human steward to rebind the attachment and confirm it opens.",
      });
    }
  }
  return findings;
}

function git(args: string[], cwd: string, allowFailure = false): string {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0 && !allowFailure) die(`git ${args[0]} failed: ${(result.stderr ?? "").trim()}`);
  return result.status === 0 ? result.stdout : "";
}
function structuralFacts(markdown: string): Map<string, string> {
  const facts = new Map<string, string>();
  let section = "frontmatter";
  let inFrontmatter = markdown.startsWith("---\n");
  let frontmatterDelimiters = 0;
  for (const raw of markdown.split("\n")) {
    const line = raw.trimEnd();
    if (line === "---" && (inFrontmatter || frontmatterDelimiters === 0)) {
      frontmatterDelimiters++;
      if (frontmatterDelimiters === 2) { inFrontmatter = false; section = "body"; }
      continue;
    }
    const heading = line.match(/^##\s+(.+)/);
    if (heading) section = heading[1].trim();
    if (section === "日誌" || section === "任務" || section === "事件" || section === "例行") continue;
    const field = line.match(/^\s{0,4}([\p{L}\p{N}_⚠️ -]{1,40}):\s*(.+)$/u);
    if (field && (inFrontmatter || ["摘要", "利害關係人"].includes(section))) {
      facts.set(`${section}:${field[1].trim()}`, field[2].trim());
    }
  }
  return facts;
}
function scanK1(config: Config, snapshot: Snapshot, repo: string, before: string, after: string): Finding[] {
  const findings: Finding[] = [];
  for (const kb of config.knowledge_bases) {
    const oldText = git(["show", `${before}:${kb.truth_path}`], repo, true);
    const newText = git(["show", `${after}:${kb.truth_path}`], repo, true);
    if (!oldText || !newText) continue;
    const oldFacts = structuralFacts(oldText);
    const newFacts = structuralFacts(newText);
    for (const [key, newValue] of newFacts) {
      const oldValue = oldFacts.get(key);
      if (oldValue === undefined || oldValue === newValue) continue;
      const keyName = key.split(":").at(-1)!;
      const page = snapshot.pages.find((candidate) => candidate.project === kb.project
        && (candidate.text.includes(oldValue) || candidate.text.includes(keyName)));
      if (!page) continue;
      findings.push({
        check: "K1", severity: "P2", project: kb.project, page: page.title,
        page_url: page.url, category: "truth_structural_drift",
        evidence: `structural field changed: ${keyName}; commit=${after}`, source_sha: after,
        suggestion: `KB page may need a human update based on truth commit ${after}.`,
      });
    }
  }
  return findings;
}
function scanK4(config: Config, snapshot: Snapshot, logPath: string, beforeLines: number): Finding[] {
  if (!existsSync(logPath)) die(`archive log does not exist: ${logPath}`);
  const added = readFileSync(logPath, "utf8").split("\n").slice(beforeLines).filter((line) => line.trim());
  const findings: Finding[] = [];
  for (let addedIndex = 0; addedIndex < added.length; addedIndex++) {
    const line = added[addedIndex];
    const lower = line.toLocaleLowerCase();
    for (const kb of config.knowledge_bases) {
      if (!kb.archive_keywords.some((keyword) => lower.includes(keyword.toLocaleLowerCase()))) continue;
      const page = snapshot.pages.find((candidate) => candidate.project === kb.project
        && candidate.title.toLocaleLowerCase().includes(kb.archive_target_title.toLocaleLowerCase()))
        ?? pageFor(config, snapshot, kb.project);
      if (!page) continue;
      findings.push({
        check: "K4", severity: "P2", project: kb.project, page: page.title,
        page_url: page.url, category: "new_archive_candidate",
        evidence: `ARCHIVE-LOG line=${beforeLines + addedIndex + 1} sha256=${sha(line).slice(0, 16)}`,
        suggestion: `Consider mounting this archived document under “${kb.archive_target_title}”; a human must decide and edit.`,
      });
      break;
    }
  }
  return findings;
}

function printResult(findings: Finding[]): void {
  console.log(JSON.stringify({ schema: "kb-guard-result-v1", findings, counts: {
    total: findings.length, P1: findings.filter((item) => item.severity === "P1").length,
    P2: findings.filter((item) => item.severity === "P2").length,
  } }, null, 2));
}

async function daily(config: Config): Promise<void> {
  const snapshot = await fetchSnapshot(config);
  atomicJson(join(config.state_dir, "latest-snapshot.json"), snapshot);
  printResult([...scanK2(config, snapshot), ...await scanK3(config, snapshot)]);
}
async function watchMode(config: Config): Promise<void> {
  mkdirSync(config.state_dir, { recursive: true });
  const watchStatePath = join(config.state_dir, "watch-state.json");
  let state = existsSync(watchStatePath)
    ? readJson<{ truth_sha: string; archive_lines: number }>(watchStatePath)
    : { truth_sha: git(["rev-parse", "HEAD"], config.truth_repo).trim(), archive_lines: existsSync(config.archive_log) ? readFileSync(config.archive_log, "utf8").split("\n").length : 0 };
  atomicJson(watchStatePath, state);
  let running = false;
  const reconcile = async () => {
    if (running) return;
    running = true;
    try {
      const snapshot = await fetchSnapshot(config);
      const currentSha = git(["rev-parse", "HEAD"], config.truth_repo).trim();
      const findings: Finding[] = [];
      if (currentSha !== state.truth_sha) findings.push(...scanK1(config, snapshot, config.truth_repo, state.truth_sha, currentSha));
      const lines = existsSync(config.archive_log) ? readFileSync(config.archive_log, "utf8").split("\n").length : state.archive_lines;
      if (lines > state.archive_lines) findings.push(...scanK4(config, snapshot, config.archive_log, state.archive_lines));
      if (findings.length) printResult(findings);
      state = { truth_sha: currentSha, archive_lines: lines };
      atomicJson(watchStatePath, state);
    } catch (error) { console.error(`[kb-guard] watch reconcile failed: ${String(error)}`); }
    finally { running = false; }
  };
  const watchers = [watch(join(config.truth_repo, ".git/logs/HEAD"), () => setTimeout(reconcile, 500))];
  if (existsSync(config.archive_log)) watchers.push(watch(config.archive_log, () => setTimeout(reconcile, 500)));
  console.error(`[kb-guard] watching truth and archive events (${watchers.length} watcher(s))`);
  await new Promise(() => undefined);
}

async function main(): Promise<void> {
  const command = args[0] ?? "daily";
  if (command === "--help" || command === "-h" || command === "help") {
    console.log("usage: kb-guard.sh daily|watch|fetch|scan|truth|archive [options]");
    return;
  }
  const config = loadConfig();
  if (command === "fetch") {
    const output = option("--out") ?? die("fetch requires --out");
    atomicJson(output, await fetchSnapshot(config));
  } else if (command === "scan") {
    const snapshot = readJson<Snapshot>(option("--snapshot") ?? die("scan requires --snapshot"));
    printResult([...scanK2(config, snapshot), ...await scanK3(config, snapshot)]);
  } else if (command === "truth") {
    const snapshot = readJson<Snapshot>(option("--snapshot") ?? die("truth requires --snapshot"));
    const before = option("--before") ?? die("truth requires --before");
    const after = option("--after") ?? die("truth requires --after");
    printResult(scanK1(config, snapshot, option("--repo", config.truth_repo)!, before, after));
  } else if (command === "archive") {
    const snapshot = readJson<Snapshot>(option("--snapshot") ?? die("archive requires --snapshot"));
    const beforeLines = Number(option("--before-lines", "0"));
    printResult(scanK4(config, snapshot, option("--log", config.archive_log)!, beforeLines));
  } else if (command === "daily") await daily(config);
  else if (command === "watch") await watchMode(config);
  else die("usage: kb-guard.sh daily|watch|fetch|scan|truth|archive [options]");
}

main().catch((error) => die(String(error), 1));

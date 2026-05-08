#!/usr/bin/env bun
// vault-orphan-scanner.ts — Orphan Node Scanner for Ocean vault
// .md orphans: CODE/KNOWLEDGE/RESOURCE → link to nearest existing _index.md or stage; UNKNOWN/DRAFT → report only.
// Non-.md files: link to same-dir .md anchor; fall back to nearest ancestor _index.md/README (no vault root).
// Does NOT create new _index.md files.

import { readdir, readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, relative, dirname, basename, extname, normalize, resolve, isAbsolute } from "node:path";

export interface ScannerResult {
  total: number;
  orphanCount: number;
  code: { total: number; linked: number; failed: number };
  knowledge: { total: number; linked: number; staged: number };
  resource: { total: number; linked: number; staged: number };
  draft: { total: number };
  archive: { total: number };
  unknown: { total: number };
  nonMd: { total: number; linked: number; noAnchor: number };
  noAnchorList: string[];
  modifiedIndexes: Array<{ indexPath: string; addedLinks: string[] }>;
  stagedFiles: Array<{ originalPath: string; stagedPath: string }>;
  needsManualIndex: string[];
  unknownList: string[];
}

type OrphanType = "CODE" | "KNOWLEDGE" | "RESOURCE" | "DRAFT" | "ARCHIVE" | "UNKNOWN";
// ARCHIVE: raw records (seabed/chats/reports) — try .clsc.md anchor, else report only

function log(msg: string): void {
  process.stderr.write(`[vault-orphan-scanner] ${msg}\n`);
}

function nowUtc8(): string {
  const offset = 8 * 60 * 60 * 1000;
  const local = new Date(Date.now() + offset);
  return local.toISOString().replace("T", " ").slice(0, 19);
}

function today(): string {
  return nowUtc8().slice(0, 10);
}

// Dirs to skip for .md orphan scanning (includes 業務流 to avoid flooding with project code)
const EXCLUDE_DIRS = new Set([
  ".stversions",
  "_orphan_staging",
  "封存深淵",
  "原檔海床",
  "Seabed",
  "業務流",
]);

// Dirs to skip for non-.md scanning (業務流 included so code files get linked)
const EXCLUDE_DIRS_NON_MD = new Set([
  ".stversions",
  "_orphan_staging",
  "封存深淵",
  "原檔海床",
  "Seabed",
]);

// Non-md file types to scan and link into the vault graph
const NON_MD_EXTENSIONS = new Set([
  ".py", ".ts", ".js", ".jsx", ".tsx", ".sh",
  ".json", ".yaml", ".yml", ".toml",
  ".png", ".jpg", ".jpeg", ".svg", ".gif", ".webp",
  ".pdf", ".log", ".txt", ".csv",
]);

// Directory names to skip (also skip any dir starting with ".")
const HIDDEN_DIR_PREFIX = ".";

function shouldSkipDir(name: string): boolean {
  return EXCLUDE_DIRS.has(name) || name.startsWith(HIDDEN_DIR_PREFIX);
}

// Narrow: for orphan detection only (excludes 業務流 to avoid flooding)
async function collectMdFilesNarrow(dir: string): Promise<string[]> {
  const results: string[] = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return results;
  }
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (shouldSkipDir(entry.name)) continue;
      results.push(...(await collectMdFilesNarrow(fullPath)));
    } else if (
      entry.isFile() &&
      entry.name.endsWith(".md") &&
      !entry.name.endsWith(".clsc.md")
    ) {
      results.push(fullPath);
    }
  }
  return results;
}

// Broad: includes 業務流 AND .clsc.md files — used for reverseIndex and anchor lookup
async function collectMdFilesAll(dir: string): Promise<string[]> {
  const results: string[] = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return results;
  }
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (EXCLUDE_DIRS_NON_MD.has(entry.name) || entry.name.startsWith(HIDDEN_DIR_PREFIX)) continue;
      results.push(...(await collectMdFilesAll(fullPath)));
    } else if (
      entry.isFile() &&
      entry.name.endsWith(".md") &&
      !entry.name.endsWith(".clsc.md")
    ) {
      results.push(fullPath);
    }
  }
  return results;
}

async function collectNonMdFiles(dir: string): Promise<string[]> {
  const results: string[] = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return results;
  }
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      // Use broader allow-list: 業務流 is included so project code gets linked
      if (EXCLUDE_DIRS_NON_MD.has(entry.name) || entry.name.startsWith(HIDDEN_DIR_PREFIX)) continue;
      results.push(...(await collectNonMdFiles(fullPath)));
    } else if (entry.isFile()) {
      const ext = extname(entry.name).toLowerCase();
      if (NON_MD_EXTENSIONS.has(ext)) results.push(fullPath);
    }
  }
  return results;
}

// Walk up from startDir to find nearest anchor in ancestor dirs.
// Priority per level: _index.md → README.md → any .md (last resort).
// Stops before vault root to prevent piling onto root _index.md.
// NOTE: normalize() preserves trailing slash — strip it for dirname() comparison to work.
function findAnchorInParents(startDir: string, vaultRoot: string, allMdFilesSet: Set<string>): string | null {
  const vaultNorm = normalize(vaultRoot).replace(/\/$/, "");
  let dir = normalize(startDir).replace(/\/$/, "");
  let anyMdFallback: string | null = null; // best "any .md" found at closest ancestor

  while (dir !== vaultNorm) {
    const parent = dirname(dir);
    if (parent === dir) break; // filesystem root
    if (parent === vaultNorm) break; // next step would reach vault root — stop
    dir = parent;
    const indexPath = join(dir, "_index.md");
    if (allMdFilesSet.has(indexPath)) return indexPath;
    for (const name of ["README.md", "README.zh-TW.md", "readme.md"]) {
      const p = join(dir, name);
      if (allMdFilesSet.has(p)) return p;
    }
    // Option (b): also check any .md in this ancestor dir as last resort
    if (anyMdFallback === null) {
      for (const f of allMdFilesSet) {
        if (dirname(f) === dir && !f.endsWith(".clsc.md")) {
          anyMdFallback = f;
          break;
        }
      }
    }
  }
  return anyMdFallback;
}

// Find the best .md anchor in the same directory (prefer _index > README > any .md).
function findBestAnchorInDir(dir: string, allMdFilesSet: Set<string>): string | null {
  const indexPath = join(dir, "_index.md");
  if (allMdFilesSet.has(indexPath)) return indexPath;
  for (const name of ["README.md", "README.zh-TW.md", "readme.md"]) {
    const p = join(dir, name);
    if (allMdFilesSet.has(p)) return p;
  }
  for (const f of allMdFilesSet) {
    if (dirname(f) === dir && !f.endsWith(".clsc.md")) return f;
  }
  return null;
}

function parseFrontmatter(content: string): Record<string, unknown> {
  if (!content.startsWith("---")) return {};
  const end = content.indexOf("\n---", 3);
  if (end === -1) return {};
  const yaml = content.slice(3, end).trim();
  const result: Record<string, unknown> = {};
  for (const line of yaml.split("\n")) {
    const col = line.indexOf(":");
    if (col === -1) continue;
    const key = line.slice(0, col).trim();
    const raw = line.slice(col + 1).trim();
    if (raw.startsWith("[") && raw.endsWith("]")) {
      result[key] = raw
        .slice(1, -1)
        .split(",")
        .map((s) => s.trim().replace(/^["']|["']$/g, ""))
        .filter(Boolean);
    } else {
      result[key] = raw.replace(/^["']|["']$/g, "");
    }
  }
  return result;
}

// Token overlap: how many tags share a token with the target string
function tokenize(s: string): Set<string> {
  const tokens = new Set<string>();
  const lower = s.toLowerCase();
  tokens.add(lower);
  for (const t of lower.split(/[\s\-_/]+/)) {
    if (t) tokens.add(t);
  }
  return tokens;
}

function tokenOverlapScore(tags: string[], target: string): number {
  const targetTokens = tokenize(target);
  let score = 0;
  for (const tag of tags) {
    const tagTokens = tokenize(tag);
    for (const t of tagTokens) {
      if (targetTokens.has(t)) {
        score++;
        break;
      }
    }
  }
  return score;
}

function classifyOrphan(
  filePath: string,
  vaultRoot: string,
  fm: Record<string, unknown>
): OrphanType {
  const relPath = relative(vaultRoot, filePath);
  const fmType = String(fm.type ?? "").toLowerCase();

  if (relPath.includes("_drafts/") || relPath.startsWith("_drafts/"))
    return "DRAFT";
  if (relPath.startsWith("技術海圖/") || fmType === "code") return "CODE";
  if (["concept", "tidedoc", "pearl", "adr"].includes(fmType))
    return "KNOWLEDGE";
  if (["person", "company", "project", "deal", "client"].includes(fmType))
    return "RESOURCE";
  // Raw records and reports: report only
  if (["seabed", "chats", "report", "digest"].includes(fmType))
    return "ARCHIVE";
  if (relPath.startsWith("聊天記錄/") || relPath.startsWith("Reports/"))
    return "ARCHIVE";
  return "UNKNOWN";
}

function escapeWikilink(s: string): string {
  return s.replace(/\]\]/g, "\\]\\]");
}

async function appendWikilink(
  indexPath: string,
  filePath: string,
  vaultRoot: string,
  ts: string
): Promise<void> {
  const relPath = relative(vaultRoot, filePath);
  const noExt = escapeWikilink(
    relPath.endsWith(".md") ? relPath.slice(0, -3) : relPath
  );
  const displayName = escapeWikilink(basename(filePath, ".md"));
  const linkLine = `\n<!-- appended by diana:vault-manage at ${ts} -->\n- [[${noExt}|${displayName}]]`;
  const existing = await readFile(indexPath, "utf8");
  await writeFile(indexPath, existing + linkLine, "utf8");
}

function recordModifiedIndex(
  result: ScannerResult,
  indexPath: string,
  filePath: string,
  vaultRoot: string
): void {
  const noExt = relative(vaultRoot, filePath).replace(/\.md$/, "");
  const existing = result.modifiedIndexes.find(
    (m) => m.indexPath === indexPath
  );
  if (existing) {
    existing.addedLinks.push(noExt);
  } else {
    result.modifiedIndexes.push({ indexPath, addedLinks: [noExt] });
  }
}

async function stageFile(
  filePath: string,
  vaultRoot: string,
  type: "KNOW" | "RES" | "UNK"
): Promise<string> {
  const relPath = relative(vaultRoot, filePath);
  const stagingPath = join(vaultRoot, "_orphan_staging", type, relPath);
  const resolvedStaging = resolve(stagingPath);
  const resolvedVault = resolve(vaultRoot);
  if (!resolvedStaging.startsWith(resolvedVault + "/")) {
    throw new Error(`Path traversal detected: ${stagingPath}`);
  }
  await mkdir(dirname(stagingPath), { recursive: true });
  await rename(filePath, stagingPath);
  return stagingPath;
}

async function getSubdirs(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  return entries.filter((e) => e.isDirectory()).map((e) => e.name);
}

// Walk up from startDir to vaultRoot, return path of the nearest existing _index.md.
// Returns null if none found. Never creates new files.
function findNearestIndex(startDir: string, vaultRoot: string): string | null {
  const vaultNorm = normalize(vaultRoot);
  let dir = normalize(startDir);

  while (true) {
    const indexPath = join(dir, "_index.md");
    if (existsSync(indexPath)) return indexPath;
    if (dir === vaultNorm) break;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  return null;
}

export async function runOrphanScanner(
  vaultRootRaw: string
): Promise<ScannerResult> {
  if (!isAbsolute(vaultRootRaw)) {
    log(`ERROR: VAULT_ROOT must be an absolute path: ${vaultRootRaw}`);
    process.exit(1);
  }
  const vaultRoot = normalize(vaultRootRaw);
  if (!existsSync(vaultRoot)) {
    log(`ERROR: vaultRoot not found: ${vaultRoot}`);
    process.exit(1);
  }

  const ts = nowUtc8();
  const d = today();

  log(`scanning ${vaultRoot}`);

  // Broad: includes 業務流 — for reverseIndex (dedup) + anchor lookup
  const allMdFilesAll = await collectMdFilesAll(vaultRoot);
  const allMdFilesSet = new Set(allMdFilesAll);
  log(`found ${allMdFilesAll.length} .md files (broad incl. 業務流)`);

  // Narrow: excludes 業務流 — for orphan detection candidates + report total
  const allMdFilesNarrow = await collectMdFilesNarrow(vaultRoot);
  log(`found ${allMdFilesNarrow.length} .md files (narrow orphan candidates)`);

  const allNonMdFiles = await collectNonMdFiles(vaultRoot);
  log(`found ${allNonMdFiles.length} non-.md files`);

  // Build wikilink reverse index from ALL .md files (broad)
  // This ensures links in 業務流 README.md files are indexed, preventing duplicate appends.
  const reverseIndex = new Map<string, Set<string>>();

  function addToIndex(target: string, source: string): void {
    if (!reverseIndex.has(target)) reverseIndex.set(target, new Set());
    reverseIndex.get(target)!.add(source);
  }

  for (const f of allMdFilesAll) {
    let content: string;
    try {
      content = await readFile(f, "utf8");
    } catch {
      continue;
    }
    const re = /\[\[([^\]]+)\]\]/g;
    let m;
    while ((m = re.exec(content)) !== null) {
      let target = m[1];
      const pipeIdx = target.indexOf("|");
      if (pipeIdx !== -1) target = target.slice(0, pipeIdx);
      target = target.trim();
      if (!target) continue;
      if (target.endsWith(".md")) target = target.slice(0, -3);
      addToIndex(target, f);
      const name = basename(target);
      if (name !== target) addToIndex(name, f);
    }
  }

  function isOrphan(filePath: string): boolean {
    const relNoExt = relative(vaultRoot, filePath).replace(/\.md$/, "");
    const name = basename(filePath, ".md");
    return (
      (reverseIndex.get(relNoExt)?.size ?? 0) === 0 &&
      (reverseIndex.get(name)?.size ?? 0) === 0
    );
  }

  // Find orphans from narrow set only (skip _index.md, _schema.md)
  const orphans: string[] = [];
  for (const f of allMdFilesNarrow) {
    const name = basename(f, ".md");
    if (name === "_index" || name === "_schema") continue;
    if (isOrphan(f)) orphans.push(f);
  }
  log(`found ${orphans.length} orphans`);

  const result: ScannerResult = {
    total: allMdFilesNarrow.length,
    orphanCount: orphans.length,
    code: { total: 0, linked: 0, failed: 0 },
    knowledge: { total: 0, linked: 0, staged: 0 },
    resource: { total: 0, linked: 0, staged: 0 },
    draft: { total: 0 },
    archive: { total: 0 },
    unknown: { total: 0 },
    nonMd: { total: 0, linked: 0, noAnchor: 0 },
    noAnchorList: [],
    modifiedIndexes: [],
    stagedFiles: [],
    needsManualIndex: [],
    unknownList: [],
  };

  // Vault top-level dirs for KNOWLEDGE matching
  const vaultTopDirs = await getSubdirs(vaultRoot);
  // 業務流 subdirs for RESOURCE matching
  const businessFlowPath = join(vaultRoot, "業務流");
  const businessDirs = existsSync(businessFlowPath)
    ? await getSubdirs(businessFlowPath)
    : [];

  for (const orphan of orphans) {
    let fm: Record<string, unknown> = {};
    try {
      const content = await readFile(orphan, "utf8");
      fm = parseFrontmatter(content);
    } catch {}

    const type = classifyOrphan(orphan, vaultRoot, fm);

    if (type === "CODE") {
      result.code.total++;
      // Find nearest existing _index.md (no creation)
      const indexPath = findNearestIndex(dirname(orphan), vaultRoot);
      if (!indexPath) {
        result.code.failed++;
        result.needsManualIndex.push(orphan);
        continue;
      }
      try {
        await appendWikilink(indexPath, orphan, vaultRoot, ts);
        recordModifiedIndex(result, indexPath, orphan, vaultRoot);
        result.code.linked++;
      } catch (err) {
        log(`WARN: could not link CODE orphan ${orphan}: ${String(err)}`);
        result.code.failed++;
        result.needsManualIndex.push(orphan);
      }
    } else if (type === "KNOWLEDGE") {
      result.knowledge.total++;
      const tags = (fm.tags as string[] | undefined) ?? [];

      // Try token-match to a top-level _index.md first
      let bestScore = 0;
      let bestIndexPath = "";
      for (const dir of vaultTopDirs) {
        if (EXCLUDE_DIRS.has(dir)) continue;
        const indexPath = join(vaultRoot, dir, "_index.md");
        if (!existsSync(indexPath)) continue;
        const score = tokenOverlapScore(tags, dir);
        if (
          score > bestScore ||
          (score === bestScore && score > 0 && indexPath < bestIndexPath)
        ) {
          bestScore = score;
          bestIndexPath = indexPath;
        }
      }

      // Fallback: find nearest existing index (no creation)
      const resolvedIndex =
        bestScore > 0
          ? bestIndexPath
          : findNearestIndex(dirname(orphan), vaultRoot);

      if (!resolvedIndex) {
        result.knowledge.staged++;
        try {
          const staged = await stageFile(orphan, vaultRoot, "KNOW");
          result.stagedFiles.push({ originalPath: orphan, stagedPath: staged });
        } catch {}
        continue;
      }
      try {
        await appendWikilink(resolvedIndex, orphan, vaultRoot, ts);
        recordModifiedIndex(result, resolvedIndex, orphan, vaultRoot);
        result.knowledge.linked++;
      } catch (err) {
        log(`WARN: could not link KNOWLEDGE orphan ${orphan}: ${String(err)}`);
        result.knowledge.staged++;
        try {
          const staged = await stageFile(orphan, vaultRoot, "KNOW");
          result.stagedFiles.push({ originalPath: orphan, stagedPath: staged });
        } catch {}
      }
    } else if (type === "RESOURCE") {
      result.resource.total++;
      const tags = (fm.tags as string[] | undefined) ?? [];
      const title = basename(orphan, ".md");
      const searchTokens = [...tags, title];

      // Try token-match to a 業務流 subdir _index.md first
      let bestScore = 0;
      let bestIndexPath = "";
      for (const dir of businessDirs) {
        const indexPath = join(businessFlowPath, dir, "_index.md");
        if (!existsSync(indexPath)) continue;
        const score = tokenOverlapScore(searchTokens, dir);
        if (
          score > bestScore ||
          (score === bestScore && score > 0 && indexPath < bestIndexPath)
        ) {
          bestScore = score;
          bestIndexPath = indexPath;
        }
      }

      // Fallback: find nearest existing index (no creation)
      const resolvedIndex =
        bestScore > 0
          ? bestIndexPath
          : findNearestIndex(dirname(orphan), vaultRoot);

      if (!resolvedIndex) {
        result.resource.staged++;
        try {
          const staged = await stageFile(orphan, vaultRoot, "RES");
          result.stagedFiles.push({ originalPath: orphan, stagedPath: staged });
        } catch {}
        continue;
      }
      try {
        await appendWikilink(resolvedIndex, orphan, vaultRoot, ts);
        recordModifiedIndex(result, resolvedIndex, orphan, vaultRoot);
        result.resource.linked++;
      } catch (err) {
        log(`WARN: could not link RESOURCE orphan ${orphan}: ${String(err)}`);
        result.resource.staged++;
        try {
          const staged = await stageFile(orphan, vaultRoot, "RES");
          result.stagedFiles.push({ originalPath: orphan, stagedPath: staged });
        } catch {}
      }
    } else if (type === "DRAFT") {
      result.draft.total++;
      // Skip; report only
    } else if (type === "ARCHIVE") {
      result.archive.total++;
      // Raw seabed records — report-only. Linking creates noisy star topology.
      // Accessible via MemOcean/CLSC search, not Obsidian graph.
    } else {
      // UNKNOWN: report only — no auto-linking, no staging
      result.unknown.total++;
      result.unknownList.push(relative(vaultRoot, orphan));
    }
  }

  // ── Non-.md file orphan linking ────────────────────────────────────────────
  // For each non-.md file with no incoming wikilinks, find the best .md anchor
  // in the same directory and append [[file.ext|file]] wikilink.

  function isNonMdOrphan(filePath: string): boolean {
    const relPath = relative(vaultRoot, filePath);
    const name = basename(filePath);
    return (
      (reverseIndex.get(relPath)?.size ?? 0) === 0 &&
      (reverseIndex.get(name)?.size ?? 0) === 0
    );
  }

  const nonMdOrphans = allNonMdFiles.filter(isNonMdOrphan);
  log(`found ${nonMdOrphans.length} non-.md orphans`);
  result.nonMd.total = nonMdOrphans.length;

  for (const nonMdFile of nonMdOrphans) {
    // Prefer same-dir anchor; walk up to nearest _index.md/README.md, stopping before vault root
    const anchorPath =
      findBestAnchorInDir(dirname(nonMdFile), allMdFilesSet) ??
      findAnchorInParents(dirname(nonMdFile), vaultRoot, allMdFilesSet);

    if (!anchorPath) {
      result.nonMd.noAnchor++;
      result.noAnchorList.push(relative(vaultRoot, nonMdFile));
      continue;
    }

    try {
      await appendWikilink(anchorPath, nonMdFile, vaultRoot, ts);
      recordModifiedIndex(result, anchorPath, nonMdFile, vaultRoot);
      result.nonMd.linked++;
    } catch (err) {
      log(`WARN: could not link non-.md file ${nonMdFile}: ${String(err)}`);
      result.nonMd.noAnchor++;
      result.noAnchorList.push(relative(vaultRoot, nonMdFile));
    }
  }

  await generateReport(vaultRoot, result, ts, d);
  log(
    `done. md-orphans=${result.orphanCount}, non-md-orphans=${result.nonMd.total}(linked=${result.nonMd.linked}), staged=${result.stagedFiles.length}`
  );
  return result;
}

async function generateReport(
  vaultRoot: string,
  r: ScannerResult,
  ts: string,
  d: string
): Promise<void> {
  const stagingDir = join(vaultRoot, "_orphan_staging");
  await mkdir(join(stagingDir, "KNOW"), { recursive: true });
  await mkdir(join(stagingDir, "RES"), { recursive: true });
  await mkdir(join(stagingDir, "UNK"), { recursive: true });

  const lines = [
    "---",
    "type: report",
    `created: ${d}`,
    `updated: ${d}`,
    "generated_by: diana:vault-manage",
    "---",
    "",
    "# 孤兒節點掃描報告",
    "",
    `> 執行時間：${ts} UTC+8`,
    `> 掃描範圍：${vaultRoot}`,
    `> 總文件數：${r.total}`,
    `> 孤兒數：${r.orphanCount}`,
    "",
    "## 處理摘要",
    "",
    "| 類型 | 數量 | 結果 |",
    "|---|---|---|",
    `| CODE (.md) | ${r.code.total} | 連結 ${r.code.linked} / 失敗 ${r.code.failed} |`,
    `| KNOWLEDGE (.md) | ${r.knowledge.total} | 連結 ${r.knowledge.linked} / 暫存 ${r.knowledge.staged} |`,
    `| RESOURCE (.md) | ${r.resource.total} | 連結 ${r.resource.linked} / 暫存 ${r.resource.staged} |`,
    `| DRAFT (.md) | ${r.draft.total} | 跳過（報告用） |`,
    `| ARCHIVE (.md) | ${r.archive.total} | 排除（seabed 原始記錄） |`,
    `| UNKNOWN (.md) | ${r.unknown.total} | 僅報告（不自動連結） |`,
    `| 非 .md 文件 | ${r.nonMd.total} | 連結 ${r.nonMd.linked} / 無錨點 ${r.nonMd.noAnchor} |`,
    "",
  ];

  if (r.stagedFiles.length > 0) {
    lines.push("## 無法自動連結（需人工處理）", "");
    for (const { originalPath, stagedPath } of r.stagedFiles) {
      lines.push(
        `- 原路徑: \`${originalPath}\` → 暫存: \`${stagedPath}\``
      );
    }
    lines.push("");
  }

  if (r.needsManualIndex.length > 0) {
    lines.push("## CODE 孤兒連結失敗", "");
    for (const f of r.needsManualIndex) {
      lines.push(`- \`${f}\``);
    }
    lines.push("");
  }

  if (r.unknownList.length > 0) {
    lines.push("## UNKNOWN 孤兒（需人工分類）", "");
    for (const f of r.unknownList) {
      lines.push(`- \`${f}\``);
    }
    lines.push("");
  }

  if (r.noAnchorList.length > 0) {
    lines.push("## 非 .md 孤兒：無錨點（需人工建立 .md 文件）", "");
    for (const f of r.noAnchorList) {
      lines.push(`- \`${f}\``);
    }
    lines.push("");
  }

  lines.push("## 已自動補 wikilink 的 _index.md", "");

  if (r.modifiedIndexes.length > 0) {
    for (const { indexPath, addedLinks } of r.modifiedIndexes) {
      lines.push(
        `- \`${indexPath}\`：新增 ${addedLinks.map((l) => `[[${l}]]`).join(", ")}`
      );
    }
  } else {
    lines.push("（無）");
  }

  lines.push("", "[[_index]] [[Bot System/_index]]");

  const reportPath = join(stagingDir, "_report.md");
  await writeFile(reportPath, lines.join("\n"), "utf8");
  log(`report: ${reportPath}`);
}

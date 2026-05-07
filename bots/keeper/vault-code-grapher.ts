#!/usr/bin/env bun
// vault-code-grapher.ts — Code Dependency Grapher for Ocean vault
// Scans entire vault for .py/.ts/.sh files, builds local import graphs.
// Only appends to existing _index.md — never creates new ones.

import { readdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, relative, dirname, basename, extname, normalize } from "node:path";

export interface GrapherResult {
  dirsProcessed: number;
  indexesCreated: number;
  indexesUpdated: number;
}

function log(msg: string): void {
  process.stderr.write(`[vault-code-grapher] ${msg}\n`);
}

function nowUtc8(): string {
  const offset = 8 * 60 * 60 * 1000;
  const local = new Date(Date.now() + offset);
  return local.toISOString().replace("T", " ").slice(0, 19);
}

const SKIP_DIRS = new Set([
  ".stversions",
  "_orphan_staging",
  "node_modules",
  ".git",
  "dist",
  "封存深淵",  // archived projects, skip
]);

async function collectCodeFiles(dir: string): Promise<string[]> {
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
      if (SKIP_DIRS.has(entry.name)) continue;
      results.push(...(await collectCodeFiles(fullPath)));
    } else if (entry.isFile()) {
      const ext = extname(entry.name);
      if ([".py", ".ts", ".sh"].includes(ext)) {
        results.push(fullPath);
      }
    }
  }
  return results;
}

function parseLocalDeps(
  filePath: string,
  content: string,
  allFilesSet: Set<string>
): string[] {
  const ext = extname(filePath);
  const dir = dirname(filePath);
  const found: string[] = [];

  if (ext === ".ts") {
    const re = /(?:from|require\s*\()\s*["'](\.{1,2}[^"']+)["']/g;
    let m;
    while ((m = re.exec(content)) !== null) {
      const imp = m[1];
      const base = join(dir, imp);
      for (const suffix of ["", ".ts", "/index.ts"]) {
        const resolved = normalize(base + suffix);
        if (allFilesSet.has(resolved)) {
          found.push(resolved);
          break;
        }
      }
    }
  } else if (ext === ".py") {
    const re = /^(?:from\s+(\.[\w.]*)\s+import|import\s+(\.[\w.]*))/gm;
    let m;
    while ((m = re.exec(content)) !== null) {
      const imp = (m[1] ?? m[2]).replace(/^\./, "").replace(/\./g, "/");
      if (!imp) continue;
      const resolved = normalize(join(dir, imp + ".py"));
      if (allFilesSet.has(resolved)) found.push(resolved);
    }
  } else if (ext === ".sh") {
    const re = /^(?:source|\.)\s+([^\s#;]+)/gm;
    let m;
    while ((m = re.exec(content)) !== null) {
      const imp = m[1];
      const resolved = imp.startsWith("/")
        ? normalize(imp)
        : normalize(join(dir, imp));
      if (allFilesSet.has(resolved)) found.push(resolved);
    }
  }

  return [...new Set(found)];
}

export async function runCodeGrapher(
  vaultRootRaw: string
): Promise<GrapherResult> {
  const chartRoot = normalize(vaultRootRaw);
  if (!existsSync(chartRoot)) {
    log(`ERROR: vaultRoot not found: ${chartRoot}`);
    return { dirsProcessed: 0, indexesCreated: 0, indexesUpdated: 0 };
  }

  log(`scanning ${chartRoot}`);
  const allFiles = await collectCodeFiles(chartRoot);
  log(`found ${allFiles.length} code files`);

  const allFilesSet = new Set(allFiles);

  const deps = new Map<string, string[]>();
  for (const f of allFiles) {
    try {
      const content = await readFile(f, "utf8");
      deps.set(f, parseLocalDeps(f, content, allFilesSet));
    } catch {
      deps.set(f, []);
    }
  }

  // Group by each file's direct parent directory
  const byDir = new Map<string, string[]>();
  for (const f of allFiles) {
    const d = dirname(f);
    if (!byDir.has(d)) byDir.set(d, []);
    byDir.get(d)!.push(f);
  }

  let updated = 0;
  const ts = nowUtc8();

  for (const [subDir, files] of byDir) {
    const indexPath = join(subDir, "_index.md");

    if (!existsSync(indexPath)) {
      // Skip directories without an existing _index.md — do not create new ones
      // Creating _index.md in code dirs pollutes the knowledge graph topology
      log(`skip (no _index.md): ${relative(chartRoot, subDir)}`);
    } else {
      // Append only — never overwrite existing content (AC-15)
      const appendContent = [
        "",
        `<!-- diana:vault-manage 代碼依賴圖更新 ${ts} -->`,
        "",
        "## 代碼依賴圖（diana 自動生成）",
        "",
        "| 文件 | 依賴 |",
        "|---|---|",
        ...files.map((f) => {
          const fileDeps = (deps.get(f) ?? [])
            .map((dep) => basename(dep))
            .join(", ");
          return `| \`${relative(subDir, f)}\` | ${fileDeps || "—"} |`;
        }),
      ].join("\n");

      const existing = await readFile(indexPath, "utf8");
      await writeFile(indexPath, existing + appendContent, "utf8");
      log(`updated: ${relative(chartRoot, indexPath)}`);
      updated++;
    }
  }

  log(`done: ${byDir.size} dirs processed, ${updated} updated`);
  return {
    dirsProcessed: byDir.size,
    indexesCreated: 0,
    indexesUpdated: updated,
  };
}

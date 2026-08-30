import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import {
  REQUIRED_EXCLUDED_NODE_TOKENS,
  atomicWriteJson,
  createRateLimitedLarkFetch,
  discoverSources,
  mirrorSources,
  renderMirrorMarkdown,
  scanSensitiveContent,
  validateConfig,
} from "../bin/lark-mirror-lib.ts";
import { ingest, syncFailureAlertMessage, unifiedTenantSession } from "../bin/lark-mirror.ts";
import {
  chmodSync,
  closeSync,
  existsSync,
  readdirSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function root(): string {
  const value = mkdtempSync(join(tmpdir(), "lark-mirror-test-"));
  roots.push(value);
  return value;
}

function response(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function radarInserted() {
  return {
    radar_action: "inserted" as const,
    radar_duplicates_removed: [],
  };
}

function writeRealIngestFixture(testRoot: string): {
  dataDir: string;
  documentPath: string;
  emptyHome: string;
} {
  const dataDir = join(testRoot, "memocean-data");
  const emptyHome = join(testRoot, "empty-home");
  mkdirSync(join(dataDir, "shared"), { recursive: true });
  mkdirSync(join(emptyHome, ".memocean"), { recursive: true });
  const userSite = join(process.env.HOME ?? "", ".local");
  if (existsSync(userSite)) symlinkSync(userSite, join(emptyHome, ".local"));
  const memoceanSource = join(import.meta.dir, "../memocean-mcp");
  if (!existsSync(memoceanSource)) {
    throw new Error("shared/memocean-mcp integration dependency is missing");
  }
  symlinkSync(
    memoceanSource,
    join(dataDir, "shared", "memocean-mcp"),
  );
  const db = new Database(join(dataDir, "memory.db"), { create: true });
  db.exec(`
    CREATE TABLE radar (
      slug TEXT PRIMARY KEY,
      clsc TEXT NOT NULL,
      tokens INTEGER NOT NULL,
      drawer_path TEXT,
      source_hash TEXT NOT NULL,
      encoded_at TEXT DEFAULT CURRENT_TIMESTAMP,
      summary TEXT
    );
    CREATE VIRTUAL TABLE radar_fts USING fts5(slug, clsc);
  `);
  db.close();
  new Database(join(emptyHome, ".memocean", "memory.db"), { create: true }).close();
  const documentPath = join(testRoot, "mirror-ingest-proof.md");
  writeFileSync(
    documentPath,
    "# Mirror ingest environment proof\n\n"
      + "This fixture invokes the real MemOcean Python ingester in a child process. ".repeat(4),
  );
  return { dataDir, documentPath, emptyHome };
}

const config = {
  version: 1 as const,
  vault_dir: "/tmp/vault",
  wiki_spaces: ["7588969620657147413"],
  drive_folders: ["folder_1"],
  excluded_node_tokens: [...REQUIRED_EXCLUDED_NODE_TOKENS, "SensitiveNode_1"],
  lark_host: "ajp9g1jn00cg.jp.larksuite.com",
};
const testSpace = config.wiki_spaces[0];
const realSingleSpaceResponse = {
  code: 0,
  data: {
    space: {
      space_id: testSpace,
      name: "NOXCAT",
    },
  },
};

describe("shared Lark tenant token session", () => {
  test("mirror obtains a tenant token without a persisted user OAuth state", async () => {
    const requests: Array<{ url: string; authorization: string }> = [];
    const session = await unifiedTenantSession({
      credentials: { appId: "id", appSecret: "secret" },
      tokenFetch: async () => response({
        code: 0, msg: "ok", tenant_access_token: "tenant-access", expire: 3600,
      }),
      apiFetch: async (input, init) => {
        requests.push({
          url: String(input),
          authorization: new Headers(init?.headers).get("authorization") ?? "",
        });
        return response(realSingleSpaceResponse);
      },
    });
    expect(session.provider.kind).toBe("tenant-access-token");
    expect(session.accessToken).toBe("tenant-access");
    await session.provider.fetch(
      `https://open.larksuite.com/open-apis/wiki/v2/spaces/${testSpace}`,
      { method: "GET", headers: { authorization: `Bearer ${session.accessToken}` } },
    );
    expect(requests).toEqual([{
      url: `https://open.larksuite.com/open-apis/wiki/v2/spaces/${testSpace}`,
      authorization: "Bearer tenant-access",
    }]);
  });

  test("failed tenant exchange stops before any mirror API request", async () => {
    let apiCalls = 0;
    await expect(unifiedTenantSession({
      credentials: { appId: "id", appSecret: "secret" },
      tokenFetch: async () => response({ code: 9499, msg: "Bad Request" }),
      apiFetch: async () => { apiCalls++; return response({ code: 0, data: {} }); },
    })).rejects.toThrow("tenant_access_token");
    expect(apiCalls).toBe(0);
  });

  test("tenant transport permits only readonly official API calls and keeps Wiki throttling", async () => {
    const calls: string[] = [];
    const sleeps: number[] = [];
    let now = 1_000;
    const fetcher = createRateLimitedLarkFetch(
      async (input) => { calls.push(String(input)); return response({ code: 0, data: {} }); },
      async (milliseconds) => { sleeps.push(milliseconds); now += milliseconds; },
      () => now,
    );
    const url = `https://open.larksuite.com/open-apis/wiki/v2/spaces/${testSpace}/nodes`;
    await fetcher(url, { method: "GET" });
    await fetcher(url, { method: "GET" });
    expect(calls).toHaveLength(2);
    expect(sleeps).toEqual([750]);
    await expect(fetcher(url, { method: "POST" })).rejects.toThrow("唯讀");
  });
});

describe("MemOcean ingest subprocess", () => {
  test("real spawned ingester receives MEMOCEAN_DATA_DIR and writes the selected radar DB", async () => {
    const fixture = writeRealIngestFixture(root());
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    const previousHome = process.env.HOME;
    process.env.MEMOCEAN_DATA_DIR = fixture.dataDir;
    process.env.HOME = fixture.emptyHome;
    try {
      await ingest(fixture.documentPath);
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    const db = new Database(join(fixture.dataDir, "memory.db"), { readonly: true });
    const row = db.query("SELECT drawer_path FROM radar WHERE drawer_path = ?")
      .get(fixture.documentPath) as { drawer_path: string } | null;
    db.close();
    expect(row).toEqual({ drawer_path: fixture.documentPath });
  });

  test("real spawned ingester reconciles an alternate-slug duplicate and reports an auditable update", async () => {
    const fixture = writeRealIngestFixture(root());
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    const previousHome = process.env.HOME;
    process.env.MEMOCEAN_DATA_DIR = fixture.dataDir;
    process.env.HOME = fixture.emptyHome;
    try {
      const first = await ingest(fixture.documentPath);
      expect(first).toMatchObject({
        radar_action: "inserted",
        radar_duplicates_removed: [],
      });
      const db = new Database(join(fixture.dataDir, "memory.db"));
      db.query(`
        INSERT INTO radar (slug, clsc, tokens, drawer_path, source_hash)
        VALUES (?, ?, ?, ?, ?)
      `).run(
        "NOXCAT-lark-mirror-alternate",
        "[alternate|writer]",
        4,
        fixture.documentPath,
        "alternate-hash",
      );
      db.query("INSERT INTO radar_fts (slug, clsc) VALUES (?, ?)")
        .run("NOXCAT-lark-mirror-alternate", "[alternate|writer]");
      db.close();
      writeFileSync(fixture.documentPath, "too short for a full MarkItDown ingest");

      const second = await ingest(fixture.documentPath, undefined, true);
      expect(second.radar_action).toBe("updated");
      expect(second.radar_duplicates_removed).toHaveLength(1);
      expect(second.radar_duplicates_removed[0]).toMatchObject({
        path: fixture.documentPath,
        removed_slug: "NOXCAT-lark-mirror-alternate",
      });
      expect(second.radar_duplicates_removed[0]?.kept_slug_after_upsert)
        .toStartWith("file:");
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    const db = new Database(join(fixture.dataDir, "memory.db"), { readonly: true });
    expect(db.query(`
      SELECT count(*) AS total, count(DISTINCT drawer_path) AS unique_paths
      FROM radar
    `).get()).toEqual({ total: 1, unique_paths: 1 });
    expect(db.query(`
      SELECT count(*) AS count FROM radar_fts
      WHERE slug = 'NOXCAT-lark-mirror-alternate'
    `).get()).toEqual({ count: 0 });
    db.close();
  });

  test("real spawned ingester fails when MEMOCEAN_DATA_DIR is absent", async () => {
    const fixture = writeRealIngestFixture(root());
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    const previousHome = process.env.HOME;
    const fallbackDb = join(fixture.emptyHome, ".memocean", "memory.db");
    const fallbackBefore = statSync(fallbackDb);
    delete process.env.MEMOCEAN_DATA_DIR;
    process.env.HOME = fixture.emptyHome;
    try {
      await expect(ingest(fixture.documentPath))
        .rejects.toThrow("MEMOCEAN_DATA_DIR 未設定");
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    const db = new Database(join(fixture.dataDir, "memory.db"), { readonly: true });
    expect(db.query("SELECT count(*) AS count FROM radar").get()).toEqual({ count: 0 });
    db.close();
    const fallbackAfter = statSync(fallbackDb);
    expect(fallbackAfter.size).toBe(fallbackBefore.size);
    expect(fallbackAfter.mtimeMs).toBe(fallbackBefore.mtimeMs);
  });

  test("actual missing-env and insecure-state failures produce distinct diagnostic alerts", async () => {
    const testRoot = root();
    const documentPath = join(testRoot, "document.md");
    writeFileSync(documentPath, "# diagnostic fixture");
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    delete process.env.MEMOCEAN_DATA_DIR;
    let missingEnv: unknown;
    try {
      await ingest(documentPath);
    } catch (error) {
      missingEnv = error;
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
    }

    const insecureRuntime = join(testRoot, "insecure-runtime");
    mkdirSync(insecureRuntime, { mode: 0o755 });
    chmodSync(insecureRuntime, 0o755);
    let insecureState: unknown;
    try {
      atomicWriteJson(join(insecureRuntime, "state.json"), { version: 1 });
    } catch (error) {
      insecureState = error;
    }

    const missingAlert = syncFailureAlertMessage(missingEnv);
    const insecureAlert = syncFailureAlertMessage(insecureState);
    expect(missingAlert).toContain("LarkDocError: MEMOCEAN_DATA_DIR 未設定");
    expect(insecureAlert)
      .toContain("LarkDocError: Lark mirror runtime 目錄權限不安全");
    expect(missingAlert).not.toBe(insecureAlert);
  });

  test("actual long Python traceback keeps its final exception in the bounded alert", async () => {
    const fixture = writeRealIngestFixture(root());
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    const previousHome = process.env.HOME;
    process.env.MEMOCEAN_DATA_DIR = join(fixture.emptyHome, ".memocean");
    process.env.HOME = fixture.emptyHome;
    let failure: unknown;
    try {
      await ingest(fixture.documentPath);
    } catch (error) {
      failure = error;
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }

    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message.length).toBeGreaterThan(500);
    const alert = syncFailureAlertMessage(failure);
    expect([...alert].length).toBeLessThan(540);
    expect(alert).toContain("sqlite3.OperationalError: no such table: radar");
  });

  test("real spawned ingester removes the exact stale radar row after relocation", async () => {
    const testRoot = root();
    const fixture = writeRealIngestFixture(testRoot);
    const oldDir = join(testRoot, "old-parent");
    const newDir = join(testRoot, "new-parent");
    mkdirSync(oldDir);
    mkdirSync(newDir);
    const oldPath = join(oldDir, "same-document.md");
    const newPath = join(newDir, "same-document.md");
    const content = "# Relocation proof\n\n"
      + "This fixture verifies stale radar cleanup after a safe path correction. ".repeat(4);
    writeFileSync(oldPath, content);
    writeFileSync(newPath, content);
    const previousDataDir = process.env.MEMOCEAN_DATA_DIR;
    const previousHome = process.env.HOME;
    process.env.MEMOCEAN_DATA_DIR = fixture.dataDir;
    process.env.HOME = fixture.emptyHome;
    try {
      await ingest(oldPath);
      await ingest(newPath, oldPath);
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    const db = new Database(join(fixture.dataDir, "memory.db"), { readonly: true });
    expect(db.query("SELECT drawer_path FROM radar ORDER BY drawer_path").all())
      .toEqual([{ drawer_path: newPath }]);
    db.close();
  });
});

describe("whitelist discovery and read-only boundary", () => {
  test("accepts regional tenant hosts and rejects non-Lark or malformed hosts", () => {
    expect(validateConfig(config).lark_host).toBe("ajp9g1jn00cg.jp.larksuite.com");
    for (const lark_host of [
      "evil.com",
      "larksuite.com.evil.com",
      "bad_host.jp.larksuite.com",
      "bad host.jp.larksuite.com",
      "-bad.jp.larksuite.com",
      "bad-.jp.larksuite.com",
      "bad..jp.larksuite.com",
      "larksuite.com",
    ]) {
      expect(() => validateConfig({ ...config, lark_host })).toThrow("設定無效");
    }
  });

  test("missing/empty whitelist fails closed", () => {
    expect(() => validateConfig({ ...config, wiki_spaces: [], drive_folders: [] }))
      .toThrow("fail-closed");
    expect(() => validateConfig({ ...config, wiki_spaces: ["../all"] })).toThrow("設定無效");
    expect(validateConfig({
      ...config,
      wiki_spaces: ["7588585813969997332"],
    }).wiki_spaces).toEqual(["7588585813969997332"]);
    expect(() => validateConfig({
      ...config,
      excluded_node_tokens: REQUIRED_EXCLUDED_NODE_TOKENS.slice(1),
    })).toThrow("設定無效");
  });

  test("enumerates only configured spaces and skips denied node subtrees", async () => {
    const methods: string[] = [];
    const urls: string[] = [];
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      urls.push(url);
      methods.push(init?.method ?? "GET");
      if (url.endsWith(`/wiki/v2/spaces/${testSpace}`)) {
        return response(realSingleSpaceResponse);
      }
      if (url.includes(`/wiki/v2/spaces/${testSpace}/nodes`)) {
        return response({ data: { items: [{
          node_token: "WikiNode_1",
          obj_type: "docx",
          obj_token: "DocToken_1",
          title: "Strategy",
          obj_edit_time: "1720000000",
          has_child: false,
        }, {
          node_token: "SensitiveNode_1",
          obj_type: "docx",
          obj_token: "SecretDoc_1",
          title: "Password vault",
          obj_edit_time: "1720000000",
          has_child: true,
        }], has_more: false } });
      }
      if (url.includes("/drive/v1/files")) {
        return response({ data: { files: [{
          type: "file",
          token: "FileToken_1",
          name: "sponsor.pdf",
          modified_time: "1720000000",
          url: "https://noxcat.larksuite.com/file/FileToken_1",
        }], has_more: false } });
      }
      throw new Error(`unexpected ${url}`);
    };
    const result = await discoverSources({ config, accessToken: "access", fetch: fetcher });
    expect(result.spaces).toEqual([{ id: testSpace, name: "NOXCAT" }]);
    expect(result.sources.map((source) => source.title)).toEqual(["Strategy", "sponsor.pdf"]);
    expect(result.excluded).toBe(1);
    expect(result.wiki_stats[0]?.excluded).toBe(1);
    expect(methods.every((method) => method === "GET")).toBeTrue();
    expect(urls.every((url) => !url.includes("/wiki/v2/spaces?"))).toBeTrue();
    expect(urls.filter((url) => url.includes("/nodes")).length).toBe(1);
    expect(urls.some((url) => url.includes("folder_token=folder_1"))).toBeTrue();
  });

  test("a shortcut pointing back to an ancestor is not expanded as a child tree", async () => {
    const parentCalls = new Map<string, number>();
    const fetcher = async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith(`/wiki/v2/spaces/${testSpace}`)) {
        return response(realSingleSpaceResponse);
      }
      const parent = url.searchParams.get("parent_node_token") ?? "<root>";
      parentCalls.set(parent, (parentCalls.get(parent) ?? 0) + 1);
      if ([...parentCalls.values()].reduce((sum, count) => sum + count, 0) > 8) {
        throw new Error("cycle call limit exceeded");
      }
      if (parent === "<root>") {
        return response({ data: { items: [{
          node_token: "AncestorNode_1",
          obj_type: "docx",
          obj_token: "AncestorDoc_1",
          title: "Ancestor",
          has_child: true,
          node_type: "origin",
        }], has_more: false } });
      }
      if (parent === "AncestorNode_1") {
        return response({ data: { items: [{
          node_token: "ShortcutNode_1",
          obj_type: "docx",
          obj_token: "AncestorDoc_1",
          title: "Ancestor shortcut",
          has_child: true,
          node_type: "shortcut",
          origin_node_token: "AncestorNode_1",
        }], has_more: false } });
      }
      if (parent === "ShortcutNode_1") {
        return response({ data: { items: [{
          node_token: "AncestorNode_1",
          obj_type: "docx",
          obj_token: "AncestorDoc_1",
          title: "Ancestor",
          has_child: true,
          node_type: "origin",
        }], has_more: false } });
      }
      throw new Error(`unexpected parent ${parent}`);
    };

    const result = await discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "access",
      fetch: fetcher,
    });

    expect(result.sources.map((source) => source.token)).toEqual(["AncestorDoc_1"]);
    expect(result.accounting.deduplicated_sources).toBe(1);
    expect(result.unmirrored_nodes).toContainEqual({
      space_id: testSpace,
      node_token: "ShortcutNode_1",
      title: "Ancestor shortcut",
      reason: "duplicate_object_source",
      obj_type: "docx",
    });
    expect(result.wiki_stats[0]).toMatchObject({
      parent_expansions: 2,
      unique_parent_tokens: 1,
      duplicate_parent_skips: 0,
      shortcuts: 1,
      shortcut_children_skipped: 1,
    });
    expect(parentCalls).toEqual(new Map([
      ["<root>", 1],
      ["AncestorNode_1", 1],
    ]));
  });

  test("repeated ordinary node tokens are expanded at most once", async () => {
    const parentCalls = new Map<string, number>();
    const fetcher = async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith(`/wiki/v2/spaces/${testSpace}`)) {
        return response(realSingleSpaceResponse);
      }
      const parent = url.searchParams.get("parent_node_token") ?? "<root>";
      parentCalls.set(parent, (parentCalls.get(parent) ?? 0) + 1);
      if ([...parentCalls.values()].reduce((sum, count) => sum + count, 0) > 8) {
        throw new Error("cycle call limit exceeded");
      }
      const child = parent === "<root>"
        ? {
          node_token: "CycleNode_A",
          obj_type: "docx",
          obj_token: "CycleDoc_A",
          title: "A",
          has_child: true,
          node_type: "origin",
        }
        : parent === "CycleNode_A"
        ? {
          node_token: "CycleNode_B",
          obj_type: "docx",
          obj_token: "CycleDoc_B",
          title: "B",
          has_child: true,
          node_type: "origin",
        }
        : {
          node_token: "CycleNode_A",
          obj_type: "docx",
          obj_token: "CycleDoc_A",
          title: "A",
          has_child: true,
          node_type: "origin",
        };
      return response({ data: { items: [child], has_more: false } });
    };

    const result = await discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "access",
      fetch: fetcher,
    });

    expect(result.sources.map((source) => source.token).sort())
      .toEqual(["CycleDoc_A", "CycleDoc_B"]);
    expect(result.wiki_stats[0]).toMatchObject({
      parent_expansions: 3,
      unique_parent_tokens: 2,
      duplicate_parent_skips: 1,
      repeated_parent_tokens: [{ node_token: "CycleNode_A", attempts: 2 }],
    });
    expect(parentCalls).toEqual(new Map([
      ["<root>", 1],
      ["CycleNode_A", 1],
      ["CycleNode_B", 1],
    ]));
  });

  test("multi-level discovery preserves sibling paths and missing-source guard fails loud", async () => {
    const fetcher = async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith(`/wiki/v2/spaces/${testSpace}`)) {
        return response(realSingleSpaceResponse);
      }
      const parent = url.searchParams.get("parent_node_token") ?? "<root>";
      const nodes = parent === "<root>"
        ? [{
          node_token: "PlanningNode_1",
          obj_type: "docx",
          obj_token: "PlanningDoc_1",
          title: "Planning",
          has_child: true,
        }, {
          node_token: "CustomerNode_1",
          obj_type: "docx",
          obj_token: "CustomerDoc_1",
          title: "客户拜访-日本區",
          has_child: false,
        }]
        : parent === "PlanningNode_1"
        ? [{
          node_token: "MeetingsNode_1",
          obj_type: "docx",
          obj_token: "MeetingsDoc_1",
          title: "Meetings",
          has_child: true,
        }, {
          node_token: "CampaignNode_1",
          obj_type: "docx",
          obj_token: "CampaignDoc_1",
          title: "Campaign",
          has_child: false,
        }]
        : parent === "MeetingsNode_1"
        ? [{
          node_token: "MinutesNode_1",
          obj_type: "docx",
          obj_token: "MinutesDoc_1",
          title: "Minutes",
          has_child: false,
        }]
        : [];
      return response({ data: { items: nodes, has_more: false } });
    };
    const discovered = await discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "access",
      fetch: fetcher,
    });

    expect(discovered.sources.map((source) => source.relative_path)).toEqual([
      "NOXCAT/Planning",
      "NOXCAT/客户拜访-日本區",
      "NOXCAT/Planning/Meetings",
      "NOXCAT/Planning/Campaign",
      "NOXCAT/Planning/Meetings/Minutes",
    ]);
    expect(discovered.accounting).toMatchObject({
      wiki_nodes: 5,
      mirror_sources: 5,
      excluded: 0,
      unsupported: 0,
    });
    expect(discovered.wiki_stats[0]).toMatchObject({
      parent_expansions: 3,
      nodes: 5,
      unique_nodes: 5,
      docx: 5,
    });
    let fetched = 0;
    let ingested = 0;
    await expect(mirrorSources({
      config: { ...config, vault_dir: join(root(), "vault") },
      statePath: join(root(), "runtime", "state.json"),
      sources: discovered.sources.slice(1),
      expectedSourceCount: discovered.accounting.mirror_sources,
      accessToken: "access",
      fetch: async () => {
        fetched++;
        return response({});
      },
      ingest: async () => { ingested++; return radarInserted(); },
    })).rejects.toThrow("完整性不符");
    expect(fetched).toBe(0);
    expect(ingested).toBe(0);
  });

  test("rejects the old flat single-space fixture shape", async () => {
    await expect(discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "access",
      fetch: async () => response({
        code: 0,
        data: {
          space_id: testSpace,
          name: "NOXCAT",
        },
      }),
    })).rejects.toThrow("白名單 Wiki space 不可見");
  });

  test("tenant Wiki 131006 is explicit and stops discovery", async () => {
    await expect(discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "tenant-access",
      fetch: async () => response({
        code: 131006,
        msg: "permission denied: wiki space permission denied",
      }),
    })).rejects.toThrow("131006");
  });

  test("code=0 with an empty node list is not treated as an empty Wiki", async () => {
    let calls = 0;
    await expect(discoverSources({
      config: { ...config, drive_folders: [] },
      accessToken: "tenant-access",
      fetch: async () => ++calls === 1
        ? response(realSingleSpaceResponse)
        : response({ code: 0, data: { items: [], has_more: false } }),
    })).rejects.toThrow("code=0");
  });
});

describe("Markdown mirror and incremental state", () => {
  test("sensitive scanner keeps structural guards and returns categories only", () => {
    expect(scanSensitiveContent("-----BEGIN PRIVATE KEY-----")).toEqual(["private_key"]);
    expect(scanSensitiveContent("-----BEGIN PUBLIC KEY-----")).toEqual([]);
    expect(scanSensitiveContent("api sk-1234567890abcdefghijklmn")).toEqual(["api_key"]);
    expect(scanSensitiveContent("api sk-too-short")).toEqual([]);
    expect(scanSensitiveContent("password: hunter2")).toEqual(["credential"]);
    expect(scanSensitiveContent("password policy: use a manager")).toEqual([]);
  });

  test("business amounts, wallet addresses, and Ethereum transaction hashes are not sensitive", () => {
    const transactionHash =
      "0x5e8f3c4d7a9b1e2f6c8d0a4b7e9f1c3d5a7b9e2f4c6d8a0b1e3f5c7d9a2b4e6f";
    expect(transactionHash).toHaveLength(66);
    expect(scanSensitiveContent(transactionHash)).toEqual([]);
    expect(scanSensitiveContent("wallet 0x1111111111111111111111111111111111111111")).toEqual([]);
    expect(scanSensitiveContent("budget 2,500 USDT")).toEqual([]);
    expect(scanSensitiveContent("budget is pending and has no amount")).toEqual([]);
  });

  test("frontmatter and image links preserve source metadata", () => {
    const text = renderMirrorMarkdown({
      kind: "docx",
      token: "DocToken_1",
      title: "Doc",
      source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
      last_edit_time: "2026-07-27T00:00:00.000Z",
    }, "# Doc\n\n![Lark image: block_1]", "2026-07-27T01:00:00.000Z");
    expect(text).toContain('source: "https://noxcat.larksuite.com/docx/DocToken_1"');
    expect(text).toContain('lark_doc_id: "DocToken_1"');
    expect(text).toContain("last_edit_time:");
    expect(text).toContain("[Lark image](https://noxcat.larksuite.com/docx/DocToken_1#block-block_1)");
  });

  test("two syncs reconcile an alternate writer without increasing radar rows", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    const source = {
      kind: "docx" as const,
      token: "DocToken_1",
      title: "Nested Doc",
      source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
      last_edit_time: "2026-07-27T00:00:00.000Z",
      relative_path: "NOXCAT/Product/Nested Doc",
    };
    const radar = new Map<string, string[]>();
    const ingested: string[] = [];
    const radarOnlyCalls: boolean[] = [];
    const fetcher = async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/DocToken_1")) {
        return response({ data: { document: { title: "Nested Doc" } } });
      }
      return response({ data: { items: [
        { block_id: "page", block_type: 1, page: { elements: [{ text_run: { content: "Nested Doc" } }] } },
        { block_id: "list", parent_id: "page", block_type: 12, bullet: { elements: [{ text_run: { content: "Parent" } }] } },
        { block_id: "child", parent_id: "list", block_type: 12, bullet: { elements: [{ text_run: { content: "Child" } }] } },
        { block_id: "code", parent_id: "page", block_type: 14, code: { language: "ts", elements: [{ text_run: { content: "const x = 1" } }] } },
        { block_id: "table", parent_id: "page", block_type: 31, table: { property: { row_size: 1, column_size: 1 }, cells: ["cell"] } },
        { block_id: "cell", parent_id: "table", block_type: 32 },
        { block_id: "celltext", parent_id: "cell", block_type: 2, text: { elements: [{ text_run: { content: "Value" } }] } },
      ], has_more: false } });
    };
    const args = {
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [source],
      accessToken: "access",
      fetch: fetcher,
      ingest: async (path: string, _relocatedFrom?: string, radarOnly = false) => {
        ingested.push(path);
        radarOnlyCalls.push(radarOnly);
        const existing = radar.get(path) ?? [];
        const removed = existing.slice(1).map((slug, index) => ({
          path,
          kept_rowid: 1,
          kept_slug_before_upsert: existing[0]!,
          kept_slug_after_upsert: "file:canonical",
          removed_rowid: index + 2,
          removed_slug: slug,
        }));
        radar.set(path, ["file:canonical"]);
        return {
          radar_action: existing.length ? "updated" as const : "inserted" as const,
          radar_duplicates_removed: removed,
        };
      },
      now: "2026-07-27T01:00:00.000Z",
    };
    const first = await mirrorSources(args);
    radar.get(first.paths[0]!)!.push("NOXCAT-lark-mirror-alternate");
    const second = await mirrorSources(args);
    expect(first.written).toBe(1);
    expect(first.radar_inserted).toBe(1);
    expect(second.skipped).toBe(1);
    expect(second.radar_updated).toBe(1);
    expect(second.radar_deduplicated).toBe(1);
    expect(second.radar_cleanup[0]?.removed_slug).toBe("NOXCAT-lark-mirror-alternate");
    expect(ingested).toHaveLength(2);
    expect(radarOnlyCalls).toEqual([false, true]);
    expect([...radar.values()].flat()).toHaveLength(1);
    expect(new Set(radar.keys()).size).toBe([...radar.values()].flat().length);
    const markdown = readFileSync(first.paths[0]!, "utf8");
    expect(markdown).toContain("  - Child");
    expect(markdown).toContain("```ts");
    expect(markdown).toContain("| Value |");
  });

  test("a corrected parent path rewrites and safely removes the byte-identical orphan", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    const source = {
      kind: "docx" as const,
      token: "RelocateDoc_1",
      node_token: "RelocateNode_1",
      title: "Sibling",
      source_url: "https://noxcat.larksuite.com/wiki/RelocateNode_1",
      last_edit_time: "2026-07-27T00:00:00.000Z",
      relative_path: "NOXCAT/Wrong Parent/Sibling",
    };
    const fetcher = async (input: RequestInfo | URL) =>
      String(input).endsWith("/RelocateDoc_1")
        ? response({ data: { document: { title: "Sibling" } } })
        : response({ data: { items: [{
          block_id: "page",
          block_type: 1,
          page: { elements: [{ text_run: { content: "Sibling" } }] },
        }], has_more: false } });
    const first = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [source],
      accessToken: "access",
      fetch: fetcher,
      ingest: async () => radarInserted(),
      now: "2026-07-27T01:00:00.000Z",
    });
    const oldPath = first.paths[0]!;
    const corrected = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [{ ...source, relative_path: "NOXCAT/Sibling" }],
      accessToken: "access",
      fetch: fetcher,
      ingest: async () => radarInserted(),
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(corrected.relocated).toBe(1);
    expect(existsSync(oldPath)).toBeFalse();
    expect(existsSync(corrected.paths[0]!)).toBeTrue();
  });

  test("PEM private key is quarantined as metadata only and never written or ingested", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    let ingested = 0;
    const result = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [{
        kind: "docx",
        token: "DocToken_1",
        title: "Looks harmless",
        source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
        last_edit_time: "2026-07-27T00:00:00.000Z",
      }],
      accessToken: "access",
      fetch: async (input) => String(input).endsWith("/DocToken_1")
        ? response({ data: { document: { title: "Looks harmless" } } })
        : response({ data: { items: [{
          block_id: "page",
          block_type: 1,
          page: { elements: [{ text_run: { content: "-----BEGIN PRIVATE KEY-----" } }] },
        }], has_more: false } }),
      ingest: async () => { ingested++; return radarInserted(); },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result.quarantined).toBe(1);
    expect(result.written).toBe(0);
    expect(ingested).toBe(0);
    const state = readFileSync(statePath, "utf8");
    expect(state).toContain("private_key");
    expect(state).not.toContain("BEGIN PRIVATE KEY");
  });

  test("credential warning is recorded while the document is written and ingested", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    mkdirSync(join(testRoot, "runtime"));
    chmodSync(join(testRoot, "runtime"), 0o700);
    writeFileSync(statePath, JSON.stringify({
      version: 1,
      documents: {},
      quarantined: {
        "docx:DocToken_1": {
          title: "Needs manual review",
          source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
          reasons: ["credential"],
          detected_at: "2026-07-26T01:00:00.000Z",
        },
      },
    }));
    chmodSync(statePath, 0o600);
    let ingested = 0;
    const result = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [{
        kind: "docx",
        token: "DocToken_1",
        title: "Needs manual review",
        source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
        last_edit_time: "2026-07-27T00:00:00.000Z",
      }],
      accessToken: "access",
      fetch: async (input) => String(input).endsWith("/DocToken_1")
        ? response({ data: { document: { title: "Needs manual review" } } })
        : response({ data: { items: [{
          block_id: "page",
          block_type: 1,
          page: { elements: [{ text_run: { content: "password: hunter2" } }] },
        }], has_more: false } }),
      ingest: async (path) => {
        ingested++;
        expect(existsSync(path)).toBeTrue();
        return radarInserted();
      },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result.quarantined).toBe(0);
    expect(result.written).toBe(1);
    expect(result.processed).toBe(result.expected);
    expect(ingested).toBe(1);
    expect(result.credential_warned).toHaveLength(1);
    expect(existsSync(result.paths[0]!)).toBeTrue();
    const state = JSON.parse(readFileSync(statePath, "utf8"));
    expect(state.credential_warned).toEqual(result.credential_warned);
    expect(state.credential_warned[0].output_path).toBe(result.paths[0]);
    expect(state.quarantined).toEqual({});
    expect(readFileSync(result.paths[0]!, "utf8")).toContain("password: hunter2");
    expect(readFileSync(statePath, "utf8")).not.toContain("hunter2");
  });

  test("MindNote becomes a title/link stub without a content API call", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    let fetched = 0;
    let ingested = 0;
    const result = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [{
        kind: "mindnote",
        token: "MindToken_1",
        node_token: "MindNode_1",
        title: "Roadmap mindmap",
        source_url: "https://noxcat.larksuite.com/wiki/MindNode_1",
        last_edit_time: "2026-07-27T00:00:00.000Z",
      }],
      accessToken: "access",
      fetch: async () => {
        fetched++;
        return response({});
      },
      ingest: async () => { ingested++; return radarInserted(); },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result.written).toBe(1);
    expect(fetched).toBe(0);
    expect(ingested).toBe(1);
    const markdown = readFileSync(result.paths[0]!, "utf8");
    expect(markdown).toContain("MindNote source");
    expect(markdown).toContain("只保存標題與來源連結");
  });

  test("sheet remains metadata-only and never reads, writes, or ingests cells", async () => {
    const testRoot = root();
    const statePath = join(testRoot, "runtime", "state.json");
    const vault = join(testRoot, "vault");
    mkdirSync(vault);
    let fetched = 0;
    let ingested = 0;
    const result = await mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath,
      sources: [{
        kind: "sheet",
        token: "SheetToken_1",
        title: "Budget",
        source_url: "https://noxcat.larksuite.com/sheets/SheetToken_1",
        last_edit_time: "2026-07-27T00:00:00.000Z",
      }],
      accessToken: "access",
      fetch: async () => {
        fetched++;
        return response({});
      },
      ingest: async () => { ingested++; return radarInserted(); },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result).toEqual({
      written: 0,
      skipped: 0,
      skipped_by_reason: { unchanged: 0 },
      metadataOnly: 1,
      quarantined: 0,
      credential_warned: [],
      failed: 0,
      processed: 1,
      expected: 1,
      relocated: 0,
      radar_inserted: 0,
      radar_updated: 0,
      radar_deduplicated: 0,
      radar_cleanup: [],
      paths: [],
    });
    expect(fetched).toBe(0);
    expect(ingested).toBe(0);
    expect(existsSync(statePath)).toBeFalse();
  });

  test("vault symlink traversal is rejected before write or ingest", async () => {
    const testRoot = root();
    const vault = join(testRoot, "vault");
    const outside = join(testRoot, "outside");
    mkdirSync(vault);
    mkdirSync(outside);
    symlinkSync(outside, join(vault, "NOXCAT"));
    let ingested = 0;
    await expect(mirrorSources({
      config: { ...config, vault_dir: vault },
      statePath: join(testRoot, "runtime", "state.json"),
      sources: [{
        kind: "docx",
        token: "DocToken_1",
        title: "Doc",
        source_url: "https://noxcat.larksuite.com/docx/DocToken_1",
        last_edit_time: "2026-07-27T00:00:00.000Z",
        relative_path: "NOXCAT/Doc",
      }],
      accessToken: "access",
      fetch: async (input) => String(input).endsWith("/DocToken_1")
        ? response({ data: { document: { title: "Doc" } } })
        : response({ data: { items: [], has_more: false } }),
      ingest: async () => { ingested++; return radarInserted(); },
    })).rejects.toThrow("symlink");
    expect(ingested).toBe(0);
    expect(existsSync(join(outside, "Doc--Token_1.md"))).toBeFalse();
  });
});

import { afterEach, describe, expect, test } from "bun:test";
import {
  APPROVED_WIKI_SPACES,
  MIRROR_REDIRECT_URI,
  MIRROR_SCOPES,
  REQUIRED_EXCLUDED_NODE_TOKENS,
  TENANT_TOKEN_ENDPOINT,
  atomicWriteJson,
  createLarkCliFetch,
  createMirrorAuthorization,
  discoverSources,
  finishMirrorAuthorization,
  mirrorSources,
  parseEnvelope,
  refreshAccessToken,
  renderMirrorMarkdown,
  scanSensitiveContent,
  tenantAccessToken,
  validateConfig,
  type AlertSink,
  type SecretEnvelope,
  type SecretStore,
} from "../bin/lark-mirror-lib.ts";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
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

class MemorySecrets implements SecretStore {
  values: string[] = [];
  failWrite = false;
  constructor(initial?: string) {
    if (initial) this.values.push(initial);
  }
  async access(): Promise<string> {
    if (!this.values.length) throw new Error("missing");
    return this.values.at(-1)!;
  }
  async addVersion(_name: string, value: string): Promise<void> {
    if (this.failWrite) throw new Error("gcp unavailable");
    this.values.push(value);
  }
}

class Alerts implements AlertSink {
  records: Array<{ kind: string; message: string }> = [];
  async send(kind: any, message: string): Promise<void> {
    this.records.push({ kind, message });
  }
}

function envelope(overrides: Partial<SecretEnvelope> = {}): SecretEnvelope {
  return {
    version: 1,
    access_token: "access-old",
    access_expires_at: new Date(Date.now() + 60_000).toISOString(),
    refresh_token: "refresh-old",
    refresh_expires_at: new Date(Date.now() + 30 * 86_400_000).toISOString(),
    verified_user_id: "rabbit",
    scope: [...MIRROR_SCOPES],
    generation: 1,
    ...overrides,
  };
}

function lockPath(): string {
  return join(root(), "runtime", "refresh.lock");
}

const config = {
  version: 1 as const,
  vault_dir: "/tmp/vault",
  wiki_spaces: [APPROVED_WIKI_SPACES[0]],
  drive_folders: ["folder_1"],
  excluded_node_tokens: [...REQUIRED_EXCLUDED_NODE_TOKENS, "SensitiveNode_1"],
  lark_host: "noxcat.larksuite.com",
};
const testSpace = APPROVED_WIKI_SPACES[0];

describe("tenant credential provider", () => {
  test("gets a short-lived tenant token directly from app credentials", async () => {
    let requestUrl = "";
    let request: RequestInit | undefined;
    const token = await tenantAccessToken({
      appId: "cli_test\n",
      appSecret: "app-secret\n",
      fetch: async (input, init) => {
        requestUrl = String(input);
        request = init;
        return response({
          code: 0,
          tenant_access_token: "tenant-access",
          expire: 7200,
        });
      },
    });
    expect(token).toBe("tenant-access");
    expect(requestUrl).toBe(TENANT_TOKEN_ENDPOINT);
    expect(request?.method).toBe("POST");
    expect(JSON.parse(String(request?.body))).toEqual({
      app_id: "cli_test",
      app_secret: "app-secret",
    });
  });

  test("failed tenant exchange exposes neither app secret nor response detail", async () => {
    await expect(tenantAccessToken({
      appId: "cli_test",
      appSecret: "never-print-this",
      fetch: async () => response({
        code: 10003,
        msg: "bad never-print-this",
      }, 400),
    })).rejects.toThrow("Lark API 回傳失敗");
  });
});

describe("official Lark CLI user transport", () => {
  test("allows only API GET with --as user and throttles Wiki enumeration", async () => {
    const calls: string[][] = [];
    const sleeps: number[] = [];
    let now = 1_000;
    const fetcher = createLarkCliFetch(
      async (argv) => {
        calls.push(argv);
        return `Found 1 node(s)\n${JSON.stringify({ ok: true, data: { items: [] } })}`;
      },
      async (milliseconds) => {
        sleeps.push(milliseconds);
        now += milliseconds;
      },
      () => now,
    );
    await fetcher(
      "https://open.larksuite.com/open-apis/wiki/v2/spaces/space_1/nodes?page_size=50",
      { method: "GET" },
    );
    await fetcher(
      "https://open.larksuite.com/open-apis/wiki/v2/spaces/space_1/nodes?page_size=50",
      { method: "GET" },
    );
    expect(calls[0]).toEqual([
      "lark-cli", "api", "GET",
      "/open-apis/wiki/v2/spaces/space_1/nodes?page_size=50",
      "--as", "user",
    ]);
    expect(sleeps).toEqual([750]);
    await expect(fetcher(
      "https://open.larksuite.com/open-apis/wiki/v2/spaces/space_1/nodes",
      { method: "POST" },
    )).rejects.toThrow("唯讀");
  });

  test("CLI/session failure exposes no command output or credential detail", async () => {
    const fetcher = createLarkCliFetch(async () => {
      throw new Error("token secret-never-print");
    });
    await expect(fetcher(
      "https://open.larksuite.com/open-apis/wiki/v2/spaces/space_1",
      { method: "GET" },
    )).rejects.toThrow("user session");
  });
});

describe("OAuth and Secret Manager lifecycle", () => {
  test("authorization is localhost, PKCE, exact six readonly scopes and secure pending", () => {
    const pending = join(root(), "runtime", "pending.json");
    const url = new URL(createMirrorAuthorization("cli_test", pending));
    expect(url.searchParams.get("redirect_uri")).toBe(MIRROR_REDIRECT_URI);
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("scope")?.split(" ").sort()).toEqual([...MIRROR_SCOPES]);
    expect(MIRROR_SCOPES).toHaveLength(6);
    expect(statSync(pending).mode & 0o777).toBe(0o600);
  });

  test("callback checks user and stores tokens only in Secret Manager envelope", async () => {
    const pending = join(root(), "runtime", "pending.json");
    const auth = new URL(createMirrorAuthorization("cli_test", pending));
    const state = auth.searchParams.get("state")!;
    const secrets = new MemorySecrets();
    let calls = 0;
    await finishMirrorAuthorization({
      callbackUrl: `${MIRROR_REDIRECT_URI}?code=one-time&state=${state}`,
      appId: "cli_test",
      appSecret: "app-secret",
      expectedUserId: "rabbit",
      pendingPath: pending,
      secrets,
      fetch: async () => ++calls === 1
        ? response({
          access_token: "access-never-stored",
          refresh_token: "refresh-new",
          refresh_token_expires_in: 2_592_000,
          expires_in: 7200,
          scope: MIRROR_SCOPES,
        })
        : response({ data: { user_id: "rabbit" } }),
    });
    expect(secrets.values).toHaveLength(1);
    expect(secrets.values[0]).toContain("refresh-new");
    expect(secrets.values[0]).toContain("access-never-stored");
    expect(secrets.values[0]).not.toContain("app-secret");
    expect(existsSync(pending)).toBeFalse();
  });

  test("refresh rotates to a new immutable version before returning access", async () => {
    const secrets = new MemorySecrets(JSON.stringify(envelope()));
    const alerts = new Alerts();
    const result = await refreshAccessToken({
      appId: "id",
      appSecret: "secret",
      expectedUserId: "rabbit",
      secrets,
      alerts,
      lockPath: lockPath(),
      fetch: async () => response({
        access_token: "access-new",
        refresh_token: "refresh-new",
        refresh_token_expires_in: 2_592_000,
        expires_in: 7200,
        scope: MIRROR_SCOPES,
      }),
    });
    expect(result.accessToken).toBe("access-new");
    expect(secrets.values).toHaveLength(2);
    expect(JSON.parse(secrets.values[1]!).generation).toBe(2);
    expect(alerts.records).toHaveLength(0);
  });

  test("refresh failure alerts and never writes a version", async () => {
    const secrets = new MemorySecrets(JSON.stringify(envelope()));
    const alerts = new Alerts();
    await expect(refreshAccessToken({
      appId: "id",
      appSecret: "secret",
      expectedUserId: "rabbit",
      secrets,
      alerts,
      lockPath: lockPath(),
      fetch: async () => response({ code: 99991669 }, 401),
    })).rejects.toThrow("失效");
    expect(secrets.values).toHaveLength(1);
    expect(alerts.records.some((record) => record.kind === "refresh_failed")).toBeTrue();
  });

  test("GCP persistence failure leaves old version byte-identical, alerts, and withholds access", async () => {
    const original = JSON.stringify(envelope());
    const secrets = new MemorySecrets(original);
    secrets.failWrite = true;
    const alerts = new Alerts();
    await expect(refreshAccessToken({
      appId: "id",
      appSecret: "secret",
      expectedUserId: "rabbit",
      secrets,
      alerts,
      lockPath: lockPath(),
      fetch: async () => response({
        access_token: "must-not-return",
        refresh_token: "rotated-but-not-persisted",
        refresh_token_expires_in: 2_592_000,
        expires_in: 7200,
        scope: MIRROR_SCOPES,
      }),
    })).rejects.toThrow("未能持久化");
    expect(secrets.values).toEqual([original]);
    expect(alerts.records.at(-1)?.message).toContain("回存 GCP 失敗");
  });

  test("concurrent callers rotate one-time refresh token only once", async () => {
    const secrets = new MemorySecrets(JSON.stringify(envelope()));
    const alerts = new Alerts();
    const lock = lockPath();
    let refreshes = 0;
    const args = {
      appId: "id",
      appSecret: "secret",
      expectedUserId: "rabbit",
      secrets,
      alerts,
      lockPath: lock,
      fetch: async () => {
        refreshes++;
        await Bun.sleep(30);
        return response({
          access_token: "access-new",
          refresh_token: "refresh-new",
          refresh_token_expires_in: 2_592_000,
          expires_in: 7200,
          scope: MIRROR_SCOPES,
        });
      },
    };
    expect((await Promise.all([refreshAccessToken(args), refreshAccessToken(args)]))
      .map((result) => result.accessToken)).toEqual(["access-new", "access-new"]);
    expect(refreshes).toBe(1);
    expect(secrets.values).toHaveLength(2);
  });

  test("malformed or extra scopes are rejected before persistence", () => {
    expect(() => parseEnvelope(JSON.stringify(envelope({
      scope: [...MIRROR_SCOPES, "docs:document:write"],
    })), "rabbit")).toThrow("唯讀");
  });
});

describe("whitelist discovery and read-only boundary", () => {
  test("missing/empty whitelist fails closed", () => {
    expect(() => validateConfig({ ...config, wiki_spaces: [], drive_folders: [] }))
      .toThrow("fail-closed");
    expect(() => validateConfig({ ...config, wiki_spaces: ["../all"] })).toThrow("設定無效");
    expect(() => validateConfig({
      ...config,
      wiki_spaces: ["7588585813969997332"],
    })).toThrow("設定無效");
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
        return response({ data: { space_id: testSpace, name: "NOXCAT" } });
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
    expect(methods.every((method) => method === "GET")).toBeTrue();
    expect(urls.every((url) => !url.includes("/wiki/v2/spaces?"))).toBeTrue();
    expect(urls.filter((url) => url.includes("/nodes")).length).toBe(1);
    expect(urls.some((url) => url.includes("folder_token=folder_1"))).toBeTrue();
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
        ? response({ code: 0, data: { space_id: testSpace, name: "NOXCAT" } })
        : response({ code: 0, data: { items: [], has_more: false } }),
    })).rejects.toThrow("code=0");
  });
});

describe("Markdown mirror and incremental state", () => {
  test("sensitive scanner returns categories, never matched values", () => {
    expect(scanSensitiveContent([
      "-----BEGIN PRIVATE KEY-----",
      "wallet 0x1111111111111111111111111111111111111111",
      "api sk-1234567890abcdefghijklmn",
      "password: hunter2",
      "budget 2,500 USDT",
    ].join("\n"))).toEqual([
      "private_key", "wallet_address", "api_key", "credential", "financial_amount",
    ]);
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

  test("first sync writes+ingests; unchanged second sync does neither", async () => {
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
    const ingested: string[] = [];
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
      ingest: async (path: string) => { ingested.push(path); },
      now: "2026-07-27T01:00:00.000Z",
    };
    const first = await mirrorSources(args);
    const second = await mirrorSources(args);
    expect(first.written).toBe(1);
    expect(second.skipped).toBe(1);
    expect(ingested).toHaveLength(1);
    const markdown = readFileSync(first.paths[0]!, "utf8");
    expect(markdown).toContain("  - Child");
    expect(markdown).toContain("```ts");
    expect(markdown).toContain("| Value |");
  });

  test("sensitive body is quarantined as metadata only and never written or ingested", async () => {
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
          page: { elements: [{ text_run: { content: "password: hunter2" } }] },
        }], has_more: false } }),
      ingest: async () => { ingested++; },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result.quarantined).toBe(1);
    expect(result.written).toBe(0);
    expect(ingested).toBe(0);
    const state = readFileSync(statePath, "utf8");
    expect(state).toContain("credential");
    expect(state).not.toContain("hunter2");
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
      ingest: async () => { ingested++; },
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
      ingest: async () => { ingested++; },
      now: "2026-07-27T01:00:00.000Z",
    });
    expect(result).toEqual({
      written: 0,
      skipped: 0,
      metadataOnly: 1,
      quarantined: 0,
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
      ingest: async () => { ingested++; },
    })).rejects.toThrow("symlink");
    expect(ingested).toBe(0);
    expect(existsSync(join(outside, "Doc--Token_1.md"))).toBeFalse();
  });
});

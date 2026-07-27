import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
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
import { ingest } from "../bin/lark-mirror.ts";
import {
  chmodSync,
  closeSync,
  existsSync,
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

function writeSpawnFixture(testRoot: string): {
  configPath: string;
  home: string;
  path: string;
  relay: string;
} {
  const bin = join(testRoot, "bin");
  const home = join(testRoot, "home");
  const relay = join(testRoot, "relay");
  mkdirSync(bin);
  mkdirSync(home);
  const cliPath = join(bin, "lark-cli");
  writeFileSync(cliPath, `#!/bin/sh
set -eu
if [ -z "\${HOME:-}" ]; then
  echo "HOME missing" >&2
  exit 42
fi
if [ -n "\${SPAWN_ENV_CANARY:-}" ]; then
  echo "unexpected parent environment leak" >&2
  exit 44
fi
if [ -n "\${MEMOCEAN_DATA_DIR:-}" ]; then
  echo "unexpected MemOcean environment leak into lark-cli" >&2
  exit 45
fi
printf '%s\\n' "$HOME" >> "$HOME/spawn-observed"
case "$3" in
  */wiki/v2/spaces/${testSpace})
    printf '%s\\n' '{"ok":true,"data":{"space":{"space_id":"${testSpace}","name":"spawn-stub"}}}'
    ;;
  */wiki/v2/spaces/${testSpace}/nodes*)
    printf '%s\\n' '{"ok":true,"data":{"items":[{"node_token":"WikiNode_1","obj_type":"docx","obj_token":"DocToken_1","title":"Spawn proof","obj_edit_time":"1720000000","has_child":false}],"has_more":false}}'
    ;;
  *)
    echo "unexpected endpoint: $3" >&2
    exit 43
    ;;
esac
`);
  chmodSync(cliPath, 0o755);
  const configPath = join(testRoot, "config.json");
  writeFileSync(configPath, JSON.stringify({
    ...config,
    vault_dir: join(testRoot, "vault"),
    drive_folders: [],
  }));
  return {
    configPath,
    home,
    path: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    relay,
  };
}

function writeProgressSpawnFixture(testRoot: string): ReturnType<typeof writeSpawnFixture> {
  const fixture = writeSpawnFixture(testRoot);
  const cliPath = join(fixture.path.split(":")[0]!, "lark-cli");
  writeFileSync(cliPath, `#!/bin/sh
set -eu
request="$3"
case "$request" in
  */wiki/v2/spaces/${testSpace})
    printf '%s\\n' '{"ok":true,"data":{"space":{"space_id":"${testSpace}","name":"progress-stub"}}}'
    ;;
  */wiki/v2/spaces/${testSpace}/nodes*)
    params="\${5:-{}}"
    parent="$(printf '%s' "$params" | sed -n 's/.*"parent_node_token":"ProgressNode_\\([0-9][0-9]*\\)".*/\\1/p')"
    if [ -z "$parent" ]; then
      next=1
    else
      next="$(expr "$parent" + 1)"
    fi
    printf '{"ok":true,"data":{"items":[{"node_token":"ProgressNode_%s","obj_type":"docx","obj_token":"ProgressDoc_%s","title":"Progress %s","has_child":true,"node_type":"origin"}],"has_more":false}}\\n' "$next" "$next" "$next"
    ;;
  *)
    echo "unexpected endpoint: $request" >&2
    exit 43
    ;;
esac
`);
  chmodSync(cliPath, 0o755);
  return fixture;
}

async function runMirrorList(
  fixture: ReturnType<typeof writeSpawnFixture>,
  includeHome: boolean,
): Promise<{ exit: number; stdout: string; stderr: string }> {
  const env: Record<string, string> = {
    PATH: fixture.path,
    FATQ_RELAY_DIR: fixture.relay,
    SPAWN_ENV_CANARY: "must-not-reach-lark-cli",
    MEMOCEAN_DATA_DIR: join(fixture.home, "must-not-reach-lark-cli"),
  };
  if (includeHome) env.HOME = fixture.home;
  const proc = Bun.spawn([
    process.execPath,
    join(import.meta.dir, "../bin/lark-mirror.ts"),
    "list",
    "--config",
    fixture.configPath,
  ], {
    env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [exit, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  return { exit, stdout, stderr };
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
  lark_host: "ajp9g1jn00cg.jp.larksuite.com",
};
const testSpace = APPROVED_WIKI_SPACES[0];
const realSingleSpaceResponse = {
  code: 0,
  data: {
    space: {
      space_id: testSpace,
      name: "NOXCAT",
    },
  },
};

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
      "https://open.larksuite.com/open-apis/wiki/v2/spaces/space_1/nodes?page_size=50&parent_node_token=ParentNode_1",
      { method: "GET" },
    );
    expect(calls[0]).toEqual([
      "lark-cli", "api", "GET",
      "/open-apis/wiki/v2/spaces/space_1/nodes",
      "--params", '{"page_size":"50"}',
      "--as", "user",
    ]);
    expect(calls[1]).toEqual([
      "lark-cli", "api", "GET",
      "/open-apis/wiki/v2/spaces/space_1/nodes",
      "--params", '{"page_size":"50","parent_node_token":"ParentNode_1"}',
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

  test("real spawned lark-cli receives the minimal HOME credential environment", async () => {
    const fixture = writeSpawnFixture(root());
    const result = await runMirrorList(fixture, true);
    expect(result.exit).toBe(0);
    expect(JSON.parse(result.stdout).spaces).toEqual([
      { id: testSpace, name: "spawn-stub" },
    ]);
    expect(readFileSync(join(fixture.home, "spawn-observed"), "utf8").trim().split("\n"))
      .toEqual([fixture.home, fixture.home]);
  });

  test("real spawned lark-cli fails closed when HOME is absent", async () => {
    const fixture = writeSpawnFixture(root());
    const result = await runMirrorList(fixture, false);
    expect(result.exit).not.toBe(0);
    expect(result.stderr).toContain("Lark CLI user session");
    expect(existsSync(join(fixture.home, "spawn-observed"))).toBeFalse();
  });

  test("redirected progress output survives SIGTERM during discovery", async () => {
    const testRoot = root();
    const fixture = writeProgressSpawnFixture(testRoot);
    const progressLog = join(testRoot, "progress.log");
    const stderrFd = openSync(progressLog, "w");
    const proc = Bun.spawn([
      process.execPath,
      join(import.meta.dir, "../bin/lark-mirror.ts"),
      "list",
      "--config",
      fixture.configPath,
    ], {
      env: {
        PATH: fixture.path,
        HOME: fixture.home,
        FATQ_RELAY_DIR: fixture.relay,
      },
      stdout: "ignore",
      stderr: stderrFd,
    });
    const deadline = Date.now() + 15_000;
    let observed = "";
    while (Date.now() < deadline) {
      observed = readFileSync(progressLog, "utf8");
      if (observed.includes('"parent_expansions":10')) break;
      await Bun.sleep(50);
    }
    proc.kill("SIGTERM");
    const exit = await proc.exited;
    closeSync(stderrFd);

    expect(exit).not.toBe(0);
    expect(observed).toContain("[lark-mirror] wiki-discovery");
    expect(observed).toContain('"status":"running"');
    expect(observed).toContain('"parent_expansions":10');
    expect(readFileSync(progressLog, "utf8")).toContain('"parent_expansions":10');
  }, 20_000);
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
    delete process.env.MEMOCEAN_DATA_DIR;
    process.env.HOME = fixture.emptyHome;
    try {
      await expect(ingest(fixture.documentPath)).rejects.toThrow();
    } finally {
      if (previousDataDir === undefined) delete process.env.MEMOCEAN_DATA_DIR;
      else process.env.MEMOCEAN_DATA_DIR = previousDataDir;
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    const db = new Database(join(fixture.dataDir, "memory.db"), { readonly: true });
    expect(db.query("SELECT count(*) AS count FROM radar").get()).toEqual({ count: 0 });
    db.close();
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
      ingest: async () => { ingested++; return radarInserted(); },
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

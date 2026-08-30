#!/usr/bin/env bun
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  renameSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import {
  DEFAULT_CONFIG_PATH,
  createRateLimitedLarkFetch,
  discoverSources,
  listVisibleWikiSpaces,
  loadConfig,
  mirrorSources,
  summarizeSpaceFilter,
  type AlertSink,
  type LarkMirrorConfig,
  type MirrorTransportProvider,
  type RadarIngestResult,
} from "./lark-mirror-lib.ts";
import {
  LarkDocError,
  getTenantAccessToken,
  loadLarkTenantCredentials,
  redact,
  type FetchLike,
  type LarkTenantCredentials,
} from "./lark-doc-lib.ts";

const RELAY_DIR = process.env.FATQ_RELAY_DIR
  ?? "/home/oldrabbit/.claude-bots/relay";

async function run(
  argv: string[],
  stdin?: string,
  additionalEnv: Record<string, string> = {},
): Promise<string> {
  // Keep child environments deliberately narrow. Callers may add only their
  // required non-secret selectors; forwarding process.env wholesale would
  // expose credentials.
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    ...additionalEnv,
  };
  if (process.env.HOME) env.HOME = process.env.HOME;
  const proc = Bun.spawn(argv, {
    stdin: stdin === undefined ? undefined : new Blob([stdin]),
    stdout: "pipe",
    stderr: "pipe",
    env,
  });
  const [stdout, stderr, exit] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exit !== 0) throw new Error(stderr);
  return stdout.trim();
}

class RelayAlerts implements AlertSink {
  async send(kind: "refresh_failed" | "refresh_expiring" | "sync_failed", message: string): Promise<void> {
    mkdirSync(RELAY_DIR, { recursive: true });
    const stamp = new Date().toISOString().replace(/[^0-9]/g, "").slice(0, 14);
    const name = `lark-mirror-${kind}-${stamp}-${process.pid}.json`;
    const path = join(RELAY_DIR, name);
    const temporary = join(RELAY_DIR, `.${name}.tmp`);
    const fd = openSync(temporary, "wx", 0o600);
    try {
      writeFileSync(fd, `${JSON.stringify({
        from_bot: "anna",
        recipient: "anya",
        text: `[LARK MIRROR ${kind}] ${message}`,
        ts: new Date().toISOString(),
      })}\n`);
    } finally {
      closeSync(fd);
    }
    renameSync(temporary, path);
  }
}

const alerts = new RelayAlerts();

export type ExecutionMode = "manual" | "scheduled";
export type FailureStage = "config" | "discovery" | "mirror";

export interface SyncFailureContext {
  executionId: string;
  failureStage: FailureStage;
  mode: ExecutionMode;
}

export async function unifiedTenantSession(args: {
  credentials?: LarkTenantCredentials;
  tokenFetch?: FetchLike;
  apiFetch?: FetchLike;
} = {}): Promise<{ provider: MirrorTransportProvider; accessToken: string }> {
  const credentials = args.credentials ?? await loadLarkTenantCredentials();
  const accessToken = await getTenantAccessToken({
    ...credentials,
    ...(args.tokenFetch ? { fetch: args.tokenFetch } : {}),
  });
  return {
    accessToken,
    provider: {
      kind: "tenant-access-token",
      fetch: createRateLimitedLarkFetch(args.apiFetch ?? fetch),
    },
  };
}

/** @deprecated Use unifiedTenantSession; retained so existing imports switch behavior safely. */
export const unifiedOAuthSession = unifiedTenantSession;

export async function ingest(
  path: string,
  relocatedFrom?: string,
  radarOnly = false,
): Promise<RadarIngestResult> {
  const script = new URL("./lark-mirror-ingest.py", import.meta.url).pathname;
  // MemOcean config otherwise falls back to ~/.memocean. Fail before spawning
  // Python so a missing selector can never open or mutate the fallback DB.
  const dataDir = process.env.MEMOCEAN_DATA_DIR?.trim();
  if (!dataDir) {
    throw new LarkDocError(
      "internal_error",
      "MEMOCEAN_DATA_DIR 未設定；已在連線 MemOcean DB 前停止",
    );
  }
  // Pass only the required data root without widening the child to process.env.
  const dataEnv = { MEMOCEAN_DATA_DIR: dataDir };
  const output = await run([
    "python3",
    script,
    path,
    ...(relocatedFrom ? ["--relocated-from", relocatedFrom] : []),
    ...(radarOnly ? ["--radar-only"] : []),
  ], undefined, dataEnv);
  const result = JSON.parse(output);
  if (result.error) throw new Error("MemOcean ingest failed");
  if (
    !["inserted", "updated"].includes(result.radar_action)
    || !Array.isArray(result.radar_duplicates_removed)
  ) {
    throw new Error("MemOcean ingest returned invalid radar accounting");
  }
  return {
    radar_action: result.radar_action,
    radar_duplicates_removed: result.radar_duplicates_removed,
  };
}

function usage(): never {
  throw new LarkDocError(
    "internal_error",
    "用法：lark-mirror list|sync [--config path] [--state path] "
      + "[--mode manual|scheduled] [--page]",
    2,
  );
}

function syncFailureDiagnostic(error: unknown): string {
  if (error instanceof Error) {
    return redact(`${error.name || "Error"}: ${error.message}`);
  }
  return redact(error);
}

export function syncFailureAlertMessage(
  error: unknown,
  context?: SyncFailureContext,
): string {
  const identity = context
    ? `execution_id=${context.executionId} failure_stage=${context.failureStage} mode=${context.mode}`
    : "execution_id=unknown failure_stage=unknown mode=unknown";
  return redact(
    `Lark mirror sync 失敗 [${identity}]：${syncFailureDiagnostic(error)}`,
  );
}

function option(args: string[], name: string, fallback: string): string {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) usage();
  args.splice(index, 2);
  return value;
}

function flag(args: string[], name: string): boolean {
  const index = args.indexOf(name);
  if (index < 0) return false;
  args.splice(index, 1);
  return true;
}

async function main(): Promise<void> {
  const args = Bun.argv.slice(2);
  const command = args.shift();
  const configPath = option(args, "--config", DEFAULT_CONFIG_PATH);
  const statePath = option(args, "--state", undefined as unknown as string);
  const modeValue = option(args, "--mode", "manual");
  if (!["manual", "scheduled"].includes(modeValue)) usage();
  const mode = modeValue as ExecutionMode;
  const pageRequested = flag(args, "--page");
  if (args.length) usage();

  if (!["list", "sync"].includes(command ?? "")) usage();
  const executionId = randomUUID();
  let failureStage: FailureStage = "config";
  try {
    const config: LarkMirrorConfig = loadConfig(configPath);
    failureStage = "discovery";
    const { provider, accessToken } = await unifiedTenantSession();
    const visibleSpaces = command === "list"
      ? await listVisibleWikiSpaces({ accessToken, fetch: provider.fetch })
      : undefined;
    const discovered = await discoverSources({
      config,
      accessToken,
      fetch: provider.fetch,
      onProgress: (progress) => {
        // A direct fd write is visible immediately even when stderr is
        // redirected to a file and the process is later terminated.
        writeSync(2, `[lark-mirror] wiki-discovery ${JSON.stringify(progress)}\n`);
      },
    });
    if (command === "list") {
      console.log(JSON.stringify({
        auth_provider: provider.kind,
        space_filter: summarizeSpaceFilter(visibleSpaces ?? [], config.wiki_spaces),
        spaces: discovered.spaces,
        excluded: discovered.excluded,
        accounting: discovered.accounting,
        unmirrored_nodes: discovered.unmirrored_nodes,
        wiki_stats: discovered.wiki_stats,
        files: discovered.sources.map(({ title, kind, source_url, last_edit_time }) =>
          ({ title, kind, source_url, last_edit_time })),
      }, null, 2));
      return;
    }
    failureStage = "mirror";
    const result = await mirrorSources({
      config,
      ...(statePath ? { statePath } : {}),
      sources: discovered.sources,
      accessToken,
      fetch: provider.fetch,
      ingest,
      expectedSourceCount: discovered.accounting.mirror_sources,
    });
    console.log(JSON.stringify({
      ...result,
      excluded: discovered.excluded,
      accounting: discovered.accounting,
      unmirrored_nodes: discovered.unmirrored_nodes,
    }));
  } catch (error) {
    const context = { executionId, failureStage, mode };
    if (mode === "scheduled" || pageRequested) {
      await alerts.send("sync_failed", syncFailureAlertMessage(error, context));
    }
    throw error;
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(syncFailureDiagnostic(error));
    process.exit(error instanceof LarkDocError ? error.exitCode : 1);
  });
}

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
import { dirname, join } from "node:path";
import {
  DEFAULT_CONFIG_PATH,
  LarkMirrorConfig,
  createLarkCliFetch,
  discoverSources,
  loadConfig,
  mirrorSources,
  type AlertSink,
  type MirrorTransportProvider,
} from "./lark-mirror-lib.ts";
import { LarkDocError, redact } from "./lark-doc-lib.ts";

const RELAY_DIR = process.env.FATQ_RELAY_DIR
  ?? "/home/oldrabbit/.claude-bots/relay";

async function run(argv: string[], stdin?: string): Promise<string> {
  // lark-cli stores its user session below HOME. Keep the child environment
  // deliberately narrow: PATH locates the CLI and HOME locates its credential
  // store; forwarding process.env wholesale would unnecessarily expose secrets.
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
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
  if (exit !== 0) throw new Error(stderr.slice(0, 300));
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

function transportProvider(): MirrorTransportProvider {
  return {
    kind: "user-cli",
    fetch: createLarkCliFetch((argv) => run(argv)),
  };
}

async function ingest(path: string): Promise<void> {
  const script = new URL("./lark-mirror-ingest.py", import.meta.url).pathname;
  const output = await run(["python3", script, path]);
  const result = JSON.parse(output);
  if (result.error) throw new Error("MemOcean ingest failed");
}

function usage(): never {
  throw new LarkDocError(
    "internal_error",
    "用法：lark-mirror list [--config path] | sync [--config path] [--state path]",
    2,
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

async function main(): Promise<void> {
  const args = Bun.argv.slice(2);
  const command = args.shift();
  const configPath = option(args, "--config", DEFAULT_CONFIG_PATH);
  const statePath = option(args, "--state", undefined as unknown as string);
  if (args.length) usage();

  if (!["list", "sync"].includes(command ?? "")) usage();
  const config: LarkMirrorConfig = loadConfig(configPath);
  try {
    const provider = transportProvider();
    const accessToken = "provided-by-lark-cli";
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
        spaces: discovered.spaces,
        excluded: discovered.excluded,
        wiki_stats: discovered.wiki_stats,
        files: discovered.sources.map(({ title, kind, source_url, last_edit_time }) =>
          ({ title, kind, source_url, last_edit_time })),
      }, null, 2));
      return;
    }
    const result = await mirrorSources({
      config,
      ...(statePath ? { statePath } : {}),
      sources: discovered.sources,
      accessToken,
      fetch: provider.fetch,
      ingest,
    });
    console.log(JSON.stringify({ ...result, excluded: discovered.excluded }));
  } catch (error) {
    await alerts.send(
      "sync_failed",
      "Lark CLI user auth/續期、知識庫讀取、敏感掃描、文件鏡射或 MemOcean ingest 失敗，已停止本輪",
    );
    throw error;
  }
}

main().catch((error) => {
  const known = error instanceof LarkDocError ? error : new LarkDocError("internal_error", "lark-mirror 執行失敗");
  console.error(redact(known.message));
  process.exit(known.exitCode);
});

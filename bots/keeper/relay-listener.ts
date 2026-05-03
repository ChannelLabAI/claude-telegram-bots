#!/usr/bin/env bun
// relay-listener.ts — Diana persistent relay daemon
// Watches ~/.claude-bots/relay/ for diana:batch / diana:urgent signals.
// Launched via: bash start.sh (tmux session "diana")

import { watch } from "node:fs";
import { readdir, readFile, mkdir, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";

const RELAY_DIR = join(import.meta.dir, "../../relay");
const RELAY_READ_DIR = join(RELAY_DIR, "read");
const BATCH_SCRIPT = join(import.meta.dir, "keeper-batch.ts");

const SIGNALS = ["diana:batch", "diana:urgent"] as const;
type Signal = typeof SIGNALS[number];

// ── Logging ───────────────────────────────────────────────────────────────────

function log(msg: string): void {
  const ts = new Date().toISOString();
  process.stderr.write(`[diana ${ts}] ${msg}\n`);
}

// ── Relay file processing ─────────────────────────────────────────────────────

async function ensureReadDir(): Promise<void> {
  await mkdir(RELAY_READ_DIR, { recursive: true });
}

async function processRelayFile(filePath: string): Promise<void> {
  if (!filePath.endsWith(".json")) return;
  if (filePath.includes(".read-by-")) return;

  let text = "";
  try {
    const raw = await readFile(filePath, "utf8");
    const msg = JSON.parse(raw);
    text = typeof msg.text === "string" ? msg.text : "";
  } catch {
    return;
  }

  const matched = SIGNALS.find(s => text.includes(s));
  if (!matched) return;

  log(`signal received: ${matched} from ${filePath}`);

  await ensureReadDir();
  const destName = join(RELAY_READ_DIR, filePath.split("/").pop()!);
  try {
    await rename(filePath, destName);
  } catch {
    log(`WARN: could not move ${filePath} to read/, skipping`);
    return;
  }

  await triggerBatch(matched);
}

async function triggerBatch(signal: Signal): Promise<void> {
  const args = signal === "diana:urgent" ? ["--urgent"] : [];
  log(`triggering keeper-batch.ts ${args.join(" ")}`);

  const proc = spawn("bun", ["run", BATCH_SCRIPT, ...args], {
    cwd: import.meta.dir,
    stdio: "inherit",
    detached: false,
  });

  await new Promise<void>((resolve) => {
    proc.on("close", (code) => {
      log(`keeper-batch.ts exited with code ${code}`);
      resolve();
    });
  });
}

// ── Dedup set — M1: no debounce, direct call; N2: hourly clear ───────────────

const _seenFiles = new Set<string>();

// N2: prevent unbounded growth in long-running daemon
setInterval(() => {
  _seenFiles.clear();
  log("_seenFiles cleared (hourly maintenance)");
}, 60 * 60 * 1000);

function scheduleProcess(filePath: string): void {
  // M1: _seenFiles guards against double-processing; no debounce needed.
  // Debounce would swallow signals arriving within the same window.
  if (_seenFiles.has(filePath)) return;
  _seenFiles.add(filePath);
  processRelayFile(filePath).catch(err =>
    log(`error processing ${filePath}: ${String(err)}`)
  );
}

// ── Initial scan ──────────────────────────────────────────────────────────────

async function initialScan(): Promise<void> {
  if (!existsSync(RELAY_DIR)) {
    log(`relay dir not found: ${RELAY_DIR}`);
    return;
  }
  const files = await readdir(RELAY_DIR).catch(() => [] as string[]);
  for (const f of files) {
    if (f.endsWith(".json") && !f.includes(".read-by-")) {
      scheduleProcess(join(RELAY_DIR, f));
    }
  }
}

// ── fs.watch with polling fallback ────────────────────────────────────────────

async function startWatcher(): Promise<void> {
  await mkdir(RELAY_DIR, { recursive: true });
  log(`watching relay dir: ${RELAY_DIR}`);

  try {
    watch(RELAY_DIR, { persistent: true }, (event, filename) => {
      if (filename && !filename.includes(".read-by-")) {
        scheduleProcess(join(RELAY_DIR, filename));
      }
    });
    log("fs.watch active");
  } catch (err) {
    log(`WARN: fs.watch failed: ${String(err)}, relying on polling only`);
  }

  // Polling fallback: 10s scan handles null-filename edge cases
  setInterval(async () => {
    const files = await readdir(RELAY_DIR).catch(() => [] as string[]);
    for (const f of files) {
      if (f.endsWith(".json") && !f.includes(".read-by-")) {
        scheduleProcess(join(RELAY_DIR, f));
      }
    }
  }, 10_000);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log("=== Diana relay-listener starting ===");
  log(`relay dir: ${RELAY_DIR}`);
  log(`batch script: ${BATCH_SCRIPT}`);

  await initialScan();
  await startWatcher();

  log("Diana is listening. Waiting for signals...");
}

main().catch(err => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});

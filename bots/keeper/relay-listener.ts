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
  // Only process .json files
  if (!filePath.endsWith(".json")) return;
  // Skip already-processed marker files
  if (filePath.includes(".read-by-")) return;

  let text = "";
  try {
    const raw = await readFile(filePath, "utf8");
    const msg = JSON.parse(raw);
    text = typeof msg.text === "string" ? msg.text : "";
  } catch {
    return; // not valid JSON or unreadable — skip
  }

  const matched = SIGNALS.find(s => text.includes(s));
  if (!matched) return;

  log(`signal received: ${matched} from ${filePath}`);

  // Move relay file to read/ before triggering (prevents re-trigger)
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

// ── Initial scan (handle signals written before daemon started) ───────────────

async function initialScan(): Promise<void> {
  if (!existsSync(RELAY_DIR)) {
    log(`relay dir not found: ${RELAY_DIR}`);
    return;
  }
  const files = await readdir(RELAY_DIR).catch(() => [] as string[]);
  for (const f of files) {
    if (f.endsWith(".json") && !f.includes(".read-by-")) {
      await processRelayFile(join(RELAY_DIR, f));
    }
  }
}

// ── fs.watch with polling fallback ────────────────────────────────────────────

const _seenFiles = new Set<string>();
let _processTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleProcess(filePath: string): void {
  if (_seenFiles.has(filePath)) return;
  _seenFiles.add(filePath);
  if (_processTimer) clearTimeout(_processTimer);
  _processTimer = setTimeout(() => {
    _processTimer = null;
    processRelayFile(filePath).catch(err => log(`error processing ${filePath}: ${String(err)}`));
  }, 500); // debounce 500ms
}

async function startWatcher(): Promise<void> {
  await mkdir(RELAY_DIR, { recursive: true });
  log(`watching relay dir: ${RELAY_DIR}`);

  // Primary: fs.watch
  try {
    watch(RELAY_DIR, { persistent: true }, (event, filename) => {
      if (filename && !filename.includes(".read-by-")) {
        const full = join(RELAY_DIR, filename);
        scheduleProcess(full);
      }
    });
    log("fs.watch active");
  } catch (err) {
    log(`WARN: fs.watch failed: ${String(err)}, relying on polling only`);
  }

  // Polling fallback: scan every 10s (handles null-filename edge cases)
  setInterval(async () => {
    const files = await readdir(RELAY_DIR).catch(() => [] as string[]);
    for (const f of files) {
      if (f.endsWith(".json") && !f.includes(".read-by-")) {
        const full = join(RELAY_DIR, f);
        if (!_seenFiles.has(full)) {
          scheduleProcess(full);
        }
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
  // Keep alive — the process stays alive via fs.watch / setInterval
}

main().catch(err => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});

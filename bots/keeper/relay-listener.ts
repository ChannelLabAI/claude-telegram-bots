#!/usr/bin/env bun
// relay-listener.ts — Diana persistent relay daemon
// Watches ~/.claude-bots/relay-diana/ for diana:* event signals.
// Also drains legacy relay/ during cutover (drain mode — Commit B of 245f).
// Launched via: bash start.sh (tmux session "diana")

import { watch } from "node:fs";
import { readdir, readFile, mkdir, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, basename } from "node:path";
import { spawn } from "node:child_process";

// Primary: relay-diana/ — pure diana:* event signal bus
const RELAY_DIR = join(import.meta.dir, "../../relay-diana");
const RELAY_READ_DIR = join(RELAY_DIR, "read");

// Legacy drain: relay/ — @mention routing bus; keep reading until no new diana:* signals (Commit C removes this)
const RELAY_LEGACY_DIR = join(import.meta.dir, "../../relay");
const RELAY_LEGACY_READ_DIR = join(RELAY_LEGACY_DIR, "read");
const BATCH_SCRIPT = join(import.meta.dir, "keeper-batch.ts");
const ANALYZE_SCRIPT = join(import.meta.dir, "diana-analyze.ts");
const VAULT_MANAGE_SCRIPT = join(import.meta.dir, "vault-manage.ts");
const TASK_SCRIPT = join(import.meta.dir, "diana-task.ts");
const QUERY_SCRIPT = join(import.meta.dir, "diana-query.ts");

const SIGNALS = ["diana:batch", "diana:urgent", "diana:analyze", "diana:vault-manage", "diana:task", "diana:query", "diana:ingest"] as const;
type Signal = typeof SIGNALS[number];

// ── Logging ───────────────────────────────────────────────────────────────────

function log(msg: string): void {
  const ts = new Date().toISOString();
  process.stderr.write(`[diana ${ts}] ${msg}\n`);
}

// ── Relay file processing ─────────────────────────────────────────────────────

async function ensureReadDir(readDir: string = RELAY_READ_DIR): Promise<void> {
  await mkdir(readDir, { recursive: true });
}

function getReadDir(filePath: string): string {
  return filePath.startsWith(RELAY_DIR) ? RELAY_READ_DIR : RELAY_LEGACY_READ_DIR;
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

  const readDir = getReadDir(filePath);
  await ensureReadDir(readDir);
  const destName = join(readDir, filePath.split("/").pop()!);
  try {
    await rename(filePath, destName);
  } catch {
    log(`WARN: could not move ${filePath} to read/, skipping`);
    return;
  }

  await triggerBatch(matched, destName);
}

async function triggerBatch(signal: Signal, destName?: string): Promise<void> {
  let script: string;
  let args: string[] = [];
  if (signal === "diana:query") {
    script = QUERY_SCRIPT;
    args = destName ? [destName] : [];
  } else if (signal === "diana:task") {
    script = TASK_SCRIPT;
    args = destName ? [destName] : [];
  } else if (signal === "diana:analyze") {
    script = ANALYZE_SCRIPT;
  } else if (signal === "diana:vault-manage") {
    script = VAULT_MANAGE_SCRIPT;
  } else if (signal === "diana:ingest") {
    // Lightweight incremental batch triggered by assistant Stop push
    // Same as diana:batch but signals event-driven ingestion (not nightly maintenance)
    script = BATCH_SCRIPT;
    args = ["--ingest-trigger"];
  } else {
    script = BATCH_SCRIPT;
    if (signal === "diana:urgent") args = ["--urgent"];
  }
  log(`triggering script for signal: ${signal}`);

  const proc = spawn("bun", ["run", script, ...args], {
    cwd: import.meta.dir,
    stdio: "inherit",
    detached: false,
  });

  await new Promise<void>((resolve) => {
    proc.on("close", (code) => {
      log(`${basename(script)} exited with code ${code}`);
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

async function scanDir(dir: string): Promise<void> {
  if (!existsSync(dir)) return;
  const files = await readdir(dir).catch(() => [] as string[]);
  for (const f of files) {
    if (f.endsWith(".json") && !f.includes(".read-by-")) {
      scheduleProcess(join(dir, f));
    }
  }
}

async function initialScan(): Promise<void> {
  // Primary: relay-diana/ (new signal bus)
  await scanDir(RELAY_DIR);
  // Legacy drain: relay/ (pick up any diana:* signals written before Commit A cutover)
  await scanDir(RELAY_LEGACY_DIR);
}

// ── fs.watch with polling fallback ────────────────────────────────────────────

async function watchDir(dir: string): Promise<void> {
  await mkdir(dir, { recursive: true });
  log(`watching: ${dir}`);
  try {
    watch(dir, { persistent: true }, (event, filename) => {
      if (filename && !filename.includes(".read-by-")) {
        scheduleProcess(join(dir, filename));
      }
    });
  } catch (err) {
    log(`WARN: fs.watch failed for ${dir}: ${String(err)}, relying on polling`);
  }
}

async function startWatcher(): Promise<void> {
  // Watch both dirs (drain mode: primary + legacy)
  await watchDir(RELAY_DIR);
  await watchDir(RELAY_LEGACY_DIR);
  log("fs.watch active (relay-diana + relay legacy drain)");

  // Polling fallback: 10s scan handles null-filename edge cases
  setInterval(async () => {
    await scanDir(RELAY_DIR);
    await scanDir(RELAY_LEGACY_DIR);
  }, 10_000);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log("=== Diana relay-listener starting ===");
  log(`relay dir (primary): ${RELAY_DIR}`);
  log(`relay dir (legacy drain): ${RELAY_LEGACY_DIR}`);
  log(`batch script: ${BATCH_SCRIPT}`);

  await initialScan();
  await startWatcher();

  log("Diana is listening. Waiting for signals...");
}

main().catch(err => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});

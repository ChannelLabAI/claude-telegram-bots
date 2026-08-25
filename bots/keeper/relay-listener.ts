#!/usr/bin/env bun
// relay-listener.ts — Diana persistent relay daemon
// Watches ~/.claude-bots/relay-diana/ for diana:* event signals.
// Launched via: bash start.sh (tmux session "diana")

import { watch } from "node:fs";
import { readdir, readFile, mkdir, rename, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { join, basename } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { Database } from "bun:sqlite";

// relay-diana/ — pure diana:* event signal bus (split from relay/ @mention bus in 245f)
const RELAY_DIR = process.env.DIANA_RELAY_DIR ?? join(import.meta.dir, "../../relay-diana");
const RELAY_READ_DIR = join(RELAY_DIR, "read");
const DIANA_CHAT_INBOX_DIR = process.env.DIANA_CHAT_INBOX_DIR
  ?? join(import.meta.dir, "../diana/inbox/messages");
const BATCH_SCRIPT = join(import.meta.dir, "keeper-batch.ts");
const ANALYZE_SCRIPT = join(import.meta.dir, "diana-analyze.ts");
const VAULT_MANAGE_SCRIPT = join(import.meta.dir, "vault-manage.ts");
const TASK_SCRIPT = join(import.meta.dir, "diana-task.ts");
const QUERY_SCRIPT = join(import.meta.dir, "diana-query.ts");

const SIGNALS = ["diana:batch", "diana:urgent", "diana:analyze", "diana:vault-manage", "diana:task", "diana:query", "diana:ingest"] as const;
type Signal = typeof SIGNALS[number];

// ── Circuit Breaker ───────────────────────────────────────────────────────────

const DB_PATH = join(import.meta.dir, "../../memory.db");
const CB_WINDOW_MS = 10 * 60 * 1000; // 10-minute rolling window
const CB_THRESHOLD = 10;              // max keeper-batch spawns in window
const CB_COOLDOWN_MS = 60 * 1000;    // min 60s between spawns
const TG_CHAT_ID = "1050312492";

let lastBatchSpawnAt = 0;

function loadTgToken(): string {
  try {
    const r = spawnSync("gcloud", ["secrets", "versions", "access", "latest", "--secret=tg-token-diana", "--project=channellab-prod"], { encoding: "utf-8", timeout: 10000 });
    if (r.status === 0 && r.stdout.trim().length > 0) return r.stdout.trim();
  } catch {}
  const envPaths = [join(import.meta.dir, "../../.env"), join(import.meta.dir, "../../bots/anya/.env"), "/home/oldrabbit/.env"];
  for (const p of envPaths) {
    if (!existsSync(p)) continue;
    try {
      for (const line of readFileSync(p, "utf-8").split("\n")) {
        const m = line.match(/^(?:TG_TOKEN_DIANA|TELEGRAM_BOT_TOKEN_DIANA)\s*=\s*(.+)$/);
        if (m) { const v = m[1].trim().replace(/\s+#.*$/, "").replace(/^["']|["']$/g, ""); if (v) return v; }
      }
    } catch {}
  }
  return process.env["TG_TOKEN_DIANA"] ?? process.env["TELEGRAM_BOT_TOKEN_DIANA"] ?? "";
}

async function sendTgAlert(text: string): Promise<void> {
  const token = loadTgToken();
  if (!token) { log("WARN: TG token unavailable, cannot send CB alert"); return; }
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: TG_CHAT_ID, text }),
    });
  } catch (err) {
    log(`WARN: TG alert failed: ${String(err)}`);
  }
}

function openCbDb(): Database {
  const db = new Database(DB_PATH);
  db.exec("PRAGMA busy_timeout=3000");
  db.exec(`CREATE TABLE IF NOT EXISTS circuit_breaker_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    ts TEXT NOT NULL,
    acked INTEGER DEFAULT 0
  )`);
  return db;
}

function getRecentSpawnCount(db: Database): number {
  const cutoff = new Date(Date.now() - CB_WINDOW_MS).toISOString();
  const row = db.query<{ cnt: number }, [string]>(
    `SELECT COUNT(*) as cnt FROM circuit_breaker_state WHERE event_type = 'batch_spawn' AND acked = 0 AND ts >= ?`
  ).get(cutoff);
  return row?.cnt ?? 0;
}

function recordSpawnEvent(db: Database): void {
  db.run(`INSERT INTO circuit_breaker_state (event_type, ts, acked) VALUES ('batch_spawn', ?, 0)`, [new Date().toISOString()]);
}

// Manual ack: run this SQL to reset circuit breaker after investigating:
//   sqlite3 ~/.claude-bots/memory.db "UPDATE circuit_breaker_state SET acked=1 WHERE event_type='batch_spawn' AND acked=0"

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
  let msg: Record<string, unknown> = {};
  try {
    const raw = await readFile(filePath, "utf8");
    msg = JSON.parse(raw);
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

  if (msg.route === "diana-chat") {
    await routeToDianaChat(msg, destName);
  } else {
    await triggerBatch(matched, destName);
  }
}

async function routeToDianaChat(msg: Record<string, unknown>, sourcePath: string): Promise<void> {
  await mkdir(DIANA_CHAT_INBOX_DIR, { recursive: true });
  const meta = typeof msg.meta === "object" && msg.meta !== null ? msg.meta : {};
  const payload = {
    params: {
      content: String(msg.text ?? ""),
      meta: { source: "relay-listener", relay_file: basename(sourcePath), ...meta },
    },
  };
  const path = join(DIANA_CHAT_INBOX_DIR, `pm-monitor-${Date.now()}-${process.pid}.json`);
  const tmp = `${path}.tmp`;
  await writeFile(tmp, JSON.stringify(payload) + "\n", { encoding: "utf8", mode: 0o600, flag: "wx" });
  await rename(tmp, path);
  log(`routed ${basename(sourcePath)} to diana-chat inbox`);
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
  // Circuit breaker: only gates keeper-batch spawns (not analyze/vault-manage/task/query)
  if (script === BATCH_SCRIPT) {
    const now = Date.now();
    if (now - lastBatchSpawnAt < CB_COOLDOWN_MS) {
      log(`CB: cooldown active (${Math.round((now - lastBatchSpawnAt) / 1000)}s since last spawn), skipping signal ${signal}`);
      return;
    }
    const db = openCbDb();
    const count = getRecentSpawnCount(db);
    if (count >= CB_THRESHOLD) {
      log(`CB: OPEN — ${count} spawns in last 10min (threshold ${CB_THRESHOLD}), blocking keeper-batch`);
      db.close();
      await sendTgAlert(`🔴 [Diana 斷路器] keeper-batch 異常\n10分鐘內已 spawn ${count} 次（閾值 ${CB_THRESHOLD}），已自動停止。\n請手動確認後執行以下 SQL 恢復：\nsqlite3 ~/.claude-bots/memory.db "UPDATE circuit_breaker_state SET acked=1 WHERE event_type='batch_spawn' AND acked=0"`);
      return;
    }
    recordSpawnEvent(db);
    lastBatchSpawnAt = now;
    db.close();
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
  await scanDir(RELAY_DIR);
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
  await watchDir(RELAY_DIR);
  log("fs.watch active");

  // Polling fallback: 10s scan handles null-filename edge cases
  setInterval(async () => {
    await scanDir(RELAY_DIR);
  }, 10_000);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  if (process.argv[2] === "--process-once") {
    const file = process.argv[3];
    if (!file) throw new Error("--process-once requires a relay file");
    await processRelayFile(file);
    process.exit(0);
  }

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

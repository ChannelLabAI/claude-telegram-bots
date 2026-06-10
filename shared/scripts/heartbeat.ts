#!/usr/bin/env bun
// heartbeat.ts — Diana P0 Health Monitor
// Zero LLM. No import anthropic. No ANTHROPIC_API_KEY usage.
// Uses: bun:sqlite, node:child_process, node:fs, node:path, fetch (Telegram API)

import { Database } from "bun:sqlite";
import { spawnSync } from "node:child_process";
import { statSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// ── Config ────────────────────────────────────────────────────────────────────

const DB_PATH = join(import.meta.dir, "../../memory.db");
const SEABED_PATH = join(import.meta.dir, "../../seabed/chats.clsc.md");
const TG_CHAT_ID = "1050312492";
const DRY_RUN = process.argv.includes("--dry-run");

// INJECT_RED: HEARTBEAT_INJECT_RED=S1,S3 forces those signals to RED (testing)
const INJECT_RED = (process.env["HEARTBEAT_INJECT_RED"] ?? "").split(",").filter(Boolean);

// ── Telegram ──────────────────────────────────────────────────────────────────

function loadTgToken(): string {
  // Layer 1: GCP Secret Manager
  try {
    const result = spawnSync(
      "gcloud",
      ["secrets", "versions", "access", "latest", "--secret=tg-token-anya", "--project=channellab-prod"],
      { encoding: "utf-8", timeout: 10000 }
    );
    if (result.status === 0 && result.stdout.trim().length > 0) {
      return result.stdout.trim();
    }
  } catch {}

  // Layer 2: .env files (check known locations)
  const envPaths = [
    join(import.meta.dir, "../../.env"),
    join(import.meta.dir, "../../bots/anya/.env"),
    "/home/oldrabbit/.env",
  ];
  for (const envPath of envPaths) {
    if (!existsSync(envPath)) continue;
    try {
      const content = readFileSync(envPath, "utf-8");
      for (const line of content.split("\n")) {
        const m = line.match(/^(?:TG_TOKEN_ANYA|TELEGRAM_BOT_TOKEN_ANYA)\s*=\s*(.+)$/);
        if (m) {
          let val = m[1].trim().replace(/\s+#.*$/, "").replace(/^["']|["']$/g, "");
          if (val) return val;
        }
      }
    } catch {}
  }

  // Layer 3: process.env
  const envVal = process.env["TG_TOKEN_ANYA"] ?? process.env["TELEGRAM_BOT_TOKEN_ANYA"] ?? "";
  if (envVal) return envVal;

  console.error("[heartbeat] No TG token available — all 3 layers failed");
  return "";
}

async function sendTg(token: string, chatId: string, text: string): Promise<boolean> {
  if (!token) {
    console.error("[heartbeat] No TG token available — cannot send message");
    return false;
  }
  if (DRY_RUN) {
    console.log(`[DRY-RUN] sendTg → ${chatId}: ${text}`);
    return true;
  }
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
    const ok = res.ok;
    if (!ok) {
      const body = await res.text();
      console.error(`[heartbeat] TG send failed: ${res.status} ${body}`);
    }
    return ok;
  } catch (err) {
    console.error(`[heartbeat] TG send error: ${String(err)}`);
    return false;
  }
}

// ── Database Setup ─────────────────────────────────────────────────────────────

function openDb(): Database {
  const db = new Database(DB_PATH);
  db.exec(`
    CREATE TABLE IF NOT EXISTS health_metrics (
      ts TEXT NOT NULL,
      signal TEXT NOT NULL,
      value REAL,
      status TEXT
    )
  `);
  db.exec(`
    CREATE TABLE IF NOT EXISTS heartbeats (
      component TEXT PRIMARY KEY,
      last_ok_at TEXT,
      last_status TEXT,
      last_error TEXT,
      consecutive_failures INTEGER DEFAULT 0
    )
  `);
  db.exec(`
    CREATE TABLE IF NOT EXISTS alerts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT,
      level TEXT,
      signal TEXT,
      msg TEXT,
      acked INTEGER DEFAULT 0,
      last_notified_at TEXT
    )
  `);
  return db;
}

// ── Alert Helpers ─────────────────────────────────────────────────────────────

async function sendAlert(
  signal: string,
  msg: string,
  level: "WARN" | "CRIT",
  db: Database,
  tgToken: string
): Promise<void> {
  const now = new Date().toISOString();

  // Check throttle: find latest unacked alert for this signal
  const existing = db.query<{ id: number; last_notified_at: string | null }, []>(
    `SELECT id, last_notified_at FROM alerts WHERE signal = ? AND acked = 0 ORDER BY id DESC LIMIT 1`
  ).get(signal) as { id: number; last_notified_at: string | null } | null;

  if (existing?.last_notified_at) {
    const lastNotified = new Date(existing.last_notified_at).getTime();
    const sixHoursMs = 6 * 60 * 60 * 1000;
    if (Date.now() - lastNotified < sixHoursMs) {
      console.log(`[heartbeat] ${signal} throttled — last notified ${existing.last_notified_at}`);
      return;
    }
  }

  // Send TG
  const emoji = level === "CRIT" ? "🔴" : "🟡";
  const sent = await sendTg(tgToken, TG_CHAT_ID, `${emoji} [Diana Health] ${level} — ${signal}\n${msg}`);

  if (existing) {
    // Update existing alert — only advance last_notified_at if TG send succeeded
    // (if send failed, keep existing timestamp so throttle window doesn't advance on failure)
    db.run(
      `UPDATE alerts SET last_notified_at = ?, ts = ?, msg = ? WHERE id = ?`,
      [sent ? now : existing.last_notified_at, now, msg, existing.id]
    );
  } else {
    // Insert new alert
    db.run(
      `INSERT INTO alerts (ts, level, signal, msg, acked, last_notified_at) VALUES (?, ?, ?, ?, 0, ?)`,
      [now, level, signal, msg, sent ? now : null]
    );
  }
}

async function sendResolved(signal: string, db: Database, tgToken: string): Promise<void> {
  // Send resolved TG message
  await sendTg(tgToken, TG_CHAT_ID, `✅ [Diana Health] RESOLVED — ${signal}`);

  // Clear last_notified_at (AC requirement: so next RED fires immediately without throttle)
  db.run(
    `UPDATE alerts SET acked = 1, last_notified_at = NULL WHERE signal = ? AND acked = 0`,
    [signal]
  );
  console.log(`[heartbeat] ${signal} resolved — last_notified_at cleared`);
}

function writeMetric(db: Database, signal: string, value: number, status: "GREEN" | "AMBER" | "RED"): void {
  const now = new Date().toISOString();
  db.run(
    `INSERT INTO health_metrics (ts, signal, value, status) VALUES (?, ?, ?, ?)`,
    [now, signal, value, status]
  );
}

function hasPriorAlert(db: Database, signal: string): boolean {
  const row = db.query<{ cnt: number }, []>(
    `SELECT COUNT(*) as cnt FROM alerts WHERE signal = ? AND acked = 0`
  ).get(signal) as { cnt: number } | null;
  return (row?.cnt ?? 0) > 0;
}

// ── Checks ────────────────────────────────────────────────────────────────────

interface CheckResult {
  signal: string;
  value: number;
  status: "GREEN" | "AMBER" | "RED";
  msg: string;
  level: "WARN" | "CRIT";
}

// S1: Seabed lag — how old is the last ingest?
function checkS1SeabedLag(db: Database): CheckResult {
  let hoursSinceLast = 999;

  try {
    // Try messages table first (most recent ingest)
    const row = db.query<{ ts: string }, []>(
      `SELECT ts FROM messages ORDER BY ts DESC LIMIT 1`
    ).get() as { ts: string } | null;

    if (row?.ts) {
      hoursSinceLast = (Date.now() - new Date(row.ts).getTime()) / 3600000;
    } else {
      // Fallback: radar.encoded_at
      const rrow = db.query<{ encoded_at: string }, []>(
        `SELECT encoded_at FROM radar ORDER BY encoded_at DESC LIMIT 1`
      ).get() as { encoded_at: string } | null;
      if (rrow?.encoded_at) {
        hoursSinceLast = (Date.now() - new Date(rrow.encoded_at).getTime()) / 3600000;
      } else {
        // Final fallback: chats.clsc.md mtime
        if (existsSync(SEABED_PATH)) {
          const mtime = statSync(SEABED_PATH).mtimeMs;
          hoursSinceLast = (Date.now() - mtime) / 3600000;
        }
      }
    }
  } catch (err) {
    console.error(`[heartbeat] S1 check error: ${String(err)}`);
  }

  let status: "GREEN" | "AMBER" | "RED" =
    hoursSinceLast > 72 ? "RED" : hoursSinceLast > 24 ? "AMBER" : "GREEN";

  // INJECT_RED override
  if (INJECT_RED.includes("S1")) {
    console.log("[heartbeat] INJECT_RED: forcing S1 → RED");
    status = "RED";
  }

  return {
    signal: "S1_seabed_lag",
    value: hoursSinceLast,
    status,
    msg: `Seabed lag: ${hoursSinceLast.toFixed(1)}h since last ingest`,
    level: "CRIT",
  };
}

// S2: Cron heartbeat — check components' last_ok_at
function checkS2CronHeartbeats(db: Database): CheckResult[] {
  const results: CheckResult[] = [];
  const now = Date.now();

  // Components and their max acceptable gap (hours)
  const components: { component: string; maxHours: number; signal: string }[] = [
    { component: "keeper-batch", maxHours: 1.5, signal: "S2_cron_keeper_batch" },
    { component: "dream_cycle", maxHours: 26, signal: "S2_cron_dream_cycle" },
    { component: "stale_check", maxHours: 26, signal: "S2_cron_stale" },
    { component: "tg_ingest", maxHours: 26, signal: "S2_cron_tg_ingest" },
  ];

  for (const { component, maxHours, signal } of components) {
    let hoursSince = 999;
    try {
      const row = db.query<{ last_ok_at: string | null }, [string]>(
        `SELECT last_ok_at FROM heartbeats WHERE component = ?`
      ).get(component) as { last_ok_at: string | null } | null;

      if (row?.last_ok_at) {
        hoursSince = (now - new Date(row.last_ok_at).getTime()) / 3600000;
      }
    } catch {}

    let status: "GREEN" | "AMBER" | "RED" = hoursSince > maxHours ? "RED" : "GREEN";
    if (INJECT_RED.includes("S2")) {
      console.log(`[heartbeat] INJECT_RED: forcing ${signal} → RED`);
      status = "RED";
    }

    results.push({
      signal,
      value: hoursSince,
      status,
      msg: `${component}: ${hoursSince >= 999 ? "never recorded" : `${hoursSince.toFixed(1)}h since last ok`} (limit: ${maxHours}h)`,
      level: "CRIT",
    });
  }

  return results;
}

// S3: env/API key health (only checks, does NOT use the key)
function checkS3ApiKey(): CheckResult {
  let status: "GREEN" | "AMBER" | "RED" = "RED";
  let msg = "anthropic-api-key: unreadable from GCP Secret Manager";

  try {
    const result = spawnSync(
      "gcloud",
      ["secrets", "versions", "access", "latest", "--secret=anthropic-api-key", "--project=channellab-prod"],
      { encoding: "utf-8", timeout: 15000 }
    );
    if (result.status === 0 && result.stdout.trim().length > 0) {
      // Key is readable — do NOT store or log the value
      status = "GREEN";
      msg = "anthropic-api-key: readable from GCP (not used)";
    } else {
      msg = `anthropic-api-key: gcloud exit=${result.status} stderr=${(result.stderr ?? "").slice(0, 100)}`;
    }
  } catch (err) {
    msg = `anthropic-api-key: check error — ${String(err).slice(0, 100)}`;
  }

  if (INJECT_RED.includes("S3")) {
    console.log("[heartbeat] INJECT_RED: forcing S3 → RED");
    status = "RED";
    msg = "[injected] anthropic-api-key: forced RED by HEARTBEAT_INJECT_RED";
  }

  return {
    signal: "S3_api_key",
    value: status === "GREEN" ? 1 : 0,
    status,
    msg,
    level: "CRIT",
  };
}

// S4: disk + db health
function checkS4DiskAndDb(): CheckResult {
  let status: "GREEN" | "AMBER" | "RED" = "GREEN";
  const issues: string[] = [];

  // Disk: parse df -h /
  try {
    const dfResult = spawnSync("df", ["-h", "/"], { encoding: "utf-8", timeout: 5000 });
    if (dfResult.status === 0) {
      const lines = dfResult.stdout.trim().split("\n");
      const dataLine = lines[1];
      if (dataLine) {
        const pctMatch = dataLine.match(/(\d+)%/);
        if (pctMatch) {
          const usedPct = parseInt(pctMatch[1]);
          const freePct = 100 - usedPct;
          if (freePct < 5) {
            status = "RED";
            issues.push(`disk free: ${freePct}% (<5%)`);
          } else if (freePct < 10) {
            status = status === "RED" ? "RED" : "AMBER";
            issues.push(`disk free: ${freePct}% (<10%)`);
          }
        }
      }
    }
  } catch (err) {
    issues.push(`df error: ${String(err).slice(0, 80)}`);
  }

  // memory.db integrity
  try {
    const db2 = new Database(DB_PATH, { readonly: true });
    const row = db2.query<{ integrity_check: string }, []>("PRAGMA integrity_check").get() as { integrity_check: string } | null;
    db2.close();
    if (row?.integrity_check !== "ok") {
      status = "RED";
      issues.push(`memory.db integrity: ${row?.integrity_check ?? "unknown"}`);
    }
  } catch (err) {
    status = "RED";
    issues.push(`memory.db open error: ${String(err).slice(0, 80)}`);
  }

  if (INJECT_RED.includes("S4")) {
    console.log("[heartbeat] INJECT_RED: forcing S4 → RED");
    status = "RED";
    issues.push("[injected] S4 forced RED");
  }

  const msg = issues.length > 0 ? issues.join("; ") : "disk OK, memory.db OK";
  return {
    signal: "S4_disk_db",
    value: status === "GREEN" ? 1 : 0,
    status,
    msg,
    level: "WARN",
  };
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log(`[heartbeat] Starting — ${new Date().toISOString()} (DRY_RUN=${DRY_RUN})`);
  if (INJECT_RED.length > 0) {
    console.log(`[heartbeat] INJECT_RED active: ${INJECT_RED.join(", ")}`);
  }

  // Step 1: Open DB and ensure tables exist
  const db = openDb();

  // Step 2: Load TG token
  const tgToken = loadTgToken();
  if (!tgToken) {
    console.error("[heartbeat] WARNING: no TG token — alerts will not be delivered");
  }

  // Step 3-4: Run all checks + write health_metrics
  const s1 = checkS1SeabedLag(db);
  const s2Results = checkS2CronHeartbeats(db);
  const s3 = checkS3ApiKey();
  const s4 = checkS4DiskAndDb();

  const allChecks: CheckResult[] = [s1, ...s2Results, s3, s4];

  for (const check of allChecks) {
    writeMetric(db, check.signal, check.value, check.status);
    console.log(`[heartbeat] ${check.signal}: ${check.status} — ${check.msg}`);
  }

  // Step 5-6: For each RED signal → sendAlert; for each GREEN-recovered signal → sendResolved
  for (const check of allChecks) {
    if (check.status === "RED") {
      await sendAlert(check.signal, check.msg, check.level, db, tgToken);
    } else if (check.status === "GREEN") {
      if (hasPriorAlert(db, check.signal)) {
        await sendResolved(check.signal, db, tgToken);
      }
    }
    // AMBER: no alert, no resolved (just log)
  }

  // Step 7: AMBER signals — log only (no TG)
  const amberSignals = allChecks.filter(c => c.status === "AMBER").map(c => c.signal);
  if (amberSignals.length > 0) {
    console.log(`[heartbeat] AMBER signals (no alert): ${amberSignals.join(", ")}`);
  }

  // Step 8: Write own heartbeat
  const now = new Date().toISOString();
  db.run(
    `INSERT OR REPLACE INTO heartbeats (component, last_ok_at, last_status, last_error, consecutive_failures)
     VALUES (?, ?, 'ok', NULL, 0)`,
    ["heartbeat", now]
  );

  console.log(`[heartbeat] Done — ${now}`);
  db.close();
}

main().catch((err) => {
  console.error(`[heartbeat] FATAL: ${String(err)}`);
  process.exit(1);
});

#!/usr/bin/env bun
// heartbeat.ts — Diana P0 Health Monitor
// Zero LLM. No import anthropic. No ANTHROPIC_API_KEY usage.
// Uses: bun:sqlite, node:child_process, node:fs, node:path, fetch (Telegram API)

import { Database } from "bun:sqlite";
import { spawnSync } from "node:child_process";
import { statSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

// ── Config ────────────────────────────────────────────────────────────────────

// env 注入供 fixture 隔離（task a8d5 S6 新增）；預設維持生產值，S1-S4 既有行為不受影響
const DB_PATH = process.env["HEARTBEAT_DB_PATH"] ?? join(import.meta.dir, "../../memory.db");
const KG_DB_PATH = process.env["HEARTBEAT_KG_DB_PATH"] ?? join(import.meta.dir, "../../kg.db");
const GATEWAY_PODS_DB_DIR = process.env["HEARTBEAT_PODS_DB_DIR"] ?? join(import.meta.dir, "../../gateway-builder/pods-db");
const SEABED_PATH = join(import.meta.dir, "../../seabed/chats.clsc.md");
const TG_CHAT_ID = "1050312492";
const DRY_RUN = process.argv.includes("--dry-run");

// INJECT_RED: HEARTBEAT_INJECT_RED=S1,S3 forces those signals to RED (testing)
const INJECT_RED = (process.env["HEARTBEAT_INJECT_RED"] ?? "").split(",").filter(Boolean);

// Alert debounce: consecutive RED count must reach this before DM-ing 老兔
const DEBOUNCE_N = 2;

// S6：quick_check 對大庫耗秒級，只在低峰時段跑一次/天（避開寫入尖峰，見 crontab 04-05 時段慣例）；
// HEARTBEAT_S6_FORCE=1 略過時段閘門，供測試/手動觸發用。
const S6_LOW_PEAK_HOUR = 4;
const S6_FORCE = process.env["HEARTBEAT_S6_FORCE"] === "1";
// 測試用時鐘注入（同 fatq-cli.sh 的 FATQ_NOW_ISO 慣例），讓 S6 低峰時段閘門可決定性測試；
// 生產不設此 env，一律用真實系統時間。
function nowForS6(): Date {
  const injected = process.env["HEARTBEAT_NOW_ISO"];
  if (injected) {
    const d = new Date(injected);
    if (!isNaN(d.getTime())) return d;
  }
  return new Date();
}

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
  // busy_timeout: heartbeat (*/5 cron) 可能與 keeper-batch cron 同時碰 memory.db；
  // 無 timeout 會靜默失敗（監測系統靜默掛掉最致命）。等鎖最多 3s。（Bella hb1a NB 2026-06-17）
  db.exec("PRAGMA busy_timeout=3000");
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

// Per-signal consecutive failure tracking (uses heartbeats table, one row per signal)
function getConsecutiveFailures(db: Database, signal: string): number {
  const row = db.query<{ consecutive_failures: number }, []>(
    `SELECT consecutive_failures FROM heartbeats WHERE component = ?`
  ).get(signal) as { consecutive_failures: number } | null;
  return row?.consecutive_failures ?? 0;
}

function updateConsecutiveFailures(db: Database, signal: string, isFailure: boolean, now: string): void {
  if (isFailure) {
    // UPSERT: ON CONFLICT DO UPDATE preserves existing row data (unlike INSERT OR REPLACE which deletes first)
    db.run(
      `INSERT INTO heartbeats (component, last_ok_at, last_status, last_error, consecutive_failures)
       VALUES (?, NULL, 'fail', NULL, 1)
       ON CONFLICT(component) DO UPDATE SET
         last_status = 'fail',
         consecutive_failures = consecutive_failures + 1`,
      [signal]
    );
  } else {
    db.run(
      `INSERT INTO heartbeats (component, last_ok_at, last_status, last_error, consecutive_failures)
       VALUES (?, ?, 'ok', NULL, 0)
       ON CONFLICT(component) DO UPDATE SET
         last_ok_at = excluded.last_ok_at,
         last_status = 'ok',
         last_error = NULL,
         consecutive_failures = 0`,
      [signal, now]
    );
  }
}

// ── Checks ────────────────────────────────────────────────────────────────────

interface CheckResult {
  signal: string;
  value: number;
  status: "GREEN" | "AMBER" | "RED";
  msg: string;
  level: "WARN" | "CRIT";
  debounce?: number;  // 覆寫預設 DEBOUNCE_N；S6 用 1（低頻檢查，首次 RED 即告警，見 checkS6DbIntegrity）
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
// null status = gcloud killed by timeout signal (inconclusive) → retry once at 30s → AMBER if still null
// clean exit≠0 or zero with empty stdout = true failure → RED
function checkS3ApiKey(): CheckResult {
  let status: "GREEN" | "AMBER" | "RED" = "RED";
  let msg = "anthropic-api-key: unreadable from GCP Secret Manager";

  const GCLOUD_ARGS = ["secrets", "versions", "access", "latest", "--secret=anthropic-api-key", "--project=channellab-prod"];

  const runGcloud = (timeoutMs: number) =>
    spawnSync("gcloud", GCLOUD_ARGS, { encoding: "utf-8", timeout: timeoutMs });

  try {
    const result = runGcloud(15000);

    if (result.status === 0 && result.stdout.trim().length > 0) {
      status = "GREEN";
      msg = "anthropic-api-key: readable from GCP (not used)";
    } else if (result.status === null) {
      // Timeout (gcloud killed by signal) — retry once with extended timeout
      console.log("[heartbeat] S3 gcloud timeout (status=null), retrying with 30s timeout...");
      const retry = runGcloud(30000);
      if (retry.status === 0 && retry.stdout.trim().length > 0) {
        status = "GREEN";
        msg = "anthropic-api-key: readable from GCP after retry (not used)";
      } else if (retry.status === null) {
        // Still timing out — inconclusive, do not escalate as RED
        status = "AMBER";
        msg = "anthropic-api-key: gcloud timed out twice (inconclusive — network/gcloud slow, not a key failure)";
      } else {
        // Retry returned a clean non-zero exit → true failure
        status = "RED";
        msg = `anthropic-api-key: gcloud exit=${retry.status} on retry stderr=${(retry.stderr ?? "").slice(0, 100)}`;
      }
    } else {
      // Clean non-zero exit or zero with empty stdout → true failure
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

// S6: DB integrity — PRAGMA quick_check across memory.db/kg.db/gateway pod db（task a8d5，
// 7/6 memory.db 損毀事件的制度化補洞）。只在低峰時段跑一次/天，見 shouldRunS6 gate；
// 首次 RED 即告警（debounce=1）——這條信號本身就是「數天內沒被發現」的事故補洞，不該再等 2 次確認。
function checkS6DbIntegrity(): CheckResult {
  const targets: { label: string; path: string }[] = [];
  if (existsSync(DB_PATH)) targets.push({ label: "memory.db", path: DB_PATH });
  if (existsSync(KG_DB_PATH)) targets.push({ label: "kg.db", path: KG_DB_PATH });
  try {
    if (existsSync(GATEWAY_PODS_DB_DIR)) {
      for (const f of readdirSync(GATEWAY_PODS_DB_DIR)) {
        if (f.endsWith(".db")) targets.push({ label: `pods-db/${f}`, path: join(GATEWAY_PODS_DB_DIR, f) });
      }
    }
  } catch {}

  const failures: string[] = [];
  for (const t of targets) {
    try {
      const db2 = new Database(t.path, { readonly: true });
      const row = db2.query<{ quick_check: string }, []>("PRAGMA quick_check").get() as { quick_check: string } | null;
      db2.close();
      if (row?.quick_check !== "ok") failures.push(`${t.label}: ${row?.quick_check ?? "unknown"}`);
    } catch (err) {
      failures.push(`${t.label}: open/check error — ${String(err).slice(0, 80)}`);
    }
  }

  let status: "GREEN" | "AMBER" | "RED" = failures.length > 0 ? "RED" : "GREEN";
  let msg = failures.length > 0
    ? `quick_check 失敗 ${failures.length}/${targets.length}：${failures.join("; ").slice(0, 300)}`
    : `quick_check 全過（${targets.length} 個資料庫：${targets.map(t => t.label).join(", ")}）`;

  if (targets.length === 0) {
    status = "AMBER";
    msg = "找不到任何資料庫可檢查（DB_PATH/KG_DB_PATH/GATEWAY_PODS_DB_DIR 都不存在，設定可能有誤）";
  }

  if (INJECT_RED.includes("S6")) {
    console.log("[heartbeat] INJECT_RED: forcing S6 → RED");
    status = "RED";
    msg = "[injected] S6 forced RED by HEARTBEAT_INJECT_RED";
  }

  return {
    signal: "S6_db_integrity",
    value: targets.length - failures.length,
    status,
    msg,
    level: "CRIT",
    debounce: 1,
  };
}

// S6 gate：低峰時段（S6_LOW_PEAK_HOUR）且今天（Asia/Taipei）尚未跑過才執行；
// 用 health_metrics（每次執行不論成敗都會寫）判斷「今天跑過」，而非 heartbeats.last_ok_at
// （後者只在成功時更新，若用它當閘門，quick_check 持續失敗時反而會在整個低峰小時內每 5 分鐘重跑）。
function shouldRunS6(db: Database, now: Date): boolean {
  if (S6_FORCE) return true;
  const taipeiHour = Number(
    new Intl.DateTimeFormat("en-US", { hour: "numeric", hour12: false, timeZone: "Asia/Taipei" }).format(now)
  );
  if (taipeiHour !== S6_LOW_PEAK_HOUR) return false;
  const todayStr = now.toLocaleDateString("en-CA", { timeZone: "Asia/Taipei" });
  try {
    const row = db.query<{ ts: string }, []>(
      `SELECT ts FROM health_metrics WHERE signal = 'S6_db_integrity' ORDER BY ts DESC LIMIT 1`
    ).get() as { ts: string } | null;
    if (row?.ts) {
      const lastStr = new Date(row.ts).toLocaleDateString("en-CA", { timeZone: "Asia/Taipei" });
      if (lastStr === todayStr) return false;
    }
  } catch {}
  return true;
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
  const s6 = shouldRunS6(db, nowForS6()) ? checkS6DbIntegrity() : null;
  if (!s6) console.log(`[heartbeat] S6 skipped（非低峰時段或今日已跑過；HEARTBEAT_S6_FORCE=1 可強制）`);

  const allChecks: CheckResult[] = [s1, ...s2Results, s3, s4, ...(s6 ? [s6] : [])];

  for (const check of allChecks) {
    writeMetric(db, check.signal, check.value, check.status);
    console.log(`[heartbeat] ${check.signal}: ${check.status} — ${check.msg}`);
  }

  // Step 5-6: Per-signal debounce gate + alert/resolved
  const now = new Date().toISOString();
  for (const check of allChecks) {
    const isFailure = check.status === "RED";
    updateConsecutiveFailures(db, check.signal, isFailure, now);

    if (check.status === "RED") {
      const consec = getConsecutiveFailures(db, check.signal);
      const threshold = check.debounce ?? DEBOUNCE_N;
      if (consec >= threshold) {
        await sendAlert(check.signal, check.msg, check.level, db, tgToken);
      } else {
        console.log(`[heartbeat] ${check.signal} RED (${consec}/${threshold}) — debounce gate, not alerting yet`);
      }
    } else if (check.status === "GREEN") {
      // Only resolve if we previously sent an alert (avoids RESOLVED for never-alerted signals)
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

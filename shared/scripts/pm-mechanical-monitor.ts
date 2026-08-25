#!/usr/bin/env bun
// Alert-only health monitor for the three oldrabbit-owned pm-hub cron jobs.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Job = "pipeline" | "render" | "reconcile";
type Status = { job: Job; finished_epoch: number; exit_code: number };
type Finding = { check: string; category: string; detail: string };

const stateDir = process.env.PM_MECHANICAL_STATE_DIR ?? "/home/oldrabbit/.claude-bots/state/pm-mechanical";
const logDir = process.env.PM_MECHANICAL_LOG_DIR ?? "/home/oldrabbit/logs";
const relayDir = process.env.PM_MECHANICAL_RELAY_DIR ?? "/home/oldrabbit/.claude-bots/relay-diana";
const now = Number(process.env.PM_MECHANICAL_NOW_EPOCH ?? Math.floor(Date.now() / 1000));
const throttleSeconds = Number(process.env.PM_MECHANICAL_THROTTLE_SECONDS ?? 6 * 60 * 60);
const maxAge: Record<Job, number> = {
  pipeline: Number(process.env.PM_PIPELINE_MAX_AGE_SECONDS ?? 26 * 60 * 60),
  render: Number(process.env.PM_RENDER_MAX_AGE_SECONDS ?? 26 * 60 * 60),
  reconcile: Number(process.env.PM_RECONCILE_MAX_AGE_SECONDS ?? 8 * 60),
};
const jobs: Job[] = ["pipeline", "render", "reconcile"];

function readJson<T>(path: string): T | undefined {
  try { return JSON.parse(readFileSync(path, "utf8")) as T; } catch { return undefined; }
}

function atomicJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}

function latestPipelineRun(log: string): string {
  const marker = /^pm-pipeline v2 done .*$/gm;
  const matches = [...log.matchAll(marker)];
  if (matches.length === 0) return log;
  const end = (matches.at(-1)!.index ?? 0) + matches.at(-1)![0].length;
  const start = matches.length > 1
    ? (matches.at(-2)!.index ?? 0) + matches.at(-2)![0].length
    : 0;
  return log.slice(start, end);
}

function projectorFailure(): Finding | undefined {
  const path = join(logDir, "pm-pipeline.log");
  if (!existsSync(path)) return { check: "projector", category: "log_missing", detail: "pm-pipeline.log missing" };
  const run = latestPipelineRun(readFileSync(path, "utf8"));
  const bad = run.split("\n").find(line =>
    /(?:token(?:\([^)]*\))?|master|event|project(?:_lark|ion))[^\n]*(?:FAIL|failed|error)/i.test(line)
  );
  return bad
    ? { check: "projector", category: "latest_run_failed", detail: `latest pipeline run: ${bad.trim().slice(0, 180)}` }
    : undefined;
}

function reconcileHeartbeatFailure(): Finding | undefined {
  const path = join(logDir, "pm-reconcile.log");
  if (!existsSync(path)) return { check: "reconcile-heartbeat", category: "log_missing", detail: "pm-reconcile.log missing" };
  const lines = readFileSync(path, "utf8").split("\n").filter(line => line.startsWith("heartbeat "));
  const line = lines.at(-1) ?? "";
  const match = line.match(/^heartbeat ts=(\S+) inbox=(\d+) calendar=(\d+) exit=(\d+)$/);
  if (!match) return { check: "reconcile-heartbeat", category: "heartbeat_malformed", detail: "missing or malformed heartbeat" };
  const heartbeatEpoch = Date.parse(match[1]) / 1000;
  if (!Number.isFinite(heartbeatEpoch)) return { check: "reconcile-heartbeat", category: "heartbeat_timestamp_invalid", detail: "invalid heartbeat timestamp" };
  if (Number(match[4]) !== 0) return { check: "reconcile-heartbeat", category: "heartbeat_exit_nonzero", detail: `heartbeat exit=${match[4]}` };
  const age = now - heartbeatEpoch;
  if (age < 0 || age > maxAge.reconcile) {
    return { check: "reconcile-heartbeat", category: "stale", detail: `stale age=${age}s limit=${maxAge.reconcile}s` };
  }
  // inbox=0/calendar=0 intentionally reaches this healthy path.
  return undefined;
}

function collectFindings(): Finding[] {
  const findings: Finding[] = [];
  for (const job of jobs) {
    const status = readJson<Status>(join(stateDir, `${job}.json`));
    if (!status || status.job !== job || !Number.isFinite(status.finished_epoch) || !Number.isInteger(status.exit_code)) {
      findings.push({ check: job, category: "status_malformed", detail: "missing or malformed status" });
      continue;
    }
    if (status.exit_code !== 0) findings.push({ check: job, category: "exit_nonzero", detail: `last exit=${status.exit_code}` });
    const age = now - status.finished_epoch;
    if (age < 0 || age > maxAge[job]) findings.push({ check: job, category: "stale", detail: `stale age=${age}s limit=${maxAge[job]}s` });
  }
  const projector = projectorFailure();
  if (projector) findings.push(projector);
  const heartbeat = reconcileHeartbeatFailure();
  if (heartbeat) findings.push(heartbeat);
  return findings;
}

function appendAudit(findings: Finding[], alert: "none" | "sent" | "throttled"): void {
  mkdirSync(stateDir, { recursive: true });
  const row = { schema: "pm-mechanical-audit-v1", ts_epoch: now, healthy: findings.length === 0, findings, alert };
  const path = join(stateDir, "audit.jsonl");
  writeFileSync(path, JSON.stringify(row) + "\n", { flag: "a", mode: 0o600 });
}

function report(): void {
  const days = Number(process.env.PM_MECHANICAL_REPORT_DAYS ?? 14);
  const cutoff = now - days * 86400;
  const path = join(stateDir, "audit.jsonl");
  const rows = existsSync(path)
    ? readFileSync(path, "utf8").split("\n").filter(Boolean).flatMap(line => {
        try { const row = JSON.parse(line); return row.ts_epoch >= cutoff ? [row] : []; } catch { return []; }
      })
    : [];
  const healthy = rows.filter(r => r.healthy).length;
  const alerts = rows.filter(r => r.alert === "sent").length;
  const rate = rows.length ? ((healthy / rows.length) * 100).toFixed(2) : "N/A";
  process.stdout.write(`# pm-hub mechanical monitor stability report\n\n- Window: ${days} days\n- Checks: ${rows.length}\n- Healthy checks: ${healthy}\n- Healthy rate: ${rate}${rate === "N/A" ? "" : "%"}\n- Alerts emitted: ${alerts}\n- Mode: alert-only; no automatic repair or crontab ownership migration\n`);
}

if (process.argv.includes("--report")) {
  report();
  process.exit(0);
}

mkdirSync(stateDir, { recursive: true });
const findings = collectFindings();
// Human-readable details may contain live ages or timestamps. Throttle on the
// stable failure class so one unresolved incident cannot alert every cycle.
const signature = findings.map(f => `${f.check}:${f.category}`).sort().join("|");
const alertStatePath = join(stateDir, "alert-state.json");
const previous = readJson<{ signature: string; last_alert_epoch: number }>(alertStatePath);
let alert: "none" | "sent" | "throttled" = "none";

if (findings.length === 0) {
  atomicJson(alertStatePath, { schema: "pm-mechanical-alert-v1", signature: "", last_alert_epoch: 0, recovered_epoch: now });
} else if (previous?.signature === signature && now - previous.last_alert_epoch < throttleSeconds) {
  alert = "throttled";
} else {
  mkdirSync(relayDir, { recursive: true });
  const relayPath = join(relayDir, `${now}-${process.pid}-pm-mechanical-monitor.json`);
  atomicJson(relayPath, {
    from_bot: "keeper-diana",
    recipient: "diana-chat",
    route: "diana-chat",
    text: `diana:urgent\n[pm-hub mechanical monitor] ${findings.map(f => `${f.check}: ${f.detail}`).join("; ")}\nPlease assess and alert 老兔 on Telegram if actionable. Trial mode is alert-only; do not repair or migrate cron.`,
    meta: { source: "pm-mechanical-monitor", mode: "alert-only", findings },
    ts: new Date(now * 1000).toISOString(),
  });
  atomicJson(alertStatePath, { schema: "pm-mechanical-alert-v1", signature, last_alert_epoch: now });
  alert = "sent";
}

appendAudit(findings, alert);
process.stdout.write(JSON.stringify({ healthy: findings.length === 0, findings, alert }) + "\n");
process.exit(findings.length === 0 ? 0 : 1);

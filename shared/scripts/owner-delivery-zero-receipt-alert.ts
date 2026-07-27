#!/usr/bin/env bun
/**
 * Detect a missing morning owner-DM receipt without sending a new kind of
 * notification.  The alert is a normal Diana CRIT relay consumed by Anya.
 *
 * Schedule is deliberately external (loop-registry starts as planned): run at
 * 09:30 Asia/Taipei after the 08:57 morning batch's 30-minute grace period.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ROSTER = process.env["OWNER_DELIVERY_ROSTER"] ?? join(import.meta.dir, "../config/morning-owner-delivery-roster.json");
const POD_SYSTEM = process.env["OWNER_DELIVERY_POD_SYSTEM"] ?? join(import.meta.dir, "../../pod-system");
const RELAY_DIR = process.env["OWNER_DELIVERY_RELAY_DIR"] ?? join(import.meta.dir, "../../relay");
const STATE_DIR = process.env["OWNER_DELIVERY_STATE_DIR"] ?? join(import.meta.dir, "../../state/owner-delivery-alerts");
const now = new Date(process.env["OWNER_DELIVERY_NOW_ISO"] ?? Date.now());

type RosterPod = { state_dir?: string; bot_username?: string; vault_dir?: string; journal_file?: string };
type Roster = { pods?: RosterPod[] };

function taipeiParts(date: Date): { date: string; hour: number; minute: number } {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  const get = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, hour: Number(get("hour")), minute: Number(get("minute")) };
}

function atomicJson(path: string, payload: unknown): void {
  mkdirSync(join(path, ".."), { recursive: true });
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + "\n", "utf8");
  renameSync(tmp, path);
}

function expectedPods(roster: Roster): string[] {
  // This is the same vault-backed roster consumed by morning-todo-all.sh.
  // team-config supplies owner mappings to the producer, not eligibility.
  return (roster.pods ?? [])
    .filter((pod) => Boolean(pod.bot_username) && Boolean(pod.state_dir) && Boolean(pod.vault_dir) && Boolean(pod.journal_file))
    .map((pod) => pod.state_dir!)
    .sort();
}

function previouslyObservedPods(): string[] {
  // The current roster is the authority for additions, but it cannot say
  // whether a previously observed pod vanished because it was retired or by
  // mistake. Keep monitoring the latter: a silent roster shrink is exactly
  // the failure this loop exists to expose. A retirement workflow must
  // explicitly retire its state.
  if (!existsSync(STATE_DIR)) return [];
  const pods = new Set<string>();
  for (const file of readdirSync(STATE_DIR).filter((name) => /^\d{4}-\d{2}-\d{2}\.json$/.test(name))) {
    try {
      const record = JSON.parse(readFileSync(join(STATE_DIR, file), "utf8")) as { pods?: unknown };
      if (Array.isArray(record.pods)) {
        for (const pod of record.pods) if (typeof pod === "string") pods.add(pod);
      }
    } catch {
      // A malformed prior state must not silently remove a current roster pod;
      // current pods still remain monitored and alert writes remain fail-closed.
    }
  }
  return [...pods].sort();
}

function receiptInMorningWindow(logPath: string, dateKey: string): boolean {
  if (!existsSync(logPath)) return false;
  const start = Date.parse(`${dateKey}T00:57:00.000Z`); // 08:57 Asia/Taipei
  const end = Date.parse(`${dateKey}T01:30:00.000Z`);   // 09:30 Asia/Taipei
  return readFileSync(logPath, "utf8").split("\n").some((line) => {
    const match = line.match(/^\[([^\]]+)\].*routed via owner_escalation\b/);
    if (!match) return false;
    const timestamp = Date.parse(match[1]);
    return Number.isFinite(timestamp) && timestamp >= start && timestamp <= end;
  });
}

function main(): void {
  if (Number.isNaN(now.getTime())) throw new Error("OWNER_DELIVERY_NOW_ISO is invalid");
  const local = taipeiParts(now);
  if (local.hour < 9 || (local.hour === 9 && local.minute < 30)) {
    console.log(`[owner-delivery] before 09:30 CST; no evaluation for ${local.date}`);
    return;
  }

  const roster = JSON.parse(readFileSync(ROSTER, "utf8")) as Roster;
  const configuredPods = expectedPods(roster);
  const pods = [...new Set([...configuredPods, ...previouslyObservedPods()])].sort();
  if (pods.length === 0) throw new Error("morning owner-delivery roster has no eligible pods");

  const missing = pods.filter((pod) => !receiptInMorningWindow(join(POD_SYSTEM, `gateway-assist-${pod}.log`), local.date));
  const statePath = join(STATE_DIR, `${local.date}.json`);
  if (missing.length === 0) {
    atomicJson(statePath, { date: local.date, pods, missing: [], status: "healthy", checked_at: now.toISOString() });
    console.log(`[owner-delivery] ${local.date}: ${pods.length}/${pods.length} owner receipts present`);
    return;
  }

  // One alert for each (date, pod); state is written only after the relay is
  // durable, so a relay write failure exits non-zero and remains observable by
  // the existing cron/heartbeat failure path instead of being silently deduped.
  const prior = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) as { alerted?: string[] } : {};
  const alerted = new Set(prior.alerted ?? []);
  const newlyMissing = missing.filter((pod) => !alerted.has(pod));
  for (const pod of newlyMissing) {
    if (process.env["OWNER_DELIVERY_INJECT_BROKEN"] === "1") throw new Error("fixture injection: alert rule disabled");
    atomicJson(join(RELAY_DIR, `${local.date}-diana-crit-owner-delivery-zero-${pod}.json`), {
      from_bot: "diana-health", recipient: "anya", chat_id: "self", message_id: 0,
      event: "diana_health_crit", level: "CRIT", signal: `owner_delivery_zero:${local.date}:${pod}`,
      ts: now.toISOString(),
      text: `@Anyachl_bot 🔴 [Diana Health CRIT] owner delivery zero：${local.date} 08:57 批次的 assist-${pod} 在 09:30 前無 owner_escalation 回執（含日誌不存在）；請查 team-config 映射、producer 與 gateway routing。`,
    });
    alerted.add(pod);
  }
  atomicJson(statePath, { date: local.date, pods, missing, alerted: [...alerted].sort(), status: "alerted", checked_at: now.toISOString() });
  console.log(`[owner-delivery] ${local.date}: alerted ${newlyMissing.length} newly missing pod(s): ${newlyMissing.join(",")}`);
}

try { main(); } catch (error) { console.error(`[owner-delivery] FATAL: ${String(error)}`); process.exit(1); }

import { Database } from "bun:sqlite";
import {
  existsSync,
  readFileSync,
  statfsSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { AppendStore } from "./append-store.ts";
import type { AppendAuthorizationHook } from "./append-store.ts";
import { AppendError, type AppendCommand, type AppendResult } from "./append-types.ts";

export const EVENT_STORE_SCHEMA_VERSION = 1;
export const STOP_WRITE_FREE_PERCENT = 15;
export const WARN_FREE_PERCENT = 30;
export const STOP_WRITE_FREE_BYTES = 10 * 1024 ** 3;

export type DiskReading = Readonly<{
  free_bytes: number;
  total_bytes: number;
  free_percent: number;
}>;

export type StartupCheck = Readonly<{
  name:
    | "pragmas"
    | "schema_version"
    | "writable_free_space"
    | "last_clean_checkpoint"
    | "roster"
    | "writer_available";
  ok: boolean;
  detail: string;
}>;

export type StartupReport = Readonly<{
  mode: "read-write" | "read-only-degraded";
  checked_at: string;
  disk: DiskReading;
  checks: readonly StartupCheck[];
}>;

export type OperationsRoster = Readonly<{
  owner: "anna";
  operator: "anya";
  backup_operator: "老兔";
  qa_gate: "bella";
  reviewed_at: string;
  review_interval_days: 7;
  runbooks: readonly string[];
}>;

export type VerifiedProjectionSnapshot<State = unknown> = Readonly<{
  verified_at: string;
  global_high_water: number;
  state: State;
  checksum: string;
}>;

export type DegradedRead<State> = Readonly<{
  state: State;
  global_high_water: number;
  staleness_timestamp: string;
}>;

type StartupOptions = Readonly<{
  now?: Date;
  diskReading?: DiskReading;
  pragmaOverride?: Partial<{
    journal_mode: string;
    synchronous: number;
    foreign_keys: number;
    busy_timeout: number;
  }>;
}>;

type ServiceOptions<State> = StartupOptions & Readonly<{
  databasePath: string;
  rosterPath: string;
  projectionSnapshotPath: string;
  authorizeRead: () => boolean;
  authorizationHook?: AppendAuthorizationHook;
}>;

function sha256Json(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export function diskReadingFor(path: string): DiskReading {
  const stats = statfsSync(path);
  const freeBytes = Number(stats.bavail) * Number(stats.bsize);
  const totalBytes = Number(stats.blocks) * Number(stats.bsize);
  return {
    free_bytes: freeBytes,
    total_bytes: totalBytes,
    free_percent: totalBytes === 0 ? 0 : (freeBytes / totalBytes) * 100,
  };
}

export function shouldStopWrites(disk: DiskReading): boolean {
  return (
    disk.free_percent < STOP_WRITE_FREE_PERCENT ||
    disk.free_bytes < STOP_WRITE_FREE_BYTES
  );
}

function validateRoster(rosterPath: string, now: Date): StartupCheck {
  try {
    const roster = JSON.parse(readFileSync(rosterPath, "utf8")) as OperationsRoster;
    const reviewedAt = new Date(roster.reviewed_at);
    const ageMs = now.getTime() - reviewedAt.getTime();
    const expected =
      roster.owner === "anna" &&
      roster.operator === "anya" &&
      roster.backup_operator === "老兔" &&
      roster.qa_gate === "bella" &&
      roster.review_interval_days === 7 &&
      roster.runbooks.length > 0;
    const current = ageMs >= 0 && ageMs <= 7 * 24 * 60 * 60 * 1_000;
    return {
      name: "roster",
      ok: expected && current,
      detail: expected && current ? `reviewed ${roster.reviewed_at}` : "roster missing, invalid, or expired",
    };
  } catch {
    return { name: "roster", ok: false, detail: "roster missing, invalid, or expired" };
  }
}

export function validateStartup(
  databasePath: string,
  rosterPath: string,
  options: StartupOptions = {},
): StartupReport {
  const now = options.now ?? new Date();
  const disk = options.diskReading ?? diskReadingFor(databasePath);
  const checks: StartupCheck[] = [];
  try {
    const db = new Database(databasePath, { readonly: true, strict: true });
    try {
      db.exec("PRAGMA foreign_keys = ON");
      db.exec("PRAGMA busy_timeout = 2000");
      const journalMode =
        options.pragmaOverride?.journal_mode ??
        (db.query("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode;
      const synchronous =
        options.pragmaOverride?.synchronous ??
        (db.query("PRAGMA synchronous").get() as { synchronous: number }).synchronous;
      const foreignKeys =
        options.pragmaOverride?.foreign_keys ??
        (db.query("PRAGMA foreign_keys").get() as { foreign_keys: number }).foreign_keys;
      const busyTimeout =
        options.pragmaOverride?.busy_timeout ??
        (db.query("PRAGMA busy_timeout").get() as { timeout: number }).timeout;
      const pragmasOk =
        journalMode.toLowerCase() === "wal" &&
        synchronous === 2 &&
        foreignKeys === 1 &&
        busyTimeout > 0 &&
        busyTimeout <= 2_000;
      checks.push({
        name: "pragmas",
        ok: pragmasOk,
        detail: `journal=${journalMode},sync=${synchronous},fk=${foreignKeys},busy_ms=${busyTimeout}`,
      });

      const meta = db.query("SELECT schema_version FROM event_store_meta").get() as
        | { schema_version: number }
        | null;
      checks.push({
        name: "schema_version",
        ok: meta?.schema_version === EVENT_STORE_SCHEMA_VERSION,
        detail: `expected=${EVENT_STORE_SCHEMA_VERSION},actual=${meta?.schema_version ?? "missing"}`,
      });
      const checkpoint = db.query(`
        SELECT last_clean_checkpoint_at, checkpoint_result
        FROM event_store_operations WHERE singleton = 1
      `).get() as { last_clean_checkpoint_at: string | null; checkpoint_result: string | null } | null;
      checks.push({
        name: "last_clean_checkpoint",
        ok: Boolean(checkpoint?.last_clean_checkpoint_at) && checkpoint?.checkpoint_result === "ok",
        detail: checkpoint?.last_clean_checkpoint_at ?? "missing",
      });
    } finally {
      db.close();
    }
  } catch (error) {
    const detail = `database unavailable: ${String(error)}`;
    checks.push(
      { name: "pragmas", ok: false, detail },
      { name: "schema_version", ok: false, detail },
      { name: "last_clean_checkpoint", ok: false, detail },
    );
  }
  checks.push({
    name: "writable_free_space",
    ok: !shouldStopWrites(disk),
    detail: `${disk.free_percent.toFixed(2)}%,${disk.free_bytes} bytes free`,
  });
  checks.push(validateRoster(rosterPath, now));
  return {
    mode: checks.every((check) => check.ok) ? "read-write" : "read-only-degraded",
    checked_at: now.toISOString(),
    disk,
    checks,
  };
}

export function parseVerifiedProjectionSnapshot<State>(
  path: string,
): VerifiedProjectionSnapshot<State> {
  const snapshot = JSON.parse(readFileSync(path, "utf8")) as VerifiedProjectionSnapshot<State>;
  const expected = sha256Json({
    verified_at: snapshot.verified_at,
    global_high_water: snapshot.global_high_water,
    state: snapshot.state,
  });
  if (snapshot.checksum !== expected) {
    throw new AppendError("UNAVAILABLE", "verified projection snapshot checksum mismatch");
  }
  return snapshot;
}

export function makeVerifiedProjectionSnapshot<State>(
  verifiedAt: string,
  globalHighWater: number,
  state: State,
): VerifiedProjectionSnapshot<State> {
  const body = {
    verified_at: verifiedAt,
    global_high_water: globalHighWater,
    state,
  };
  return { ...body, checksum: sha256Json(body) };
}

export class DurableEventLayer<State = unknown> {
  readonly startup: StartupReport;
  readonly #options: ServiceOptions<State>;
  #store?: AppendStore;

  constructor(options: ServiceOptions<State>) {
    this.#options = options;
    if (existsSync(options.databasePath)) {
      const preflight = validateStartup(
        options.databasePath,
        options.rosterPath,
        options,
      );
      if (preflight.mode !== "read-write") {
        this.startup = preflight;
        return;
      }
    }
    try {
      this.#store = new AppendStore(options.databasePath, {
        authorizationHook: options.authorizationHook,
      });
      this.startup = validateStartup(options.databasePath, options.rosterPath, options);
      if (this.startup.mode !== "read-write") {
        this.#store.close(false);
        this.#store = undefined;
      }
    } catch (error) {
      this.#store = undefined;
      const report = validateStartup(options.databasePath, options.rosterPath, options);
      this.startup = {
        ...report,
        mode: "read-only-degraded",
        checks: [
          ...report.checks,
          {
            name: "writer_available",
            ok: false,
            detail: `writer unavailable: ${String(error)}`,
          },
        ],
      };
    }
  }

  append(command: AppendCommand): AppendResult {
    if (!this.#store || this.startup.mode !== "read-write") {
      throw new AppendError("UNAVAILABLE", "event layer is read-only degraded");
    }
    return this.#store.append(command);
  }

  readDegraded(): DegradedRead<State> {
    if (this.startup.mode !== "read-only-degraded") {
      throw new AppendError("INVALID_COMMAND", "degraded read is only available in degraded mode");
    }
    if (!this.#options.authorizeRead()) {
      throw new AppendError("UNAVAILABLE", "authorization authority unavailable or denied");
    }
    const snapshot = parseVerifiedProjectionSnapshot<State>(
      this.#options.projectionSnapshotPath,
    );
    return {
      state: snapshot.state,
      global_high_water: snapshot.global_high_water,
      staleness_timestamp: snapshot.verified_at,
    };
  }

  close(): void {
    this.#store?.close();
    this.#store = undefined;
  }
}

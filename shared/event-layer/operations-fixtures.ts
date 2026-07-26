#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomBytes } from "node:crypto";
import { AppendStore } from "./src/append-store.ts";
import { AppendError, type AppendCommand } from "./src/append-types.ts";
import {
  createEncryptedVerifiedSnapshot,
  pruneBackupDirectory,
  restoreAndReplay,
  retainedManifestPaths,
  type BackupManifest,
} from "./src/backup.ts";
import {
  DurableEventLayer,
  makeVerifiedProjectionSnapshot,
  type DiskReading,
} from "./src/durability.ts";
import { EventLayerMetrics } from "./src/observability.ts";
import { ProjectionRegistry, knowledgeLifecycleProjection } from "./src/projection.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`operations fixture assertion failed: ${message}`);
}

function command(ordinal: number): AppendCommand {
  return {
    workspace_id: "workspace-operations",
    stream_id: "stream-operations",
    stream_kind: "channel",
    event_type: "message.posted",
    schema_version: 2,
    actor_id: "actor-operations",
    actor_kind: "human",
    origin: "native",
    correlation_id: `operations-${ordinal}`,
    occurred_at: new Date(1_720_000_000_000 + ordinal * 1_000).toISOString(),
    payload: { body: `operations fixture ${ordinal}` },
    refs: [],
    client_id: "operations-fixture",
    idempotency_key: `operations-${ordinal}`,
    authorization: {
      principal_id: "principal-operations",
      authz_version: 1,
      capability: "event.append",
    },
  };
}

function seedStrongAuthorization(databasePath: string): void {
  const db = new Database(databasePath);
  try {
    db.query(`
      INSERT INTO authorization_principals(workspace_id, principal_id, actor_id, authz_version)
      VALUES (?, ?, ?, 1)
    `).run("workspace-operations", "principal-operations", "actor-operations");
    db.query(`
      INSERT INTO authorization_capabilities(workspace_id, principal_id, capability)
      VALUES (?, ?, ?)
    `).run("workspace-operations", "principal-operations", "event.append");
    db.query(`
      INSERT INTO strong_stream_memberships(workspace_id, stream_id, principal_id, active)
      VALUES (?, ?, ?, 1)
    `).run("workspace-operations", "stream-operations", "principal-operations");
  } finally {
    db.close();
  }
}

function eventCount(databasePath: string): number {
  const database = new Database(databasePath, { readonly: true });
  try {
    return (
      database.query("SELECT COUNT(*) AS value FROM events").get() as { value: number }
    ).value;
  } finally {
    database.close();
  }
}

const healthyDisk: DiskReading = {
  free_bytes: 50 * 1024 ** 3,
  total_bytes: 100 * 1024 ** 3,
  free_percent: 50,
};
const pressuredDisk: DiskReading = {
  free_bytes: 9 * 1024 ** 3,
  total_bytes: 100 * 1024 ** 3,
  free_percent: 20,
};
const fixtureNow = new Date("2026-07-25T02:30:00Z");
const fixtureRoot = mkdtempSync(join(tmpdir(), "event-operations-fixture-"));
const evidenceRoot = process.env.EVENT_LAYER_EVIDENCE_DIR || join(fixtureRoot, "evidence");
mkdirSync(evidenceRoot, { recursive: true });
const databasePath = join(fixtureRoot, "events.db");
const rosterPath = join(fixtureRoot, "roster.json");
const projectionPath = join(fixtureRoot, "verified-projection.json");

try {
  const roster = {
    owner: "anna",
    operator: "anya",
    backup_operator: "老兔",
    qa_gate: "bella",
    reviewed_at: new Date(
      fixtureNow.getTime() - 24 * 60 * 60 * 1_000,
    ).toISOString(),
    review_interval_days: 7,
    runbooks: [
      "runbooks.md#disk-pressure",
      "runbooks.md#database-corruption",
      "runbooks.md#restore-and-replay",
      "runbooks.md#stuck-wal",
      "runbooks.md#projection-drift",
      "runbooks.md#poison-event",
      "runbooks.md#credential-revoke",
    ],
  };
  writeFileSync(rosterPath, `${JSON.stringify(roster, null, 2)}\n`);

  const store = new AppendStore(databasePath);
  seedStrongAuthorization(databasePath);
  store.append(command(1));
  store.append(command(2));
  const checkpointDuration = store.checkpoint();
  store.close();
  assert(checkpointDuration < 60_000, "clean checkpoint must satisfy SLO");
  writeFileSync(
    projectionPath,
    `${JSON.stringify(
      makeVerifiedProjectionSnapshot(
        "2026-07-25T02:00:00Z",
        2,
        { messages: ["safe projected record"] },
      ),
      null,
      2,
    )}\n`,
  );

  const healthy = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  assert(healthy.startup.mode === "read-write", "healthy startup must accept writes");
  healthy.close();

  const lockHolder = new AppendStore(databasePath);
  const writerUnavailable = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  assert(
    writerUnavailable.startup.mode === "read-only-degraded",
    "writer open failure must report degraded mode",
  );
  assert(
    writerUnavailable.startup.checks.some(
      (check) => check.name === "writer_available" && !check.ok,
    ),
    "writer open failure must fail the writer availability check",
  );
  lockHolder.close();

  const authorityBefore = eventCount(databasePath);
  const authorityUnavailable = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    authorizationHook: () => {
      throw new AppendError("UNAVAILABLE", "authorization authority unavailable");
    },
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  let authorityWriteRejected = false;
  try {
    authorityUnavailable.append(command(30));
  } catch (error) {
    authorityWriteRejected = String(error).includes("authorization authority unavailable");
  }
  assert(authorityWriteRejected, "authorization authority failure must reject writes");
  assert(eventCount(databasePath) === authorityBefore, "authorization failure wrote an event");
  authorityUnavailable.close();

  const beforePragmaFailure = eventCount(databasePath);
  const badPragma = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
    pragmaOverride: { synchronous: 1 },
  });
  assert(badPragma.startup.mode === "read-only-degraded", "bad pragma must degrade");
  let rejected = false;
  try {
    badPragma.append(command(3));
  } catch (error) {
    rejected = String(error).includes("read-only degraded");
  }
  assert(rejected, "degraded append must fail closed");
  assert(eventCount(databasePath) === beforePragmaFailure, "bad pragma append wrote an event");

  const operationsDb = new Database(databasePath);
  operationsDb.exec(
    "UPDATE event_store_operations SET checkpoint_result='busy', last_clean_checkpoint_at=NULL WHERE singleton=1",
  );
  operationsDb.close();
  const checkpointFailed = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  assert(
    checkpointFailed.startup.mode === "read-only-degraded",
    "missing/failed clean checkpoint must degrade",
  );
  assert(
    checkpointFailed.startup.checks.some(
      (check) => check.name === "last_clean_checkpoint" && !check.ok,
    ),
    "checkpoint failure must be explicit",
  );

  new AppendStore(databasePath).close();
  const diskFailed = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: pressuredDisk,
  });
  assert(diskFailed.startup.mode === "read-only-degraded", "disk reserve must stop writes");
  const degradedRead = diskFailed.readDegraded();
  assert(
    degradedRead.staleness_timestamp === "2026-07-25T02:00:00Z",
    "degraded read must expose staleness timestamp",
  );
  let authorizationFailed = false;
  const authUnavailable = new DurableEventLayer({
    databasePath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => false,
    now: fixtureNow,
    diskReading: pressuredDisk,
  });
  try {
    authUnavailable.readDegraded();
  } catch (error) {
    authorizationFailed = String(error).includes("authorization authority");
  }
  assert(authorizationFailed, "unavailable authorization authority must fail all reads closed");

  const corruptPath = join(fixtureRoot, "corrupt.db");
  writeFileSync(corruptPath, randomBytes(512));
  const corrupt = new DurableEventLayer({
    databasePath: corruptPath,
    rosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  assert(corrupt.startup.mode === "read-only-degraded", "corrupt database must degrade");
  assert(
    corrupt.readDegraded().global_high_water === 2,
    "corruption drill must retain verified safe read",
  );

  const expiredRosterPath = join(fixtureRoot, "expired-roster.json");
  writeFileSync(
    expiredRosterPath,
    `${JSON.stringify({
      ...roster,
      reviewed_at: new Date(
        fixtureNow.getTime() - 8 * 24 * 60 * 60 * 1_000,
      ).toISOString(),
    })}\n`,
  );
  const expiredRosterService = new DurableEventLayer({
    databasePath,
    rosterPath: expiredRosterPath,
    projectionSnapshotPath: projectionPath,
    authorizeRead: () => true,
    now: fixtureNow,
    diskReading: healthyDisk,
  });
  assert(
    expiredRosterService.startup.mode === "read-only-degraded",
    "expired roster must block W1 traffic",
  );

  const backupDirectory = join(evidenceRoot, "backup");
  const encryptionKey = randomBytes(32);
  const manifest = createEncryptedVerifiedSnapshot({
    databasePath,
    backupDirectory,
    encryptionKey,
    createdAt: fixtureNow,
  });
  const manifestPath = join(backupDirectory, `${manifest.backup_id}.manifest.json`);
  for (const field of [
    "schema_version",
    "global_high_water",
    "attachment_manifest_high_water",
    "checksum",
    "duration_ms",
    "result",
  ] as const) {
    assert(manifest[field] !== undefined, `backup manifest missing ${field}`);
  }
  const registry = new ProjectionRegistry();
  registry.register(knowledgeLifecycleProjection);
  const restored = restoreAndReplay({
    manifestPath,
    encryptionKey,
    disposableDatabasePath: join(evidenceRoot, "disposable-restore.db"),
    replay: (events) => registry.rebuild(events),
    now: fixtureNow,
  });
  assert(restored.evidence.result === "ok", "restore/integrity/replay drill failed");
  assert(restored.evidence.duration_ms < 3_600_000, "restore drill breached RTO");
  writeFileSync(
    join(evidenceRoot, "restore-evidence.json"),
    `${JSON.stringify(restored.evidence, null, 2)}\n`,
  );

  const retentionDirectory = join(fixtureRoot, "retention");
  mkdirSync(retentionDirectory);
  const retentionDates = [
    "2026-07-25T01:10:00Z",
    "2026-07-25T01:50:00Z",
    "2026-07-23T02:30:00Z",
    "2026-07-23T01:30:00Z",
    "2026-07-22T02:30:00Z",
    "2026-06-24T02:30:00Z",
    "2025-07-25T02:30:00Z",
    "2025-07-20T02:30:00Z",
  ].map((value) => new Date(value));
  const generations = retentionDates.map((createdAt, index) => {
    const manifestFile = join(retentionDirectory, `${index}.manifest.json`);
    const encryptedFile = `${index}.sqlite.enc`;
    writeFileSync(join(retentionDirectory, encryptedFile), "fixture");
    const fake: BackupManifest = {
      ...manifest,
      backup_id: String(index),
      created_at: createdAt.toISOString(),
      encrypted_file: encryptedFile,
    };
    writeFileSync(manifestFile, JSON.stringify(fake));
    return { manifestPath: manifestFile, createdAt };
  });
  const retained = retainedManifestPaths(generations, fixtureNow);
  assert(retained.has(generations[1]!.manifestPath), "newest hourly generation missing");
  assert(!retained.has(generations[0]!.manifestPath), "older same-hour generation retained");
  assert(retained.has(generations[2]!.manifestPath), "48-hour boundary generation missing");
  assert(!retained.has(generations[3]!.manifestPath), "older same-day generation retained");
  assert(retained.has(generations[4]!.manifestPath), "daily generation missing");
  assert(retained.has(generations[5]!.manifestPath), "monthly generation missing");
  assert(retained.has(generations[6]!.manifestPath), "12-month boundary generation missing");
  assert(!retained.has(generations[7]!.manifestPath), "expired monthly generation retained");
  const removed = pruneBackupDirectory(retentionDirectory, fixtureNow);
  assert(removed.length === 3, "retention pruning removed the wrong generations");

  const metrics = new EventLayerMetrics();
  for (let index = 0; index < 100; index += 1) {
    metrics.record("append_latency_ms", index >= 98 ? 300 : 20, fixtureNow);
    metrics.record("lock_wait_ms", index === 99 ? 2_000 : 10, fixtureNow);
    metrics.record("projection_lag_ms", 1_000, fixtureNow);
  }
  metrics.record("checkpoint_duration_ms", checkpointDuration, fixtureNow);
  metrics.record("backup_duration_ms", manifest.duration_ms, fixtureNow);
  metrics.record("restore_replay_duration_ms", restored.evidence.duration_ms, fixtureNow);
  metrics.record("free_disk_percent", pressuredDisk.free_percent, fixtureNow);
  metrics.record("free_disk_bytes", pressuredDisk.free_bytes, fixtureNow);
  const breaches = metrics.evaluate();
  assert(
    breaches.some((breach) => breach.metric === "append_latency_ms"),
    "append SLO threshold was not evaluated",
  );
  assert(
    breaches.some((breach) => breach.metric === "lock_wait_ms"),
    "lock SLO threshold was not evaluated",
  );
  assert(
    breaches.some((breach) => breach.metric === "free_disk_bytes"),
    "disk stop-write threshold was not evaluated",
  );

  const alerts = JSON.parse(
    readFileSync(join(import.meta.dir, "ops", "alerts.json"), "utf8"),
  ) as Array<Record<string, unknown>>;
  assert(alerts.length > 0, "alerts missing");
  for (const alert of alerts) {
    for (const field of ["owner", "severity", "action", "runbook"]) {
      assert(typeof alert[field] === "string" && alert[field] !== "", `alert missing ${field}`);
    }
  }
  const sourceFiles = readdirSync(join(import.meta.dir, "src"))
    .filter((name) => name.endsWith(".ts"))
    .map((name) => readFileSync(join(import.meta.dir, "src", name), "utf8"))
    .join("\n");
  assert(!sourceFiles.includes(".clsc.md"), "legacy file fallback appeared in source");
  assert(!sourceFiles.includes("relay"), "relay fallback appeared in source");
  assert(!/attachment_(size|latency)|adapter_(latency|receipt)/.test(sourceFiles), "out-of-scope metrics appeared");
  assert(existsSync(manifestPath), "backup manifest evidence missing");

  console.log("event-layer operations fixtures: PASS");
  console.log("  pragma/checkpoint/corruption/disk pressure -> fail-closed PASS");
  console.log("  authorized degraded read includes staleness timestamp PASS");
  console.log("  encrypted snapshot -> disposable restore -> integrity -> replay PASS");
  console.log(`  manifest: ${manifestPath}`);
  console.log(`  restore evidence: ${join(evidenceRoot, "restore-evidence.json")}`);
  console.log("  hourly/daily/monthly retention boundaries and pruning PASS");
  console.log("  SLO thresholds + alert/roster/runbook contract PASS");
} finally {
  if (!process.env.EVENT_LAYER_EVIDENCE_DIR) rmSync(fixtureRoot, { recursive: true, force: true });
  else {
    for (const name of readdirSync(fixtureRoot)) {
      if (join(fixtureRoot, name) !== evidenceRoot) {
        rmSync(join(fixtureRoot, name), { recursive: true, force: true });
      }
    }
  }
}

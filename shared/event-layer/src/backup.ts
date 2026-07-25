import { Database } from "bun:sqlite";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";
import { parseStoredEvent, type StoredEventRow } from "./append-store.ts";
import type { EventEnvelope } from "./envelope.ts";

const BACKUP_MAGIC = Buffer.from("CLEB1");

export type BackupManifest = Readonly<{
  backup_id: string;
  created_at: string;
  encrypted_file: string;
  schema_version: number;
  global_high_water: number;
  attachment_manifest_high_water: number;
  checksum: string;
  duration_ms: number;
  result: "ok";
  encryption: "aes-256-gcm";
  source_bytes: number;
}>;

export type RestoreEvidence = Readonly<{
  backup_id: string;
  restored_at: string;
  disposable_database: string;
  integrity_result: "ok";
  replay_result: "ok";
  restored_global_high_water: number;
  duration_ms: number;
  result: "ok";
}>;

export type RetentionGeneration = Readonly<{
  manifestPath: string;
  createdAt: Date;
}>;

function atomicWrite(path: string, contents: Uint8Array | string): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  writeFileSync(temporary, contents, { flag: "wx", mode: 0o600 });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function encryptSnapshot(snapshot: Uint8Array, key: Uint8Array): Buffer {
  if (key.byteLength !== 32) throw new Error("backup encryption key must be 32 bytes");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(snapshot), cipher.final()]);
  return Buffer.concat([BACKUP_MAGIC, iv, cipher.getAuthTag(), ciphertext]);
}

function decryptSnapshot(encrypted: Uint8Array, key: Uint8Array): Buffer {
  const buffer = Buffer.from(encrypted);
  if (!buffer.subarray(0, BACKUP_MAGIC.length).equals(BACKUP_MAGIC)) {
    throw new Error("unsupported encrypted backup format");
  }
  const ivStart = BACKUP_MAGIC.length;
  const tagStart = ivStart + 12;
  const bodyStart = tagStart + 16;
  const decipher = createDecipheriv(
    "aes-256-gcm",
    key,
    buffer.subarray(ivStart, tagStart),
  );
  decipher.setAuthTag(buffer.subarray(tagStart, bodyStart));
  return Buffer.concat([
    decipher.update(buffer.subarray(bodyStart)),
    decipher.final(),
  ]);
}

export function createEncryptedVerifiedSnapshot(options: Readonly<{
  databasePath: string;
  backupDirectory: string;
  encryptionKey: Uint8Array;
  createdAt?: Date;
}>): BackupManifest {
  const started = performance.now();
  const createdAt = options.createdAt ?? new Date();
  const database = new Database(options.databasePath, { readonly: true, strict: true });
  let snapshot: Uint8Array;
  let schemaVersion: number;
  let globalHighWater: number;
  try {
    const integrity = database.query("PRAGMA integrity_check").get() as {
      integrity_check: string;
    };
    if (integrity.integrity_check !== "ok") throw new Error("source integrity check failed");
    schemaVersion = (
      database.query("SELECT schema_version FROM event_store_meta").get() as {
        schema_version: number;
      }
    ).schema_version;
    globalHighWater = (
      database.query("SELECT COALESCE(MAX(global_seq), 0) AS value FROM events").get() as {
        value: number;
      }
    ).value;
    // SQLite serialization takes a transactionally coherent image including
    // committed WAL state; the image is integrity-checked again after restore.
    snapshot = database.serialize();
  } finally {
    database.close();
  }

  const backupId = createdAt.toISOString().replace(/[:.]/g, "-");
  const encrypted = encryptSnapshot(snapshot, options.encryptionKey);
  const encryptedFile = join(options.backupDirectory, `${backupId}.sqlite.enc`);
  const manifestPath = join(options.backupDirectory, `${backupId}.manifest.json`);
  atomicWrite(encryptedFile, encrypted);
  const manifest: BackupManifest = {
    backup_id: backupId,
    created_at: createdAt.toISOString(),
    encrypted_file: basename(encryptedFile),
    schema_version: schemaVersion,
    global_high_water: globalHighWater,
    // W1 has no attachment delivery wave. The field remains explicit so a
    // future generation cannot be mistaken for a complete cross-layer backup.
    attachment_manifest_high_water: 0,
    checksum: sha256(encrypted),
    duration_ms: Math.ceil(performance.now() - started),
    result: "ok",
    encryption: "aes-256-gcm",
    source_bytes: snapshot.byteLength,
  };
  atomicWrite(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

function storedEvents(database: Database): readonly EventEnvelope[] {
  const rows = database
    .query("SELECT * FROM events ORDER BY global_seq")
    .all() as StoredEventRow[];
  return rows.map(parseStoredEvent);
}

export function restoreAndReplay<State>(options: Readonly<{
  manifestPath: string;
  encryptionKey: Uint8Array;
  disposableDatabasePath: string;
  replay: (events: readonly EventEnvelope[]) => State;
  now?: Date;
}>): Readonly<{ evidence: RestoreEvidence; replayState: State }> {
  const started = performance.now();
  const manifest = JSON.parse(
    readFileSync(options.manifestPath, "utf8"),
  ) as BackupManifest;
  if (basename(manifest.encrypted_file) !== manifest.encrypted_file) {
    throw new Error("backup manifest encrypted_file must be a basename");
  }
  const encryptedPath = join(dirname(options.manifestPath), manifest.encrypted_file);
  const encrypted = readFileSync(encryptedPath);
  if (sha256(encrypted) !== manifest.checksum) throw new Error("backup checksum mismatch");
  const snapshot = decryptSnapshot(encrypted, options.encryptionKey);
  atomicWrite(options.disposableDatabasePath, snapshot);

  const restored = new Database(options.disposableDatabasePath, {
    readonly: true,
    strict: true,
  });
  let events: readonly EventEnvelope[];
  try {
    const integrity = restored.query("PRAGMA integrity_check").get() as {
      integrity_check: string;
    };
    if (integrity.integrity_check !== "ok") throw new Error("restored integrity check failed");
    const schema = (
      restored.query("SELECT schema_version FROM event_store_meta").get() as {
        schema_version: number;
      }
    ).schema_version;
    if (schema !== manifest.schema_version) throw new Error("restored schema mismatch");
    events = storedEvents(restored);
    if ((events.at(-1)?.global_seq ?? 0) !== manifest.global_high_water) {
      throw new Error("restored high-water mismatch");
    }
  } finally {
    restored.close();
  }
  const replayState = options.replay(events);
  return {
    replayState,
    evidence: {
      backup_id: manifest.backup_id,
      restored_at: (options.now ?? new Date()).toISOString(),
      disposable_database: options.disposableDatabasePath,
      integrity_result: "ok",
      replay_result: "ok",
      restored_global_high_water: manifest.global_high_water,
      duration_ms: Math.ceil(performance.now() - started),
      result: "ok",
    },
  };
}

function newestPerBucket(
  generations: readonly RetentionGeneration[],
  bucket: (date: Date) => string,
): Set<string> {
  const newest = new Map<string, RetentionGeneration>();
  for (const generation of generations) {
    const key = bucket(generation.createdAt);
    const current = newest.get(key);
    if (!current || generation.createdAt > current.createdAt) newest.set(key, generation);
  }
  return new Set([...newest.values()].map((generation) => generation.manifestPath));
}

export function retainedManifestPaths(
  generations: readonly RetentionGeneration[],
  now: Date,
): ReadonlySet<string> {
  const age = (generation: RetentionGeneration) =>
    now.getTime() - generation.createdAt.getTime();
  const hours48 = 48 * 60 * 60 * 1_000;
  const days30 = 30 * 24 * 60 * 60 * 1_000;
  const monthCutoff = new Date(now);
  monthCutoff.setUTCMonth(monthCutoff.getUTCMonth() - 12);
  const retained = new Set<string>();
  const tiers: Array<[(generation: RetentionGeneration) => boolean, (date: Date) => string]> = [
    [(generation) => age(generation) >= 0 && age(generation) <= hours48, (date) => date.toISOString().slice(0, 13)],
    [(generation) => age(generation) >= 0 && age(generation) <= days30, (date) => date.toISOString().slice(0, 10)],
    [
      (generation) =>
        generation.createdAt <= now && generation.createdAt >= monthCutoff,
      (date) => date.toISOString().slice(0, 7),
    ],
  ];
  for (const [withinWindow, bucket] of tiers) {
    for (const path of newestPerBucket(
      generations.filter(withinWindow),
      bucket,
    )) retained.add(path);
  }
  return retained;
}

export function pruneBackupDirectory(backupDirectory: string, now = new Date()): string[] {
  const generations = readdirSync(backupDirectory)
    .filter((name) => name.endsWith(".manifest.json"))
    .map((name) => {
      const manifestPath = join(backupDirectory, name);
      const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as BackupManifest;
      return { manifestPath, createdAt: new Date(manifest.created_at) };
    });
  const retained = retainedManifestPaths(generations, now);
  const removed: string[] = [];
  for (const generation of generations) {
    if (retained.has(generation.manifestPath)) continue;
    const manifest = JSON.parse(
      readFileSync(generation.manifestPath, "utf8"),
    ) as BackupManifest;
    if (basename(manifest.encrypted_file) !== manifest.encrypted_file) {
      throw new Error("backup manifest encrypted_file must be a basename");
    }
    rmSync(join(backupDirectory, manifest.encrypted_file), { force: true });
    rmSync(generation.manifestPath);
    removed.push(generation.manifestPath);
  }
  return removed;
}
